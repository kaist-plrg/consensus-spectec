open Common.Source
open Lang.El
open Store
open Kind
open Operand
open Ctx
open Branch
module S = Source
module B = Python_builtins

let sequence_helper_name = "translated_set_or_append_list"

let generic_sequence_helper ctx (helper : S.sequence_helper) =
  Registry.register ctx.registry ~ownership:Shared ~name:sequence_helper_name
    ~generate:(fun () ->
      let at = helper.at in
      let source =
        {
          ctx.source with
          constants = [];
          casts = [];
          calls = [];
          locals = [ "list"; "index"; "value" ];
          types =
            ("X", { S.descriptor = S.Opaque; target = Some "X" })
            :: ctx.source.types;
        }
      in
      let generic = Ctx.for_helper ctx ~source in
      let list =
        {
          exp = IterE (var ~at "X_list", List) $ at;
          kind = Sequence (Named "X", None);
        }
      in
      let index =
        {
          exp = var ~at "validatorIndex_index";
          kind = Named Spec_names.validator_index;
        }
      in
      let value = { exp = var ~at "X_value"; kind = Named "X" } in
      let capacity = var ~at "nat_capacity" in
      let valid = var ~at "bool_valid" in
      let initial =
        Branch.make
          (Store.make [ ("list", list); ("index", index); ("value", value) ])
      in
      let write at append index branch =
        let current =
          Error.find_or_reject ~at ~name:"list" (Store.bindings branch.storage)
        in
        let branch =
          if append then
            guard ~at
              ~exp:(comparison ~at ~op:`LtOp (LenE current.exp $ at) capacity)
              branch
          else
            guard ~at
              ~exp:(comparison ~at ~op:`LeOp (nat ~at 0) index.exp)
              branch
            |> guard ~at
                 ~exp:
                   (comparison ~at ~op:`LtOp index.exp (LenE current.exp $ at))
        in
        let branch = guard ~at ~exp:valid branch in
        let exp =
          if append then CatE (current.exp, ListE [ value.exp ] $ at) $ at
          else
            UpdE
              (current.exp, IdxP (RootP $ at, unarith index.exp) $ at, value.exp)
            $ at
        in
        let branch, result =
          bind ~ctx:generic ~at branch ~term:{ current with exp }
        in
        replace_local ~name:"list" ~value:result branch
      in
      let rec translate_body nodes branch =
        match nodes with
        | [] -> [ branch ]
        | node :: rest -> (
            let at = node.at in
            match node.it with
            | Syntax.If (test, yes, no) ->
                [ (true, yes); (false, no) ]
                |> List.concat_map (fun (truth, body) ->
                       Expr.condition ~ctx:generic test ~holds:truth ~branch
                       |> List.concat_map (translate_body (body @ rest)))
            | Syntax.Expression
                {
                  it =
                    Syntax.Method
                      ( { it = Syntax.Name "list"; _ },
                        "append",
                        [ { it = Syntax.Name "value"; _ } ] );
                  _;
                } ->
                translate_body rest (write at true index branch)
            | Syntax.Assign
                ( {
                    it =
                      Syntax.Index ({ it = Syntax.Name "list"; _ }, index_node);
                    _;
                  },
                  { it = Syntax.Name "value"; _ } ) ->
                Expr.translate ~ctx:generic index_node ~branch
                |> List.concat_map (fun (branch, index) ->
                       translate_body rest (write at false index branch))
            | Syntax.Assert test ->
                Expr.condition ~ctx:generic test ~holds:true ~branch
                |> List.concat_map (translate_body rest)
            | _ ->
                Error.reject ~at
                  "Unsupported statement in the generic sequence helper")
      in
      let branches = translate_body helper.body initial in
      let sequence = Operand.typ ~types:generic.source.types ~at list.kind in
      Operand.function_definitions ~type_parameters:[ "X" ] ~at
        sequence_helper_name
        ~parameters:
          [
            sequence;
            VarT (id ~at "validatorIndex", []) $ at;
            VarT (id ~at "X", []) $ at;
            NumT `NatT $ at;
            BoolT $ at;
          ]
        ~result:sequence
        ~equations:
          (List.map
             (fun branch ->
               ( [ list.exp; index.exp; value.exp; capacity; valid ],
                 (Error.find_or_reject ~at ~name:"list"
                    (Store.bindings branch.storage))
                   .exp,
                 branch.premises ))
             branches))

