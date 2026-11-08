open Common.Annotated
open Lang.El
open Value
open Ctx
open Branch
open Loop
open Stmt

let string_of_signature ~types (signature : Typed.signature) =
  let at = Common.Location.Unknown in
  let render kind =
    Lang.El.Unparse.string_of_plaintyp (Value.plaintyp_of_kind ~types ~at kind)
  in
  let parameters =
    List.map
      (fun (name, typ) ->
        render
          (if List.mem name signature.optional then Optional (Named typ)
           else Named typ))
      signature.parameters
  in
  match signature.relation with
  | Some relation ->
      Printf.sprintf "relation %s: %s ~> %s\n  hint(input %s)" relation
        (String.concat " " parameters)
        (List.hd parameters)
        (String.concat " "
           (List.mapi (fun index _ -> "%" ^ string_of_int index) parameters))
  | None ->
      let type_parameters =
        match Call.type_parameters ~types ~at signature with
        | [] -> ""
        | names -> "<" ^ String.concat ", " names ^ ">"
      in
      Printf.sprintf "dec $%s%s(%s) : %s" signature.name type_parameters
        (String.concat ", " parameters)
        (render (Named (Option.get signature.returns)))

let declaration_of_signature ~types (signature : Typed.signature) =
  match
    Spectec.parse_spec_source
      {
        filename = "<presentation>";
        contents = string_of_signature ~types signature;
      }
  with
  | Ok [ ({ it = RelD _ | DecD _; _ } as declaration) ] -> declaration
  | _ ->
      Error.reject ~at:Common.Location.Unknown
        ("Invalid presentation declaration for " ^ signature.name)

let set_input ~ctx ~at ~branch value =
  match Value.set_element ~types:(Ctx.types ctx) ~at value.kind with
  | None -> branch
  | Some element ->
      let name = fresh_helper_name ctx ~operation:"distinct" in
      let head = fresh ctx ~at ~kind:element in
      let tail = fresh ctx ~at ~kind:(Sequence (element, None)) in
      let member = MemE (head.exp, tail.exp) $ at in
      let cons = ConsE (head.exp, tail.exp) $ at in
      emit_helper ctx
        ~definitions:
          (Value.function_definitions ~at name
             ~parameters:
               [ Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at value.kind ]
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

let translate_source ~registry ~list_results ~declarations source =
  let at = source.Typed.at and signature = source.Typed.signature in
  let ctx =
    Ctx.make source ~list_results ~registry
      ~reserved:(List.map snd signature.variables)
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
                (Error.find_or_reject ~at ~name signature.variables)
                ~typ:(Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at kind);
            kind;
          } ))
      signature.parameters
  in
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
        (fun branch (_, value) -> set_input ~ctx ~at ~branch value)
        initial environment
    in
    Stmt.translate ~ctx ~body_kind:FunctionBody source.body ~branch:initial
    |> List.map (fun (branch, completion) ->
           match completion with
           | Returned value -> (branch, value)
           | Broken | Fallthrough -> assert false)
  in
  (* An empty loop leaves its accumulator as a plain integer. Using the
     function's declared result kind would hide that number class. *)
  List.iter
    (fun (branch, value) ->
      if
        List.mem_assoc (Lang.El.Unparse.string_of_exp value.exp) branch.promoted
      then
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
                Value.conclusion_of_relation ~at declaration
                  ~values:(head branch @ [ value.exp ]),
                premises )
            $ at
        | None ->
            DefD
              ( id ~at signature.name,
                List.map (id ~at)
                  (Call.type_parameters ~types:(Ctx.types ctx) ~at signature),
                List.map (fun exp -> ExpA exp $ at) (head branch),
                value.exp,
                premises )
            $ at)
      branches
  in
  Ctx.Registry.emit registry (declaration :: definitions)

let is_declaration definition =
  match definition.it with
  | TypD _ | RelD _ | DecD _ | BuiltinDecD _ -> true
  | _ -> false

let assemble registry =
  let declarations, bodies =
    Ctx.Registry.definitions registry |> List.partition is_declaration
  in
  declarations @ bodies

let translate pyspec =
  let types = Typed.types pyspec in
  let declarations =
    List.map
      (fun (s : Typed.signature) -> (s.name, declaration_of_signature ~types s))
      (Typed.signatures pyspec)
  in
  let list_results = Typed.list_results pyspec in
  let registry = Ctx.Registry.make () in
  List.iter
    (translate_source ~registry ~list_results ~declarations)
    (Typed.sources pyspec);
  assemble registry
