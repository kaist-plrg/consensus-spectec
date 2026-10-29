open Common.Source
open Lang.El
open Kind
open Operand
open Ctx
open Branch
module S = Source
module B = Python_builtins
open Loop
open Stmt

let parse_declaration (signature : S.signature) =
  match
    Spectec.parse_spec_source
      { filename = "<presentation>"; contents = signature.declaration }
  with
  | Ok [ ({ it = RelD _ | DecD _; _ } as declaration) ] -> declaration
  | _ ->
      Error.reject ~at:no_region
        ("Invalid presentation declaration for " ^ signature.name)

let set_input ctx at branch value =
  match Kind.set_element ~types:ctx.source.types ~at value.kind with
  | None -> branch
  | Some element ->
      let name = fresh_helper_name ctx ~operation:"distinct" in
      let head = fresh ctx ~at ~kind:element in
      let tail = fresh ctx ~at ~kind:(Sequence (element, None)) in
      let member = MemE (head.exp, tail.exp) $ at in
      let cons = ConsE (head.exp, tail.exp) $ at in
      Registry.emit ~registry:ctx.registry
        ~ownership:(Helper ctx.source.signature.name)
        (Operand.function_definitions ~at name
           ~parameters:[ Operand.typ ~types:ctx.source.types ~at value.kind ]
           ~result:(BoolT $ at)
           ~equations:
             [
               ([ EpsE $ at ], bool ~at true, []);
               ([ cons ], bool ~at false, [ IfPr member $ at ]);
               ( [ cons ],
                 call ~at name ~args:[ tail.exp ],
                 [ IfPr (UnE (`NotOp, ParenE member $ at) $ at) $ at ] );
             ]);
      guard ~at ~exp:(call ~at name ~args:[ value.exp ]) branch

let translate_source list_results source =
  let at = source.S.at and signature = source.S.signature in
  let declarations =
    List.map
      (fun (s : S.signature) -> (s.name, parse_declaration s))
      source.calls
  in
  let ctx =
    Ctx.make source ~list_results
      ~reserved:(List.map snd signature.arguments)
      ~declarations
  in
  let environment =
    List.map
      (fun (name, kind) ->
        let kind =
          if List.mem name signature.optional then Optional (Named kind)
          else Named kind
        in
        ( name,
          {
            exp =
              variable ~at
                (Error.find_or_reject ~at ~name signature.arguments)
                ~typ:(Operand.typ ~types:ctx.source.types ~at kind);
            kind;
          } ))
      signature.parameters
  in
  (* The target models an execution engine as a unit handle, so one invocation
     reaches one external service. A supplied engine and the global would be
     two services answering one shared verdict. *)
  let supplied_engines =
    List.length
      (List.filter
         (fun (_, kind) -> kind = Spec_names.execution_engine)
         signature.parameters)
  in
  let global_engine =
    List.mem Spec_names.execution_engine_global source.builtins
  in
  if supplied_engines > 1 then
    Error.reject ~at "More than one execution engine in one definition";
  if supplied_engines = 1 && global_engine then
    Error.reject ~at
      "A supplied execution engine cannot be mixed with the global";
  if supplied_engines > 0 || global_engine then
    Target_builtins.declare_execution_engine ~ctx ~at;
  (* An optional parameter takes the head pattern that its path decided, so
     presence and absence become separate clauses of one definition. *)
  let head branch =
    List.map
      (fun (name, value) ->
        match List.assoc_opt name branch.options with
        | Some pattern -> pattern
        | None -> value.exp)
      environment
  in
  let branches =
    let initial = Branch.make (Store.make environment) in
    let initial =
      List.fold_left
        (fun branch (_, value) -> set_input ctx at branch value)
        initial environment
    in
    Stmt.translate ~ctx ~scope:FunctionBody source.body ~branch:initial
    |> List.map (fun (branch, completion) ->
           match completion with
           | Returned value -> (branch, value)
           | Broken | Fallthrough -> assert false)
  in
  (* The accumulated kind is settled only inside its own definition, so the
     declared result would hide the plain value an empty loop leaves. *)
  List.iter
    (fun (branch, value) ->
      if List.mem_assoc (string_of_exp value.exp) branch.promoted then
        Error.reject ~at
          "An accumulated loop result cannot be the declared result")
    branches;
  let declaration =
    Error.find_or_reject ~at ~name:signature.name declarations
  in
  let definitions =
    List.mapi
      (fun index (branch, value) ->
        let premises = branch.premises in
        match signature.relation with
        | Some name ->
            RuleD
              ( id ~at name,
                id ~at ("path" ^ string_of_int index),
                Operand.conclusion ~at declaration
                  ~values:(head branch @ [ value.exp ]),
                premises )
            $ at
        | None ->
            DefD
              ( id ~at signature.name,
                List.map (id ~at) (Call_ops.type_parameters ~ctx ~at signature),
                List.map (fun exp -> ExpA exp $ at) (head branch),
                value.exp,
                premises )
            $ at)
      branches
  in
  Registry.emit ~registry:ctx.registry ~ownership:(Source signature.name)
    (declaration :: definitions);
  Registry.groups ctx.registry

let bundle bundle =
  let list_results = Bundle.list_results bundle in
  Bundle.documents bundle
  |> List.concat_map (translate_source list_results)
  |> Assembly.assemble
