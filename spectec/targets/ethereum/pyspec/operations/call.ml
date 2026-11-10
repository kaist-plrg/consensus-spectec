open Common.Annotated
open Lang.El
open Value
open Ctx
open Branch

let bind_arguments ~at ~(signature : Typed.signature) args ~keywords =
  (* Python evaluates keyword argument expressions where they are
     written, then binds them to parameters by name. The written
     order drives evaluation and the parameter order drives the
     generated call. *)
  let written = args @ List.map snd keywords in
  if List.length args > List.length signature.parameters then
    Error.reject ~at "Call arity";
  let order =
    List.mapi
      (fun index (parameter, _) ->
        if index < List.length args then Some index
        else
          match
            List.find_index (fun (keyword, _) -> keyword = parameter) keywords
          with
          | Some offset -> Some (List.length args + offset)
          | None when List.mem parameter signature.optional -> None
          | None when List.mem_assoc parameter signature.defaults -> None
          | None ->
              Error.reject ~at ("Missing argument for parameter " ^ parameter))
      signature.parameters
  in
  if
    List.sort Int.compare (List.filter_map Fun.id order)
    <> List.init (List.length written) Fun.id
  then Error.reject ~at "Keyword arguments must bind each parameter once";
  (* A parameter with a literal default that this call omits is evaluated after
     every written argument, which is where Python binds it and where it cannot
     reorder the written evaluations. *)
  let written, order =
    List.fold_left2
      (fun (written, order) slot (parameter, _) ->
        match (slot, List.assoc_opt parameter signature.defaults) with
        | None, Some value ->
            ( written @ [ Syntax.Bool value $ at ],
              order @ [ Some (List.length written) ] )
        | _ -> (written, order @ [ slot ]))
      (written, []) order signature.parameters
  in
  (* An omitted argument and a written None both bind the None
     default, and neither evaluates to a value. *)
  let supplied, positions, _ =
    List.fold_left
      (fun (supplied, positions, next) (node : Syntax.expr) ->
        if node.it = Syntax.NoneValue then (supplied, None :: positions, next)
        else (node :: supplied, Some next :: positions, next + 1))
      ([], [], 0) written
  in
  let positions = List.rev positions in
  let order =
    List.map2
      (fun slot (parameter, _) ->
        let slot = Option.bind slot (List.nth positions) in
        if slot = None && not (List.mem parameter signature.optional) then
          Error.reject ~at ("Parameter " ^ parameter ^ " cannot be None");
        slot)
      order signature.parameters
  in
  (List.rev supplied, order)

let type_parameters ~types ~at (signature : Typed.signature) =
  List.filter_map
    (fun (_, name) ->
      if Typed.descriptor_of_name ~types ~at name = Typed.SszParameter then
        Some name
      else None)
    signature.parameters
  |> List.fold_left
       (fun parameters name ->
         if List.mem name parameters then parameters else parameters @ [ name ])
       []

let type_arguments ~ctx ~at (signature : Typed.signature) ~supplied ~branch =
  let type_parameters = type_parameters ~types:(Ctx.types ctx) ~at signature in
  let branch, instantiations =
    List.fold_left2
      (fun (branch, instantiations) value (_, expected) ->
        if
          Typed.descriptor_of_name ~types:(Ctx.types ctx) ~at expected
          <> Typed.SszParameter
        then (branch, instantiations)
        else
          match value with
          | None ->
              Error.reject ~at "Optional SSZ type parameters are unsupported"
          | Some value ->
              let typ = Ssz_ops.targ_of_kind ~ctx ~at value.kind in
              (match List.assoc_opt expected instantiations with
              | Some previous
                when Lang.El.Unparse.string_of_plaintyp previous
                     <> Lang.El.Unparse.string_of_plaintyp typ ->
                  Error.reject ~at
                    "Inconsistent SSZ type parameter instantiation"
              | _ -> ());
              ( Ssz_ops.validity_guards ~ctx ~at value ~branch,
                (expected, typ) :: instantiations ))
      (branch, []) supplied signature.parameters
  in
  ( branch,
    List.map
      (fun name -> Error.find_or_reject ~at ~name instantiations)
      type_parameters )

