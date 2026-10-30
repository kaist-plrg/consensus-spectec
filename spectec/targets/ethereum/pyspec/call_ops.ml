open Common.Source
open Lang.El
open Kind
open Operand
module S = Source

let signature ~ctx ~at name : S.signature =
  match
    List.find_opt (fun (s : S.signature) -> s.name = name) ctx.Ctx.source.calls
  with
  | Some s -> s
  | None -> Error.reject ~at ("Call effects are not reviewed for " ^ name)

let bind_arguments ~at ~(signature : S.signature) args ~keywords =
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

let type_parameters ~ctx ~at (signature : S.signature) =
  List.filter_map
    (fun (_, name) ->
      if Kind.descriptor ~types:(Ctx.types ctx) ~at name = S.SszParameter then
        Some name
      else None)
    signature.parameters
  |> List.fold_left
       (fun parameters name ->
         if List.mem name parameters then parameters else parameters @ [ name ])
       []

let type_arguments ~ctx ~at (signature : S.signature) ~supplied ~branch =
  let type_parameters = type_parameters ~ctx ~at signature in
  let branch, instantiations =
    List.fold_left2
      (fun (branch, instantiations) value (_, expected) ->
        if Kind.descriptor ~types:(Ctx.types ctx) ~at expected <> S.SszParameter
        then (branch, instantiations)
        else
          match value with
          | None ->
              Error.reject ~at "Optional SSZ type parameters are unsupported"
          | Some value ->
              let typ = Ssz_ops.type_argument ~ctx ~at value.kind in
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
      (fun name ->
        match List.assoc_opt name instantiations with
        | Some value -> value
        | None -> Error.reject ~at ("Unresolved name: " ^ name))
      type_parameters )

let parameter_values written ~order =
  List.map (Option.map (List.nth written)) order

let invoke ~ctx ~at (signature : S.signature) ~list_result ~supplied ~branch =
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
            Kind.check_set_value ~types:(Ctx.types ctx) ~at value.kind
              ~expected:
                (Kind.set_element ~types:(Ctx.types ctx) ~at (Named expected))
              ~diagnostic:"Set arguments require a matching set parameter";
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
           let element, _, _ =
             Kind.sequence ~types:(Ctx.types ctx) ~at returns
           in
           PythonList element
         else returns);
    } )

let invoke_primitive ~ctx ~at (primitive : Python_builtins.primitive_contract)
    ~branch ~values =
  let accepts operand value =
    match operand with
    | Python_builtins.Exact kind -> value.kind = kind
    | Python_builtins.Bytes width ->
        Kind.byte_width ~types:(Ctx.types ctx) ~at value.kind
        = Some (Bigint.of_int width)
    | Python_builtins.Sequence expected ->
        let element, _, _ =
          Kind.sequence ~types:(Ctx.types ctx) ~at value.kind
        in
        element = expected
  in
  if not (List.for_all2 accepts primitive.operands values) then
    Error.reject ~at primitive.operand_error;
  let result =
    {
      exp =
        call ~at primitive.name ~args:(List.map (fun value -> value.exp) values);
      kind = primitive.result;
    }
  in
  if primitive.bind_result then Branch.bind ~ctx ~at branch ~term:result
  else (branch, result)

let notify_new_payload ~ctx ~at ~branch payload =
  if payload.kind <> Named Source.Contracts.execution_payload then
    Error.reject ~at "Expected an execution payload";
  Branch.bind ~ctx ~at branch
    ~term:
      {
        exp = Target_builtins.notify_new_payload ~ctx ~at payload.exp;
        kind = Kind.boolean;
      }

let aggregate_pubkeys ~ctx ~at ~branch value =
  let element, _, _ = Kind.sequence ~types:(Ctx.types ctx) ~at value.kind in
  if element <> Named Source.Contracts.bls_pubkey then
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
      invoke_primitive ~ctx ~at Python_builtins.key_validate ~branch:initial
        ~values:[ item ]
    in
    ([ Branch.bind ~ctx ~at initial ~term:valid ], [])
  in
  let branch, validity =
    Sequence_ops.map ~ctx ~at ~captures:[] ~element:validate ~branch value
  in
  let branch, valid = Sequence_ops.all ~ctx ~at ~branch validity in
  let branch = Branch.guard ~at ~exp:valid.exp branch in
  ( branch,
    {
      exp = Target_builtins.aggregate_pubkeys ~ctx ~at value.exp;
      kind = Named Source.Contracts.bls_pubkey;
    } )