let sequence_helper_call ctx at helper args branch =
  if ctx.source.signature.effect = S.Pure then
    Error.reject ~at "Sequence mutation requires a state-mutating caller";
  let receiver =
    match args with
    | [ receiver; _; _ ] -> receiver
    | _ -> Error.reject ~at "Generic sequence helper arity"
  in
  generic_sequence_helper ctx helper;
  Expr.arguments ~ctx args ~branch
  |> List.map (fun (branch, values) ->
         match values with
         | [ list; index; value ] -> (
             let element, capacity =
               match list.kind with
               | Named name -> (
                   match
                     Kind.bounded_ssz_list ~types:ctx.source.types ~at name
                   with
                   | Some result -> result
                   | None ->
                       Error.reject ~at
                         "Generic mutation requires a bounded SSZ List")
               | _ ->
                   Error.reject ~at
                     "Generic mutation requires concrete SSZ metadata"
             in
             if index.kind <> Named Spec_names.validator_index then
               Error.reject ~at "Generic list index must be ValidatorIndex";
             let valid =
               match
                 ( Kind.bits ~types:ctx.source.types ~at element,
                   Kind.bits ~types:ctx.source.types ~at value.kind )
               with
               | Some width, Some source when width = source ->
                   comparison ~at ~op:`LeOp value.exp
                     (number ~at (Numeric_ops.unsigned_maximum width))
               | Some _, Some _ -> bool ~at false
               | Some width, None
                 when Kind.is_integer ~types:ctx.source.types ~at value.kind
                 -> (
                   match value.exp.it with
                   | NumE (_, `Nat _) ->
                       comparison ~at ~op:`LeOp value.exp
                         (number ~at (Numeric_ops.unsigned_maximum width))
                   | _ ->
                       Error.reject ~at
                         "Integer variables need a reviewed SSZ conversion")
               | None, None when value.kind = element -> bool ~at true
               | _ -> Error.reject ~at "Unreviewed SSZ element conversion"
             in
             let branch, list = bind ~ctx ~at branch ~term:list in
             let branch, index = bind ~ctx ~at branch ~term:index in
             let branch, value =
               bind ~ctx ~at branch ~term:{ value with kind = element }
             in
             let result =
               {
                 kind = list.kind;
                 exp =
                   call
                     ~types:[ Operand.typ ~types:ctx.source.types ~at element ]
                     ~at sequence_helper_name
                     ~args:
                       [
                         list.exp;
                         index.exp;
                         value.exp;
                         number ~at capacity;
                         valid;
                       ];
               }
             in
             match receiver.it with
             | Syntax.Name name ->
                 let reference =
                   match
                     List.assoc_opt name (Store.references branch.storage)
                   with
                   | Some reference when reference.valid -> reference
                   | _ ->
                       Error.reject ~at
                         "Sequence receiver has no valid tracked state location"
                 in
                 if reference.location = None then
                   Error.reject ~at
                     "SSZ sequence helper requires a state-backed receiver";
                 Write.apply ~ctx ~at
                   {
                     container = result;
                     selection = RootP $ at;
                     owner = ReferenceWrite reference;
                   }
                   ~replacement:result.exp ~branch
             | _ -> Write.store ~ctx receiver ~value:result ~branch)
         | _ -> assert false)

let is_owned_list ~branch (receiver : Syntax.expr) =
  match receiver.it with
  | Syntax.Name name -> (
      match List.assoc_opt name (Store.references branch.storage) with
      | Some { location = None; valid = true; _ } -> true
      | _ -> false)
  | _ -> false

(* The generated append replaces the stored sequence and updates every alias
   that shares the list's reference identity. *)
let append_owned ctx at receiver node branch =
  let name =
    match receiver.it with Syntax.Name name -> name | _ -> assert false
  in
  let list = Error.find_or_reject ~at ~name (Store.bindings branch.storage) in
  let element, _, _ = Kind.sequence ~types:ctx.source.types ~at list.kind in
  let branch, list = bind ~ctx ~at branch ~term:list in
  Expr.translate ~ctx node ~branch
  |> List.map (fun (branch, value) ->
         if value.kind <> element then
           Error.reject ~at
             "Appending to a local list cannot convert the element";
         (if
            Kind.is_named_container_or_set ~types:ctx.source.types ~at
              value.kind
          then
            match node.it with
            | Syntax.Call (constructor, _, _)
              when value.kind = Named constructor
                   && Kind.is_flat_record ~types:ctx.source.types ~at value.kind
              ->
                ()
            | _ ->
                Error.reject ~at
                  "A local record list only accepts freshly constructed flat \
                   records");
         let branch, value = bind ~ctx ~at branch ~term:value in
         let reference =
           Error.find_or_reject ~at ~name (Store.references branch.storage)
         in
         let branch =
           Write.store ~copied:name ~ctx receiver
             ~value:
               {
                 kind = Sequence (element, None);
                 exp = CatE (list.exp, ListE [ value.exp ] $ at) $ at;
               }
             ~branch
         in
         let result =
           Error.find_or_reject ~at ~name (Store.bindings branch.storage)
         in
         update_aliases ~identity:reference.identity ~value:result branch)

let append_ssz ctx at receiver node branch =
  if ctx.source.signature.effect = S.Pure then
    Error.reject ~at "SSZ append requires a mutating caller";
  (match receiver.it with
  | Syntax.Attribute ({ it = Syntax.Name "state"; _ }, _) -> ()
  | _ -> Error.reject ~at "Append requires a direct state field or a local list");
  Expr.translate ~ctx receiver ~branch
  |> List.concat_map (fun (branch, list) ->
         let element, capacity =
           match list.kind with
           | Named name -> (
               match Kind.bounded_ssz_list ~types:ctx.source.types ~at name with
               | Some result -> result
               | None -> Error.reject ~at "Append requires a bounded SSZ List")
           | _ -> Error.reject ~at "Append requires concrete SSZ metadata"
         in
         let branch, list = bind ~ctx ~at branch ~term:list in
         Expr.translate ~ctx node ~branch
         |> List.map (fun (branch, value) ->
                if value.kind <> element then
                  Error.reject ~at "Append element conversion is unsupported";
                let branch =
                  match Kind.bits ~types:ctx.source.types ~at element with
                  | Some width ->
                      guard ~at
                        ~exp:
                          (comparison ~at ~op:`LtOp value.exp
                             (number ~at Bigint.(pow (of_int 2) (of_int width))))
                        branch
                  | None -> branch
                in
                let branch, value = bind ~ctx ~at branch ~term:value in
                let branch =
                  guard ~at
                    ~exp:
                      (comparison ~at ~op:`LtOp (LenE list.exp $ at)
                         (number ~at capacity))
                    branch
                in
                Write.store ~ctx receiver
                  ~value:
                    {
                      list with
                      exp = CatE (list.exp, ListE [ value.exp ] $ at) $ at;
                    }
                  ~branch))

let append ctx at (receiver : Syntax.expr) node branch =
  (match receiver.it with
  | Syntax.Name name -> (
      match List.assoc_opt name (Store.references branch.storage) with
      | Some { location = None; valid = false; _ } ->
          Error.reject ~at
            "Mutation of an iterated local list requires a live-iterator \
             contract"
      | _ -> ())
  | _ -> ());
  if is_owned_list ~branch receiver then
    append_owned ctx at receiver node branch
  else append_ssz ctx at receiver node branch

let nominal_type_name ctx at kind =
  match (Operand.typ ~types:ctx.source.types ~at kind).it with
  | VarT (name, []) -> name.it
  | _ ->
      Error.reject ~at "A local helper needs nominal state and operation types"

(* One shared definition for a nested source helper that applies a mutator to
   every element of a sequence. The target's function parameters carry the
   mutator, and the captured state is threaded explicitly through the
   recursion, so all call sites instantiate this one body. *)
let local_helper_definition ctx at (helper : Syntax.local_helper) =
  let name =
    "translated_" ^ ctx.source.signature.name ^ "_" ^ helper.Syntax.helper
  in
  Registry.register ctx.registry ~ownership:(Helper ctx.source.signature.name)
    ~name ~generate:(fun () ->
      let state = nominal_type_name ctx at (Named Spec_names.state_type) in
      let contents =
        Printf.sprintf
          "dec $%s<X>(%s, X*, def $f(%s, X) : %s) : %s\n\
           def $%s<X>(%s_state, eps, def $f) = %s_state\n\
           def $%s<X>(%s_state, X_element :: X_tail*, def $f) = \
           $%s<X>($f(%s_state, X_element), X_tail*, def $f)\n"
          name state state state state name state state name state name state
      in
      match
        Spectec.parse_spec_source { filename = "<local-helper>"; contents }
      with
      | Ok definitions -> definitions
      | Error _ -> Error.reject ~at ("Invalid generated local helper: " ^ name));
  name

(* A thin function wrapper around an existing generated mutator relation, so a
   local helper can receive it as a function argument. It forwards and holds no
   logic of its own. *)
let local_helper_adapter ctx at (signature : S.signature) operation =
  let name = "translated_apply_" ^ signature.S.name in
  Registry.register ctx.registry ~ownership:Shared ~name ~generate:(fun () ->
      let state_type =
        Operand.typ ~types:ctx.source.types ~at (Named Spec_names.state_type)
      in
      let operation_type =
        Operand.typ ~types:ctx.source.types ~at (Named operation)
      in
      let state =
        var ~at
          (nominal_type_name ctx at (Named Spec_names.state_type) ^ "_state")
      in
      let element =
        var ~at (nominal_type_name ctx at (Named operation) ^ "_operation")
      in
      let result =
        var ~at
          (nominal_type_name ctx at (Named Spec_names.state_type) ^ "_result")
      in
      let declaration =
        Error.find_or_reject ~at ~name:signature.S.name ctx.declarations
      in
      let relation =
        match signature.S.relation with
        | Some relation -> relation
        | None ->
            Error.reject ~at
              ("A local helper mutator needs a relation: " ^ signature.S.name)
      in
      Operand.function_definitions ~at name
        ~parameters:[ state_type; operation_type ]
        ~result:state_type
        ~equations:
          [
            ( [ state; element ],
              result,
              [
                RulePr
                  ( id ~at relation,
                    Operand.conclusion ~at declaration
                      ~values:[ state; element; result ] )
                $ at;
              ] );
          ]);
  name

let replace_state result branch = write_state ~location:[] ~value:result branch

let local_helper_call ctx at (helper : Syntax.local_helper) args branch =
  let elements_node, mutator =
    match args with
    | [ elements; { it = Syntax.Name mutator; _ } ] -> (elements, mutator)
    | _ ->
        Error.reject ~at
          "A local helper call takes one sequence and one named mutator"
  in
  if List.mem mutator ctx.source.locals then
    Error.reject ~at ("A local helper mutator cannot be shadowed: " ^ mutator);
  let signature = Expr.call_signature ~ctx ~at mutator in
  let operation =
    match (signature.S.effect, signature.S.returns, signature.S.parameters) with
    | S.MutatesState, None, [ ("state", state_type); (_, operation) ]
      when state_type = Spec_names.state_type ->
        operation
    | _ ->
        Error.reject ~at
          ("A local helper mutator takes the state and one operation: "
         ^ mutator)
  in
  Expr.translate ~ctx elements_node ~branch
  |> List.map (fun (branch, elements) ->
         let element, _, _ =
           Kind.sequence ~types:ctx.source.types ~at elements.kind
         in
         if element <> Named operation then
           Error.reject ~at
             ("A local helper element type does not match " ^ mutator);
         let name = local_helper_definition ctx at helper in
         let adapter = local_helper_adapter ctx at signature operation in
         let state =
           Error.find_or_reject ~at ~name:"state"
             (Store.bindings branch.storage)
         in
         let branch, elements = bind ~ctx ~at branch ~term:elements in
         let result = fresh ctx ~at ~kind:(Named Spec_names.state_type) in
         let applied =
           CallE
             ( id ~at name,
               [ Operand.typ ~types:ctx.source.types ~at element ],
               [
                 ExpA state.exp $ at;
                 ExpA elements.exp $ at;
                 DefA (id ~at adapter) $ at;
               ] )
           $ at
         in
         let branch =
           guard ~at ~exp:(comparison ~at ~op:`EqOp applied result.exp) branch
         in
         replace_state result branch)