let parameter_values written ~order =
  List.map (Option.map (List.nth written)) order

let invoke ~ctx ~at (signature : Typed.signature) ~list_result ~supplied ~branch
    =
  let returns = Named (Option.get signature.returns) in
  let branch, type_arguments =
    type_arguments ~ctx ~at signature ~supplied ~branch
  in
  let values =
    List.map2
      (fun value (parameter, expected) ->
        match value with
        | None -> EpsE $ at
        | Some value ->
            Value.check_set_value ~types:(Ctx.types ctx) ~at value.kind
              ~expected:
                (Value.set_element ~types:(Ctx.types ctx) ~at (Named expected))
              ~diagnostic:"Set arguments require a matching set parameter";
            Value.check_number_class ~types:(Ctx.types ctx) ~at value.kind
              ~declared:(Named expected)
              ~diagnostic:
                "Arguments keep their number class, which must match the \
                 parameter annotation";
            if
              List.mem parameter signature.optional
              && value.kind <> Named expected
            then
              Error.reject ~at
                "An optional argument needs the declared parameter type";
            value.exp)
      supplied signature.parameters
  in
  ( branch,
    {
      exp = call ~types:type_arguments ~at signature.name ~args:values;
      kind =
        (if list_result then
           let { Value.element; _ } =
             Value.sequence ~types:(Ctx.types ctx) ~at returns
           in
           PythonList element
         else returns);
    } )

let replace_state result branch = write_state ~location:[] ~value:result branch

let mutator_arguments ~at (signature : Typed.signature) args ~keywords =
  if signature.effect = Typed.Pure then
    Error.reject ~at ("State effects are not reviewed for " ^ signature.name);
  let written, order = bind_arguments ~at ~signature args ~keywords in
  (match List.hd order with
  | Some index
    when (List.nth written index).it = Syntax.Name Names.state_parameter ->
      ()
  | _ -> Error.reject ~at "Mutating calls require the root state argument");
  (written, order)

let mutate ~ctx ~at (signature : Typed.signature) ~order alternatives =
  let combinations =
    alternatives
    |> List.map (fun (branch, written) ->
           List.fold_left_map
             (fun branch ((_, kind), value) ->
               match value with
               | None ->
                   (branch, { exp = EpsE $ at; kind = Optional (Named kind) })
               | Some value ->
                   if
                     value.kind <> Named kind
                     && not
                          (Value.is_same_number_class ~types:(Ctx.types ctx) ~at
                             value.kind (Named kind))
                   then
                     Error.reject ~at
                       "Mutating call argument conversions are unsupported";
                   let branch, value =
                     bind ~ctx ~at branch ~term:{ value with kind = Named kind }
                   in
                   (branch, value))
             branch
             (List.combine signature.parameters
                (parameter_values written ~order)))
  in
  List.map
    (fun (branch, values) ->
      let result = fresh ctx ~at ~kind:(Named Names.state_type) in
      let declaration =
        Error.find_or_reject ~at ~name:signature.name (Ctx.declarations ctx)
      in
      let exp =
        Value.conclusion_of_relation ~at declaration
          ~values:(List.map (fun t -> t.exp) values @ [ result.exp ])
      in
      let branch =
        require
          ~prem:(RulePr (id ~at (Option.get signature.relation), exp) $ at)
          branch
      in
      replace_state result branch)
    combinations

let type_name_of_kind ~ctx ~at kind =
  match (Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at kind).it with
  | VarT (name, []) -> name.it
  | _ ->
      Error.reject ~at "A local helper needs nominal state and operation types"

(* A local helper takes a function argument, so this adapter wraps the mutator
   relation in a function. *)
let local_helper_adapter ~ctx ~at (signature : Typed.signature) ~operation =
  let name = "translated_apply_" ^ signature.Typed.name in
  Ctx.share_helper ctx ~name ~definitions:(fun () ->
      let state_type =
        Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at
          (Named Names.state_type)
      in
      let operation_type =
        Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at (Named operation)
      in
      let state =
        var ~at (type_name_of_kind ~ctx ~at (Named Names.state_type) ^ "_state")
      in
      let element =
        var ~at (type_name_of_kind ~ctx ~at (Named operation) ^ "_operation")
      in
      let result =
        var ~at (type_name_of_kind ~ctx ~at (Named Names.state_type) ^ "_result")
      in
      let declaration =
        Error.find_or_reject ~at ~name:signature.Typed.name
          (Ctx.declarations ctx)
      in
      let relation =
        match signature.Typed.relation with
        | Some relation -> relation
        | None ->
            Error.reject ~at
              ("A local helper mutator needs a relation: "
             ^ signature.Typed.name)
      in
      Value.function_definitions ~at name
        ~parameters:[ state_type; operation_type ]
        ~result:state_type
        ~equations:
          [
            ( [ state; element ],
              result,
              [
                RulePr
                  ( id ~at relation,
                    Value.conclusion_of_relation ~at declaration
                      ~values:[ state; element; result ] )
                $ at;
              ] );
          ]);
  name

let local_helper_arguments ~ctx ~at args =
  let elements, mutator =
    match args with
    | [ elements; { it = Syntax.Name mutator; _ } ] -> (elements, mutator)
    | _ ->
        Error.reject ~at
          "A local helper call takes one sequence and one named mutator"
  in
  let signature =
    match Typed.role_of_name (Ctx.source ctx) mutator with
    | Some Typed.Local ->
        Error.reject ~at
          ("A local helper mutator cannot be shadowed: " ^ mutator)
    | Some (Typed.Function signature) -> signature
    | _ -> Error.reject ~at ("Call effects are not reviewed for " ^ mutator)
  in
  let operation =
    match
      ( signature.Typed.effect,
        signature.Typed.returns,
        signature.Typed.parameters )
    with
    | Typed.MutatesState, None, [ (parameter, state_type); (_, operation) ]
      when parameter = Names.state_parameter && state_type = Names.state_type ->
        operation
    | _ ->
        Error.reject ~at
          ("A local helper mutator takes the state and one operation: "
         ^ mutator)
  in
  (elements, signature, operation)

let local_helper ~ctx ~at ~(mutator : Typed.signature) ~operation ~branch
    elements =
  let { Value.element; _ } =
    Value.sequence ~types:(Ctx.types ctx) ~at elements.kind
  in
  if element <> Named operation then
    Error.reject ~at
      ("A local helper element type does not match " ^ mutator.Typed.name);
  let adapter = local_helper_adapter ~ctx ~at mutator ~operation in
  let state =
    Error.find_or_reject ~at ~name:Names.state_parameter
      (Store.bindings branch.storage)
  in
  let branch, elements = bind ~ctx ~at branch ~term:elements in
  let result = fresh ctx ~at ~kind:(Named Names.state_type) in
  let applied =
    CallE
      ( id ~at "translated_apply_each",
        [ Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at element ],
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
  replace_state result branch

let aggregate_pubkeys ~ctx ~at ~branch value =
  let { Value.element; _ } =
    Value.sequence ~types:(Ctx.types ctx) ~at value.kind
  in
  if element <> Named Names.bls_pubkey then
    Error.reject ~at "AggregatePKs requires BLSPubkey sequence";
  let branch, value = Branch.bind ~ctx ~at branch ~term:value in
  let branch =
    Branch.guard ~at
      ~exp:(comparison ~at ~op:`GtOp (LenE value.exp $ at) (nat ~at 0))
      branch
  in
  Branch.check_promoted_capture ~at branch;
  let validate initial _index item =
    let initial, valid =
      Prelude.invoke_primitive ~ctx ~at Library.key_validate ~branch:initial
        ~values:[ item ]
    in
    ([ Branch.bind ~ctx ~at initial ~term:valid ], [])
  in
  let branch, validity =
    Loop.map ~ctx ~at ~captures:[] ~element:validate ~branch value
  in
  let branch, valid = Sequence_ops.all ~ctx ~at ~branch validity in
  let branch = Branch.guard ~at ~exp:valid.exp branch in
  ( branch,
    {
      exp = Prelude.aggregate_pubkeys ~at value.exp;
      kind = Named Names.bls_pubkey;
    } )