let call ~ctx (node : Syntax.expr) ~branch =
  let at = node.at in
  match node.it with
  | Syntax.Method (receiver, "append", [ value ]) ->
      append ctx at receiver value branch
  | _ -> (
      let name, args, keywords =
        match node.it with
        | Syntax.Call (name, args, keywords)
          when not (List.mem name ctx.source.locals) ->
            (name, args, keywords)
        | _ -> Error.reject ~at "Mutating calls require an unshadowed name"
      in
      match List.assoc_opt name branch.local_helpers with
      | Some helper ->
          if keywords <> [] then
            Error.reject ~at "Local helpers require positional arguments";
          local_helper_call ctx at helper args branch
      | None -> (
          match
            List.find_opt
              (fun (h : S.sequence_helper) -> h.name = name)
              ctx.source.sequence_helpers
          with
          | Some helper ->
              if keywords <> [] then
                Error.reject ~at "Sequence helpers require positional arguments";
              sequence_helper_call ctx at helper args branch
          | None ->
              let signature = Expr.call_signature ~ctx ~at name in
              if signature.effect = S.Pure then
                Error.reject ~at ("State effects are not reviewed for " ^ name);
              let written, order =
                Expr.call_arguments ~at ~signature args ~keywords
              in
              (match List.hd order with
              | Some index
                when (List.nth written index).it = Syntax.Name "state" ->
                  ()
              | _ ->
                  Error.reject ~at
                    "Mutating calls require the root state argument");
              let combinations =
                Expr.arguments ~ctx written ~branch
                |> List.map (fun (branch, written) ->
                       List.fold_left_map
                         (fun branch ((_, kind), value) ->
                           match value with
                           | None ->
                               ( branch,
                                 {
                                   exp = EpsE $ at;
                                   kind = Optional (Named kind);
                                 } )
                           | Some value ->
                               if
                                 value.kind <> Named kind
                                 && not
                                      (Kind.bits ~types:ctx.source.types ~at
                                         value.kind
                                       = Some 64
                                      && Kind.bits ~types:ctx.source.types ~at
                                           (Named kind)
                                         = Some 64)
                               then
                                 Error.reject ~at
                                   "Mutating call argument conversions are \
                                    unsupported";
                               let branch, value =
                                 bind ~ctx ~at branch
                                   ~term:{ value with kind = Named kind }
                               in
                               (branch, value))
                         branch
                         (List.combine signature.parameters
                            (Call_ops.parameter_values written ~order)))
              in
              List.map
                (fun (branch, values) ->
                  let result =
                    fresh ctx ~at ~kind:(Named Spec_names.state_type)
                  in
                  let declaration =
                    Error.find_or_reject ~at ~name ctx.declarations
                  in
                  let exp =
                    Operand.conclusion ~at declaration
                      ~values:(List.map (fun t -> t.exp) values @ [ result.exp ])
                  in
                  let branch =
                    require
                      ~prem:
                        (RulePr (id ~at (Option.get signature.relation), exp)
                        $ at)
                      branch
                  in
                  replace_state result branch)
                combinations))
