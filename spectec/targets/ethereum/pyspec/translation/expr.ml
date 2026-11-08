open Common.Annotated
open Lang.El
open Store
open Value
open Ctx
open Branch

let captures ~at ~branch ~bound nodes =
  let names = List.concat_map Syntax.free_names nodes in
  Store.bindings branch.storage
  |> List.filter (fun (name, _) ->
         List.mem name names && not (List.mem name bound))
  |> List.map (fun ((_, value) as binding) ->
         (match value.kind with
         | Optional _ -> Error.reject ~at "Optional comprehension capture"
         | _ -> ());
         binding)

let collect_values step branch nodes =
  List.fold_left
    (fun combinations node ->
      List.concat_map
        (fun (branch, reversed) ->
          List.map
            (fun (branch, value) -> (branch, value :: reversed))
            (step branch node))
        combinations)
    [ (branch, []) ]
    nodes
  |> List.map (fun (branch, reversed) -> (branch, List.rev reversed))

(* [select false] gives paths where this node decides the result, and [select
   true] continues to the next node. Calling [select] may allocate names, so its
   call order determines those names. *)
let short_circuit ~require_all selector branches nodes =
  let live, stopped =
    List.fold_left
      (fun (live, stopped) node ->
        let select = selector node live in
        let stopped =
          if require_all then stopped
          else List.rev_append (select false) stopped
        in
        let live = select true in
        (live, stopped))
      (branches, []) nodes
  in
  if require_all then live else List.rev stopped

let truth_condition ~ctx ~at ~holds ~branch value =
  if
    Value.is_integer ~types:(Ctx.types ctx) ~at value.kind
    || Value.bits ~types:(Ctx.types ctx) ~at value.kind <> None
  then
    guard ~at
      ~exp:
        (comparison ~at
           ~op:(if holds then `NeOp else `EqOp)
           value.exp (nat ~at 0))
      branch
  else (
    if not (Value.is_boolean ~types:(Ctx.types ctx) ~at value.kind) then
      Error.reject ~at "Non-boolean truthiness";
    guard_boolean_condition ~at ~holds ~exp:value.exp branch)

let value_of_constant ~ctx ~at name =
  let kind, value = Error.find_or_reject ~at ~name (Ctx.source ctx).constants in
  let kind =
    match value with
    | Typed.IntegerConstant _ -> Named kind
    | Typed.SequenceConstant values -> (
        match Typed.descriptor_of_name ~types:(Ctx.types ctx) ~at kind with
        | Typed.Sequence { element; _ } ->
            FrozenSequence (Named element, Bigint.of_int (List.length values))
        | _ -> Error.reject ~at "Sequence constant type")
  in
  ({ exp = call ~at name ~args:[]; kind }, value)

let rec static_integer ~ctx (node : Syntax.expr) =
  match node.it with
  | Syntax.Int value -> value
  | Syntax.Negate value -> Bigint.(zero - static_integer ~ctx value)
  | Syntax.Name name
    when Typed.role_of_name (Ctx.source ctx) name <> Some Typed.Local -> (
      match snd (value_of_constant ~ctx ~at:node.at name) with
      | Typed.IntegerConstant value -> value
      | _ -> Error.reject ~at:node.at "Expected an integer constant")
  | Syntax.Binary (((Syntax.Add | Syntax.Sub) as op), left, right) ->
      let l = static_integer ~ctx left and r = static_integer ~ctx right in
      (if op = Syntax.Add then Bigint.( + ) else Bigint.( - )) l r
  | _ ->
      Error.reject ~at:node.at
        "Slice bounds must be integer literals or constants"

(* Python clamps byte-slice bounds above the length but counts negative bounds
   from the end. Negative bounds must be rejected here, since clamping them to
   zero would turn [0 - 1 :] into [0:]. *)
let clamp_byte_slice_bound ~at ~length ~diagnostic value =
  if Bigint.compare value Bigint.zero < 0 then Error.reject ~at diagnostic
  else Bigint.min value length

let byte_slice ~ctx ~at ~branch base ~lower ~upper ~step =
  if step <> None then Error.reject ~at "Stepped byte slices are unsupported";
  let width =
    match Value.byte_width ~types:(Ctx.types ctx) ~at base.kind with
    | Some width -> width
    | None -> Error.reject ~at "Byte slices require a fixed source width"
  in
  let bound =
    clamp_byte_slice_bound ~at ~length:width
      ~diagnostic:
        "Byte slices require a nonnegative resolved bound; a negative bound is \
         relative to length and unsupported"
  in
  let start =
    bound
      (match lower with None -> Bigint.zero | Some n -> static_integer ~ctx n)
  in
  let finish =
    bound (match upper with None -> width | Some n -> static_integer ~ctx n)
  in
  let count = Bigint.max Bigint.zero Bigint.(finish - start) in
  let branch, bytes_ = Byte_ops.bytes_of_value ~ctx ~at ~branch base in

  bind ~ctx ~at branch
    ~term:
      {
        exp =
          Prelude.bytes_slice ~at bytes_.exp ~start:(number ~at start)
            ~count:(number ~at count);
        kind = ByteString count;
      }

let bind_tuple_targets ~ctx ~at ~arity_error ~branch ~targets item =
  let elements = Value.product ~types:(Ctx.types ctx) ~at item.kind in
  if List.length elements <> List.length targets then
    Error.reject ~at arity_error;
  let values = List.map (fun kind -> fresh ctx ~at ~kind) elements in
  let branch =
    guard ~at
      ~exp:
        (comparison ~at ~op:`EqOp item.exp
           (TupleE (List.map (fun value -> value.exp) values) $ at))
      branch
  in
  List.fold_left2
    (fun branch name value -> replace_local ~name ~value branch)
    branch targets values

let read_name ~ctx ~at ~branch name =
  match List.assoc_opt name (Store.bindings branch.storage) with
  | Some { kind = Optional _; _ } ->
      (* Only an identity test against None consumes an optional value, so
         every other reader needs the presence decided first. *)
      Error.reject ~at
        ("An optional value needs a None test before use: " ^ name)
  | Some value -> value
  | None when Typed.role_of_name (Ctx.source ctx) name = Some Typed.Local ->
      Error.reject ~at ("Read before local assignment: " ^ name)
  | None
    when name = Names.execution_engine_global
         && Typed.role_of_name (Ctx.source ctx) name = Some Typed.LibraryBinding
    ->
      { exp = TupleE [] $ at; kind = Named Names.execution_engine }
  | None -> fst (value_of_constant ~ctx ~at name)

type callee =
  | Local
  | LocalHelper of Syntax.local_helper
  | SetOrAppendList
  | Constructor
  | Builtin of Library.t
  | Cast
  | Function of Typed.signature
  | Unsupported

let callee_of_name ~ctx ~branch name =
  match
    ( Typed.role_of_name (Ctx.source ctx) name,
      List.assoc_opt name branch.local_helpers )
  with
  | Some Typed.Local, _ -> Local
  | _, Some helper -> LocalHelper helper
  | Some Typed.SetOrAppendList, None -> SetOrAppendList
  | Some Typed.Constructor, None -> Constructor
  | Some Typed.LibraryBinding, None -> (
      match Library.of_name name with
      | Some builtin -> Builtin builtin
      | None -> Unsupported)
  | Some Typed.Cast, None -> Cast
  | Some (Typed.Function signature), None -> Function signature
  | None, None -> Unsupported

let builtin_of_name ~ctx ~branch name =
  match callee_of_name ~ctx ~branch name with
  | Builtin builtin -> Some builtin
  | _ -> None

let is_nonnegative_range ~ctx ~branch (node : Syntax.expr) =
  match node.it with
  | Syntax.Call (name, args, [])
    when builtin_of_name ~ctx ~branch name = Some Library.Range -> (
      match args with
      | [ _ ] -> true
      | [ start; _ ] -> (
          try Bigint.compare (static_integer ~ctx start) Bigint.zero >= 0
          with Error.Rejected _ -> false)
      | _ -> false)
  | _ -> false

(* An enumerate target binds the iteration counter [index] to its first name. *)
let bind_loop_targets ~ctx ~at ~arity_error ~iterated ~enumerated ~target ~index
    ~branch item =
  let branch =
    if is_nonnegative_range ~ctx ~branch iterated then
      guard ~at ~exp:(comparison ~at ~op:`LeOp (nat ~at 0) item.exp) branch
    else branch
  in
  let targets = Syntax.target_names target in
  match target with
  | _ when enumerated ->
      replace_local ~name:(List.nth targets 0) ~value:index branch
      |> replace_local ~name:(List.nth targets 1) ~value:item
  | Syntax.Unpacked _ ->
      bind_tuple_targets ~ctx ~at ~arity_error ~branch ~targets item
  | Syntax.Single name -> replace_local ~name ~value:item branch

let enumeration ~ctx ~at ~branch ~target_error (iterable : Syntax.expr) target =
  match (iterable.it, target) with
  | Syntax.Call (name, [ value ], []), Syntax.Unpacked [ _; _ ]
    when builtin_of_name ~ctx ~branch name = Some Library.Enumerate ->
      (true, value)
  | _, (Syntax.Single _ | Syntax.Unpacked (_ :: _)) -> (false, iterable)
  | _, Syntax.Unpacked [] -> Error.reject ~at target_error

let state_backed ~branch (node : Syntax.expr) value =
  origin branch ~value <> None
  ||
  match node.it with
  | Syntax.Name name -> (
      match List.assoc_opt name (Store.references branch.storage) with
      | Some { location = Some _; _ } -> true
      | _ -> false)
  | _ -> false

let binary_operator ~ctx ~at ~op ~branch left right =
  (* An accumulated loop result is a plain integer only when the loop body
     never ran, so it may only meet an operand that coerces it exactly as the
     unsigned class the body produced would. This runs before the operator
     dispatch, so byte, bitwise and shift operands are covered too. *)
  List.iter
    (fun (value, other) ->
      match
        List.assoc_opt
          (Lang.El.Unparse.string_of_exp value.exp)
          branch.Branch.promoted
      with
      | Some kind
        when Value.bits ~types:(Ctx.types ctx) ~at other.kind
             <> Value.bits ~types:(Ctx.types ctx) ~at kind ->
          Error.reject ~at
            "An accumulated loop result needs an operand of the unsigned width \
             its loop produced"
      | _ -> ())
    [ (left, right); (right, left) ];
  if
    op = Syntax.Add
    && Value.byte_width ~types:(Ctx.types ctx) ~at left.kind <> None
    && Value.byte_width ~types:(Ctx.types ctx) ~at right.kind <> None
  then Byte_ops.concat ~ctx ~at ~branch left ~right
  else if
    op = Syntax.Add
    &&
    match (left.kind, right.kind) with
    | Sequence _, Sequence _
    | Empty, Sequence _
    | Sequence _, Empty
    | Empty, Empty ->
        true
    | _ -> false
  then Sequence_ops.concat ~ctx ~at ~branch left ~right
  else if List.mem op Syntax.[ BitAnd; BitOr; BitXor ] then
    Numeric_ops.bitwise ~ctx ~at ~op ~branch left right
  else Numeric_ops.binary ~ctx ~at ~op ~branch left right

let complement = function
  | `EqOp -> `NeOp
  | `NeOp -> `EqOp
  | `LtOp -> `GeOp
  | `LeOp -> `GtOp
  | `GtOp -> `LeOp
  | `GeOp -> `LtOp

let cmpop_of_syntax = function
  | Syntax.Eq -> `EqOp
  | Syntax.NotEq -> `NeOp
  | Syntax.Lt -> `LtOp
  | Syntax.LtE -> `LeOp
  | Syntax.Gt -> `GtOp
  | Syntax.GtE -> `GeOp
  | _ -> assert false

(* Operand conversions run once before either truth value is selected. The
   converted right operand continues a chained comparison. *)
let comparison_operator ~ctx ~at ~op ~branch left right =
  let branch, left, right =
    match
      ( Value.is_byte_valued ~types:(Ctx.types ctx) ~at left.kind,
        Value.is_byte_valued ~types:(Ctx.types ctx) ~at right.kind )
    with
    | false, false -> (branch, left, right)
    | true, true when List.mem op Syntax.[ Eq; NotEq ] ->
        let branch, left = Byte_ops.bytes_of_value ~ctx ~at ~branch left in
        let branch, right = Byte_ops.bytes_of_value ~ctx ~at ~branch right in
        (branch, left, right)
    | _ ->
        Error.reject ~at "Byte comparisons require equality between byte values"
  in
  if
    Value.set_element ~types:(Ctx.types ctx) ~at left.kind <> None
    || Value.set_element ~types:(Ctx.types ctx) ~at right.kind <> None
  then Error.reject ~at "Set comparisons require a membership contract";
  let op = cmpop_of_syntax op in
  ( branch,
    (fun holds ->
      Value.comparison ~at
        ~op:(if holds then op else complement op)
        left.exp right.exp),
    right )

let rec translate ~ctx (node : Syntax.expr) ~branch =
  let at = node.at in
  match node.it with
  | Syntax.Name name -> [ (branch, read_name ~ctx ~at ~branch name) ]
  | Syntax.Int value ->
      if Bigint.compare value Bigint.zero < 0 then
        Error.reject ~at "Negative literals require unary-minus support";
      [ (branch, { exp = number ~at value; kind = Value.integer }) ]
  | Syntax.Negate value ->
      translate ~ctx value ~branch
      |> List.map (fun (branch, value) ->
             Numeric_ops.negate ~ctx ~at ~branch value)
  | Syntax.BytesLiteral value -> [ (branch, Byte_ops.bytes_of_hex ~at value) ]
  | Syntax.Bool value ->
      [ (branch, { exp = bool ~at value; kind = Value.boolean }) ]
  | Syntax.Empty -> [ (branch, { exp = EpsE $ at; kind = Empty }) ]
  | Syntax.NoneValue ->
      (* None is only a value of an optional parameter, so it is admitted as
         an identity comparison and as an omitted argument, never as a value
         that a general expression can carry. *)
      Error.reject ~at "None is only supported in an identity comparison"
  | Syntax.Attribute (base, field) ->
      translate ~ctx base ~branch
      |> List.map (fun (branch, base) ->
             let kind =
               Named
                 (Error.find_or_reject ~at ~name:field
                    (Value.fields ~types:(Ctx.types ctx) ~at base.kind))
             in
             remember_origin branch ~base ~step:(Field field)
               ~value:{ exp = DotE (base.exp, atom ~at field) $ at; kind })
  | Syntax.Index (base, { it = Syntax.Slice (lower, upper, step); _ }) ->
      translate ~ctx base ~branch
      |> List.concat_map (fun (branch, base) ->
             if Value.is_byte_valued ~types:(Ctx.types ctx) ~at base.kind then
               [ byte_slice ~ctx ~at ~branch base ~lower ~upper ~step ]
             else
               let { Value.element; length; bitvector } =
                 Value.sequence ~types:(Ctx.types ctx) ~at base.kind
               in
               match base.kind with
               | Sequence _ | FrozenSequence _ -> (
                   match (lower, upper, step) with
                   | None, Some upper, None ->
                       translate ~ctx upper ~branch
                       |> List.concat_map (fun (branch, upper) ->
                              Sequence_ops.prefix_slice ~ctx ~at ~element
                                ~branch base ~upper)
                   | _ ->
                       Error.reject ~at
                         "Python list slicing requires a prefix and no step")
               | _ ->
                   if not bitvector then
                     Error.reject ~at "Slicing requires a fixed SSZ bitvector";
                   let length = Option.get length in
                   let branch = Sequence_ops.shape ~ctx ~at ~branch base in
                   let branch, start, finish =
                     slice_bounds ~ctx ~at ~branch length ~lower ~upper ~step
                   in
                   Sequence_ops.bitvector_slice ~at ~element ~branch base ~start
                     ~finish)
  | Syntax.Index (base, index) ->
      expression_pair ~ctx base index ~branch ~finish:(fun branch base index ->
          if Value.is_byte_valued ~types:(Ctx.types ctx) ~at base.kind then
            Byte_ops.index ~ctx ~at ~branch base ~index
          else
            let branch, index =
              Sequence_ops.normalize_index ~ctx ~at ~branch base ~index
            in
            let branch, value =
              Sequence_ops.read_index ~ctx ~at ~branch base ~index
            in
            remember_origin branch ~base ~step:(Element index) ~value)
  | Syntax.ListLiteral nodes ->
      arguments ~ctx nodes ~branch
      |> List.map (fun (branch, values) ->
             Sequence_ops.list_literal ~ctx ~at ~branch values)
  | Syntax.Tuple _ | Syntax.Lambda _ ->
      Error.reject ~at
        "Tuples require membership and lambdas require immediate set/filter \
         consumption"
  | Syntax.Method (receiver, method_, [ request ])
    when method_ = Names.new_payload_method ->
      (match Typed.role_of_name (Ctx.source ctx) Names.new_payload_request with
      | Some Typed.LibraryBinding -> ()
      | Some Typed.Local ->
          Error.reject ~at
            "Calls through locally bound names: NewPayloadRequest"
      | _ -> Error.reject ~at "Unreviewed execution-payload request");
      let payload =
        match request.it with
        | Syntax.Call (name, [], [ (keyword, payload) ])
          when name = Names.new_payload_request
               && keyword = Names.execution_payload_keyword ->
            payload
        | _ ->
            Error.reject ~at
              "The external engine requires an immediate execution-payload \
               request"
      in
      translate ~ctx receiver ~branch
      |> List.concat_map (fun (branch, receiver) ->
             if receiver.kind <> Named Names.execution_engine then
               Error.reject ~at "Expected an external execution engine";
             translate ~ctx payload ~branch
             |> List.map (fun (branch, payload) ->
                    Prelude.notify_new_payload ~ctx ~at ~branch payload))
  | Syntax.Method (receiver, "intersection", [ other ]) ->
      intersection ~ctx ~at receiver ~other ~branch
  | Syntax.Method (receiver, "count", [ needle ]) ->
      search ~ctx ~at ~search:Sequence_ops.Count receiver ~needle ~branch
  | Syntax.Method (receiver, "index", [ needle ]) ->
      search ~ctx ~at ~search:Sequence_ops.Index receiver ~needle ~branch
  | Syntax.Method _ ->
      Error.reject ~at "Method calls require a reviewed sequence operation"
  | Syntax.Slice _ -> Error.reject ~at "Slice outside subscript"
  | Syntax.Binary
      ( Syntax.Mult,
        { it = Syntax.ListLiteral [ item ]; _ },
        { it = Syntax.Call (len, [ sequence ], []); _ } )
    when builtin_of_name ~ctx ~branch len = Some (Library.Eager Library.Length)
    ->
      repeat ~ctx ~at ~item sequence ~branch
  | Syntax.Binary (Syntax.Mult, { it = Syntax.BytesLiteral value; _ }, count)
  | Syntax.Binary (Syntax.Mult, count, { it = Syntax.BytesLiteral value; _ }) ->
      translate ~ctx count ~branch
      |> List.map (fun (branch, value_count) ->
             if
               not
                 (Value.is_integer ~types:(Ctx.types ctx) ~at value_count.kind
                 || Value.bits ~types:(Ctx.types ctx) ~at value_count.kind
                    <> None)
             then
               Error.reject ~at
                 "Byte literal repetition requires an integer count";
             let count = static_integer ~ctx count in
             let representable = Bigint.of_int Sys.max_string_length in
             if
               Bigint.compare count representable > 0
               || Bigint.compare count Bigint.(zero - representable) < 0
             then
               Error.reject ~at
                 "Byte literal repetition exceeds the representable source size";
             let count =
               if Bigint.compare count Bigint.zero < 0 then Bigint.zero
               else count
             in
             if value = "" then (branch, Byte_ops.bytes_of_hex ~at "")
             else (
               if
                 Bigint.compare count
                   (Bigint.of_int (Sys.max_string_length / String.length value))
                 > 0
               then
                 Error.reject ~at
                   "Byte literal repetition exceeds the representable source \
                    size";
               let repeated =
                 String.concat ""
                   (List.init (Bigint.to_int_exn count) (fun _ -> value))
               in
               (branch, Byte_ops.bytes_of_hex ~at repeated)))
  | Syntax.Binary (Syntax.Pow, base, exponent) ->
      expression_pair ~ctx base exponent ~branch
        ~finish:(fun branch base exponent ->
          Numeric_ops.power ~ctx ~at ~branch base ~exponent)
  | Syntax.Binary (op, left, right) ->
      expression_pair ~ctx left right ~branch ~finish:(fun branch ->
          binary_operator ~ctx ~at ~op ~branch)
  | Syntax.Conditional (test, yes, no) ->
      [ (true, yes); (false, no) ]
      |> List.concat_map (fun (truth, body) ->
             condition ~ctx test ~holds:truth ~branch
             |> List.concat_map (fun branch -> translate ~ctx body ~branch))
  | Syntax.Boolop (op, values) -> boolean_value ~ctx ~at ~op values ~branch
  | Syntax.Compare _ | Syntax.Not _ ->
      [ true; false ]
      |> List.concat_map (fun truth ->
             condition ~ctx node ~holds:truth ~branch
             |> List.map (fun branch ->
                    (branch, { exp = bool ~at truth; kind = Value.boolean })))
  | Syntax.Primitive (primitive, args) ->
      let args =
        match (primitive, args) with
        | Syntax.IntFromBytes, [ value; _endianness ] -> [ value ]
        | _ -> args
      in
      eager_call ~ctx ~at
        (Library.operation_of_primitive primitive)
        ~args ~keywords:[] ~branch
  | Syntax.Call (name, args, keywords) -> (
      match callee_of_name ~ctx ~branch name with
      | Local -> Error.reject ~at ("Calls through locally bound names: " ^ name)
      | LocalHelper _ | SetOrAppendList | Unsupported
      | Builtin (Library.Zip | Library.Enumerate | Library.Filter) ->
          Error.reject ~at ("Call effects are not reviewed for " ^ name)
      | Constructor -> record_constructor ~ctx ~at name ~args ~keywords ~branch
      | Builtin (Library.Eager operation) ->
          eager_call ~ctx ~at operation ~args ~keywords ~branch
      | Builtin Library.Bytes32Constructor -> (
          match (args, keywords) with
          | [], [] ->
              (* The pinned functions use Bytes32() only as a Root, whose
                 nominal target type is required by record fields. *)
              [
                ( branch,
                  {
                    exp = Prelude.bytes32_to_bytes ~at (nat ~at 0);
                    kind = Named Names.root;
                  } );
              ]
          | ( [
                { it = Syntax.Generator (element, target, iterable, filters); _ };
              ],
              [] ) ->
              comprehension ~ctx ~at ~element ~target ~filters iterable ~branch
              |> List.map (fun (branch, value) ->
                     Byte_ops.bytes32_of_sequence ~ctx ~at ~branch value)
          | _ ->
              eager_call ~ctx ~at Library.Bytes32Value ~args ~keywords ~branch)
      | Builtin (Library.NominalBytesConstructor name) -> (
          match (args, keywords) with
          | [], [] ->
              let width =
                match
                  Value.byte_width ~types:(Ctx.types ctx) ~at (Named name)
                with
                | Some width -> width
                | None ->
                    Error.reject ~at "A default byte value needs a fixed width"
              in
              [
                ( branch,
                  {
                    exp =
                      Prelude.fixed_bytes ~at (nat ~at 0)
                        ~width:(number ~at width);
                    kind = Named name;
                  } );
              ]
          | _ ->
              eager_call ~ctx ~at (Library.NominalBytesValue name) ~args
                ~keywords ~branch)
      | Builtin Library.Range ->
          Error.reject ~at
            "Range objects are supported only as loop or comprehension \
             iterables"
      | Builtin Library.Set -> (
          match (args, keywords) with
          | [ argument ], [] ->
              let values =
                match argument.it with
                | Syntax.Generator (element, target, iterable, filters) ->
                    comprehension ~ctx ~at ~element ~target ~filters iterable
                      ~branch
                | Syntax.Call
                    ( filter,
                      [ { it = Syntax.Lambda (local, predicate); _ }; iterable ],
                      [] )
                  when builtin_of_name ~ctx ~branch filter = Some Library.Filter
                  ->
                    comprehension ~set_iteration:true ~ctx ~at
                      ~element:(Syntax.Name local $ at)
                      ~target:(Syntax.Single local) ~filters:[ predicate ]
                      iterable ~branch
                | _ -> translate ~ctx argument ~branch
              in
              values
              |> List.map (fun (branch, value) ->
                     let element =
                       match
                         Value.set_element ~types:(Ctx.types ctx) ~at value.kind
                       with
                       | Some element -> element
                       | None ->
                           let { Value.element; _ } =
                             Value.sequence ~types:(Ctx.types ctx) ~at
                               value.kind
                           in
                           element
                     in
                     if
                       Value.bits ~types:(Ctx.types ctx) ~at element = None
                       && not
                            (Value.is_integer ~types:(Ctx.types ctx) ~at element
                            || Value.is_boolean ~types:(Ctx.types ctx) ~at
                                 element)
                     then
                       Error.reject ~at
                         "Set construction requires homogeneous scalar values";
                     ( branch,
                       Sequence_ops.set_of_sequence ~ctx ~at ~element value ))
          | _ -> Error.reject ~at "set requires one typed materialized sequence"
          )
      | Builtin Library.Sorted -> sorted ~ctx ~at args ~keywords ~branch
      | Builtin Library.Sum -> sum ~ctx ~at args ~keywords ~branch
      | Builtin (Library.Extremum operation) -> (
          match (args, keywords) with
          | [ _; _ ], [] ->
              arguments ~ctx args ~branch
              |> List.concat_map (fun (branch, values) ->
                     Numeric_ops.extremum ~ctx ~at ~operation ~branch values)
          | [ value ], [] -> extremum ~ctx ~at ~operation value ~branch
          | _ ->
              Error.reject ~at
                "Min and max require two values or one materialized sequence")
      | Cast -> (
          if keywords <> [] then
            Error.reject ~at "Keyword calls require a reviewed constructor";
          match args with
          | [
           {
             it =
               Syntax.Binary (Syntax.Pow, { it = Syntax.Int base; _ }, exponent);
             _;
           };
          ]
            when Bigint.equal base (Bigint.of_int 2)
                 && Value.bits ~types:(Ctx.types ctx) ~at (Named name) = Some 8
            ->
              translate ~ctx exponent ~branch
              |> List.map (fun (branch, value) ->
                     Numeric_ops.cast_power_of_two ~ctx ~at ~name ~branch value)
          | _ ->
              eager_call ~ctx ~at (Library.NumericCast name) ~args ~keywords:[]
                ~branch)
      | Function signature ->
          if signature.effect = Typed.MutatesState then
            Error.reject ~at ("Call effects are not reviewed for " ^ name);
          let written, order =
            Call.bind_arguments ~at ~signature args ~keywords
          in
          let returns = Named (Option.get signature.returns) in
          if
            (match
               Typed.descriptor_of_name ~types:(Ctx.types ctx) ~at
                 (Option.get signature.returns)
             with
            | Typed.Product _ -> true
            | _ -> false)
            && ((not
                   (Value.is_readonly_product ~types:(Ctx.types ctx) ~at returns))
               || not signature.fresh_result)
          then
            Error.reject ~at
              "Tuple-valued calls require a reviewed fresh-result contract";
          arguments ~ctx written ~branch
          |> List.map (fun (branch, written) ->
                 let supplied = Call.parameter_values written ~order in
                 Call.invoke ~ctx ~at signature
                   ~list_result:(List.mem name (Ctx.list_results ctx))
                   ~supplied ~branch))
  | Syntax.Comprehension (element, target, iterable, filters) ->
      comprehension ~ctx ~at ~element ~target ~filters iterable ~branch
  | Syntax.Generator _ ->
      Error.reject ~at "Generator expressions require immediate set consumption"

and intersection ~ctx ~at receiver ~other ~branch =
  arguments ~ctx [ receiver; other ] ~branch
  |> List.map (fun (branch, values) ->
         match values with
         | [ left; right ] ->
             Sequence_ops.intersection ~ctx ~at ~branch left ~right
         | _ -> assert false)

and search ~ctx ~at ~search receiver ~needle ~branch =
  arguments ~ctx [ receiver; needle ] ~branch
  |> List.map (fun (branch, values) ->
         match values with
         | [ input; needle ] ->
             Sequence_ops.search ~ctx ~at ~search ~branch input ~needle
         | _ -> assert false)

and iterable ~ctx (iterable : Syntax.expr) ~branch =
  match iterable.it with
  | Syntax.Tuple nodes when nodes <> [] ->
      arguments ~ctx nodes ~branch
      |> List.map (fun (branch, values) ->
             let element = (List.hd values).kind in
             if not (List.for_all (fun value -> value.kind = element) values)
             then
               Error.reject ~at:iterable.at
                 "Tuple iteration requires homogeneous elements";
             ( branch,
               {
                 exp =
                   ListE (List.map (fun value -> value.exp) values)
                   $ iterable.at;
                 kind =
                   Sequence (element, Some (Bigint.of_int (List.length values)));
               } ))
  | Syntax.Call (name, [ left; right ], [])
    when builtin_of_name ~ctx ~branch name = Some Library.Zip ->
      arguments ~ctx [ left; right ] ~branch
      |> List.map (fun (branch, values) ->
             let backed =
               List.exists2
                 (fun node value ->
                   (not
                      (Value.is_byte_valued ~types:(Ctx.types ctx)
                         ~at:iterable.at value.kind))
                   && state_backed ~branch node value)
                 [ left; right ] values
             in
             let branch, values =
               List.fold_left_map
                 (fun branch value ->
                   let branch, value =
                     if
                       Value.is_byte_valued ~types:(Ctx.types ctx)
                         ~at:iterable.at value.kind
                     then
                       Byte_ops.sequence_of_bytes ~ctx ~at:iterable.at ~branch
                         value
                     else (branch, value)
                   in
                   ignore
                     (Value.sequence ~types:(Ctx.types ctx) ~at:iterable.at
                        value.kind);
                   (branch, value))
                 branch values
             in
             let value = Sequence_ops.zip ~ctx ~at:iterable.at values in
             let branch =
               if backed then
                 Branch.map_storage
                   ~f:
                     (Store.remember_origin
                        ~key:(Lang.El.Unparse.string_of_exp value.exp)
                        ~location:[])
                   branch
               else branch
             in
             (branch, value))
  | Syntax.Call (name, _, _)
    when builtin_of_name ~ctx ~branch name = Some Library.Zip ->
      Error.reject ~at:iterable.at
        "Zip iteration requires two positional sequences"
  | Syntax.Call (name, args, keywords)
    when builtin_of_name ~ctx ~branch name = Some Library.Range ->
      range ~ctx ~at:iterable.at args ~keywords ~branch
  | _ ->
      translate ~ctx iterable ~branch
      |> List.map (fun (branch, value) ->
             if
               Value.is_byte_valued ~types:(Ctx.types ctx) ~at:iterable.at
                 value.kind
             then Byte_ops.sequence_of_bytes ~ctx ~at:iterable.at ~branch value
             else (branch, value))

and range ~ctx ~at args ~keywords ~branch =
  if keywords <> [] || (List.length args <> 1 && List.length args <> 2) then
    Error.reject ~at "Range requires one or two positional bounds";
  arguments ~ctx args ~branch
  |> List.map (fun (branch, values) ->
         Sequence_ops.range ~ctx ~at ~branch values)

and sorted ~ctx ~at args ~keywords ~branch =
  let input, local, key, numeric_order =
    match (args, keywords) with
    | [ input ], [] ->
        let local = "__sorted_element" in
        (input, local, Syntax.Name local $ at, true)
    | [ input ], [ ("key", { it = Syntax.Lambda (local, key); _ }) ] ->
        (input, local, key, false)
    | _ ->
        Error.reject ~at
          "Sorting requires one integer sequence and an optional key lambda"
  in
  translate ~ctx input ~branch
  |> List.map (fun (branch, input) ->
         let input =
           match Value.set_element ~types:(Ctx.types ctx) ~at input.kind with
           | Some element when numeric_order ->
               { input with kind = Sequence (element, None) }
           | Some _ ->
               Error.reject ~at
                 "Sorting a set with a key may expose its iteration order"
           | None -> input
         in
         let { Value.element; _ } =
           Value.sequence ~types:(Ctx.types ctx) ~at input.kind
         in
         if
           not
             (Value.is_integer ~types:(Ctx.types ctx) ~at element
             || Value.bits ~types:(Ctx.types ctx) ~at element = Some 64)
         then Error.reject ~at "Sorting requires an ordered integer sequence";
         Branch.check_promoted_capture ~at branch;
         let decorate initial _index item =
           let key_nodes =
             match key.it with
             | Syntax.Tuple nodes when nodes <> [] -> nodes
             | _ -> [ key ]
           in
           let alternatives =
             arguments ~ctx key_nodes
               ~branch:(replace_local ~name:local ~value:item initial)
           in
           let keys =
             match alternatives with
             | (_, keys) :: _ -> keys
             | [] -> Error.reject ~at "Sort key has no result"
           in
           let kinds = List.map (fun value -> value.kind) keys in
           if
             (not
                (List.for_all
                   (fun kind ->
                     Value.is_integer ~types:(Ctx.types ctx) ~at kind
                     || Value.bits ~types:(Ctx.types ctx) ~at kind = Some 64)
                   kinds))
             || not
                  (List.for_all
                     (fun (_, values) ->
                       List.map (fun value -> value.kind) values = kinds)
                     alternatives)
           then Error.reject ~at "Sort keys require uniform integer components";
           ( List.map
               (fun (branch, keys) ->
                 ( branch,
                   {
                     exp =
                       TupleE
                         (List.map (fun value -> value.exp) (keys @ [ item ]))
                       $ at;
                     kind = Product (kinds @ [ element ]);
                   } ))
               alternatives,
             [] )
         in
         let branch, decorated =
           Loop.map ~ctx ~at
             ~captures:(captures ~at ~branch ~bound:[ local ] [ key ])
             ~element:decorate ~branch input
         in
         Sequence_ops.sort ~ctx ~at ~element ~branch decorated)

and arguments ~ctx nodes ~branch =
  collect_values (fun branch node -> translate ~ctx node ~branch) branch nodes

and eager_call ~ctx ~at operation ~args ~keywords ~branch =
  let contract = Library.contract_of_operation operation in
  if keywords <> [] || List.length args <> contract.arity then
    Error.reject ~at contract.diagnostic;
  arguments ~ctx args ~branch
  |> List.map (fun (branch, values) ->
         let unary apply =
           match values with
           | [ value ] -> apply ~branch value
           | _ -> assert false
         in
         match operation with
         | Library.Hash -> unary (Byte_ops.hash ~ctx ~at)
         | Library.Serialize -> unary (Ssz_ops.serialize ~ctx ~at)
         | Library.HashTreeRoot -> unary (Ssz_ops.hash_tree_root ~ctx ~at)
         | Library.All -> unary (Sequence_ops.all ~ctx ~at)
         | Library.Length -> unary (Sequence_ops.length ~ctx ~at)
         | Library.Bytes32Value -> unary (Byte_ops.bytes32_of_value ~ctx ~at)
         | Library.NominalBytesValue name ->
             unary (Byte_ops.nominal_bytes_of_value ~ctx ~at ~name)
         | Library.NumericCast name -> unary (Numeric_ops.cast ~ctx ~at ~name)
         | Library.Primitive primitive ->
             Prelude.invoke_primitive ~ctx ~at primitive ~branch ~values
         | Library.LittleEndian -> unary (Byte_ops.integer_of_bytes ~ctx ~at)
         | Library.AggregatePubkeys -> unary (Call.aggregate_pubkeys ~ctx ~at))

and expression_pair ~ctx left right ~branch ~finish =
  translate ~ctx left ~branch
  |> List.concat_map (fun (branch, left) ->
         translate ~ctx right ~branch
         |> List.map (fun (branch, right) -> finish branch left right))

and boolean_value ~ctx ~at ~op values ~branch =
  let rec select branch = function
    | [] -> Error.reject ~at "Boolean operations require an operand"
    | [ value ] -> translate ~ctx value ~branch
    | value :: rest ->
        translate ~ctx value ~branch
        |> List.concat_map (fun (branch, value) ->
               let stop = op = Syntax.Or in
               let stopped =
                 truth_condition ~ctx ~at ~holds:stop ~branch value
               in
               let continuing =
                 truth_condition ~ctx ~at ~holds:(not stop) ~branch value
               in
               (stopped, value) :: select continuing rest)
  in
  select branch values

and condition ~ctx (node : Syntax.expr) ~holds ~branch =
  let at = node.at in
  match node.it with
  | Syntax.Not value -> condition ~ctx value ~holds:(not holds) ~branch
  | Syntax.Compare
      ( left,
        [ (((Syntax.Is | Syntax.IsNot) as op), { it = Syntax.NoneValue; _ }) ]
      ) -> (
      let name =
        match left.it with
        | Syntax.Name name -> name
        | _ ->
            Error.reject ~at "A None test requires an optional parameter name"
      in
      let absent = holds = (op = Syntax.Is) in
      match List.assoc_opt name (Store.bindings branch.storage) with
      | None -> Error.reject ~at ("Unresolved name: " ^ name)
      | Some ({ kind = Optional element; _ } as value) -> (
          match List.assoc_opt name branch.options with
          | Some recorded ->
              (* Presence is already decided on this path, so a repeated test
                 agrees with the recorded head pattern. *)
              if recorded.it = EpsE = absent then [ branch ] else []
          | None ->
              let argument =
                match value.exp.it with
                | IterE ({ it = VarE argument; _ }, Opt) -> argument.it
                | _ ->
                    Error.reject ~at
                      "A None test requires an optional parameter"
              in
              let pattern, value =
                if absent then (EpsE $ at, { value with exp = EpsE $ at })
                else
                  (var ~at argument, { exp = var ~at argument; kind = element })
              in
              [
                branch |> replace_local ~name ~value
                |> decide_option ~name ~pattern;
              ])
      | Some _ ->
          (* A binding whose type excludes None is never None, so only the
             negative branch survives. *)
          if absent then [] else [ branch ])
  | Syntax.Compare (_, comparisons)
    when List.exists
           (fun (op, _) -> List.mem op Syntax.[ Is; IsNot ])
           comparisons ->
      Error.reject ~at "Identity tests are only supported against None"
  | Syntax.Boolop (op, values) ->
      let conjunction = op = Syntax.And in
      short_circuit ~require_all:(holds = conjunction)
        (fun value live truth ->
          List.concat_map
            (fun branch ->
              condition ~ctx value ~holds:(truth = conjunction) ~branch)
            live)
        [ branch ] values
  | Syntax.Compare (left, [ (op, { it = Syntax.Tuple elements; _ }) ])
    when List.mem op Syntax.[ In; NotIn ] ->
      translate ~ctx left ~branch
      |> List.concat_map (fun (branch, left) ->
             (match left.kind with
             | Named _
               when not
                      (Value.is_named_container_or_set ~types:(Ctx.types ctx)
                         ~at left.kind) ->
                 ()
             | _ ->
                 Error.reject ~at
                   "Tuple membership requires immutable scalar values");
             let branch, left = bind ~ctx ~at branch ~term:left in
             let values =
               collect_values
                 (fun branch node ->
                   translate ~ctx node ~branch
                   |> List.map (fun (branch, value) ->
                          if
                            value.kind <> left.kind
                            || Value.is_named_container_or_set
                                 ~types:(Ctx.types ctx) ~at value.kind
                          then
                            Error.reject ~at
                              "Tuple membership requires matching scalar types";
                          let branch, value =
                            bind ~ctx ~at branch ~term:value
                          in
                          (branch, value)))
                 branch elements
             in
             values
             |> List.map (fun (branch, values) ->
                    let member =
                      List.fold_left
                        (fun result value ->
                          BinE
                            ( result,
                              `OrOp,
                              comparison ~at ~op:`EqOp left.exp value.exp )
                          $ at)
                        (bool ~at false) values
                    in
                    guard_boolean_condition ~at
                      ~holds:(holds = (op = Syntax.In))
                      ~exp:member branch))
  | Syntax.Compare (left, [ (op, right) ]) when List.mem op Syntax.[ In; NotIn ]
    ->
      translate ~ctx left ~branch
      |> List.concat_map (fun (branch, left) ->
             let branch, left = bind ~ctx ~at branch ~term:left in
             translate ~ctx right ~branch
             |> List.map (fun (branch, right) ->
                    let element =
                      match
                        Value.set_element ~types:(Ctx.types ctx) ~at right.kind
                      with
                      | Some element -> element
                      | None ->
                          let { Value.element; _ } =
                            Value.sequence ~types:(Ctx.types ctx) ~at right.kind
                          in
                          element
                    in
                    if element <> left.kind then
                      Error.reject ~at
                        "Membership requires a matching element type";
                    let branch, right = bind ~ctx ~at branch ~term:right in
                    let member = MemE (left.exp, right.exp) $ at in
                    guard_boolean_condition ~at
                      ~holds:(holds = (op = Syntax.In))
                      ~exp:member branch))
  | Syntax.Compare (_, comparisons)
    when List.exists
           (fun (op, _) -> List.mem op Syntax.[ In; NotIn ])
           comparisons ->
      Error.reject ~at "Membership requires one comparison with a scalar tuple"
  | Syntax.Compare (left, comparisons) ->
      short_circuit ~require_all:holds
        (fun (op, right) live ->
          let combinations =
            live
            |> List.concat_map (fun (branch, left) ->
                   translate ~ctx right ~branch
                   |> List.map (fun (branch, right) ->
                          let branch, test, right =
                            comparison_operator ~ctx ~at ~op ~branch left right
                          in
                          (branch, test, right)))
          in
          fun truth ->
            List.map
              (fun (branch, test, right) ->
                (guard ~at ~exp:(test truth) branch, right))
              combinations)
        (translate ~ctx left ~branch)
        comparisons
      |> List.map fst
  | _ ->
      translate ~ctx node ~branch
      |> List.map (fun (branch, value) ->
             truth_condition ~ctx ~at ~holds ~branch value)

and slice_bounds ~ctx ~at ~branch length ~lower ~upper ~step =
  if step <> None then
    Error.reject ~at "Stepped bitvector slices are unsupported";
  (* remerkleable raises IndexError for bitvector slice bounds past the length.
     Python byte slices clamp those bounds. *)
  let bound branch fallback = function
    | None -> (branch, fallback)
    | Some node -> (
        let n = static_integer ~ctx node in
        if Bigint.compare n Bigint.zero < 0 then
          Error.reject ~at "Negative bitvector slice bounds are unsupported";
        if Bigint.compare n length > 0 then
          Error.reject ~at
            "A bitvector slice bound past the bitvector length raises in Python";
        match translate ~ctx node ~branch with
        | [ (branch, _) ] -> (branch, n)
        | _ -> Error.reject ~at "Branching slice bound")
  in
  let branch, start = bound branch Bigint.zero lower in
  let branch, finish = bound branch length upper in
  (branch, start, finish)

and record_constructor ~ctx ~at name ~args ~keywords ~branch =
  let record =
    Ssz_ops.prepare_record ~ctx ~at name ~positional:(args <> [])
      ~keywords:(List.map fst keywords)
  in
  collect_values
    (fun branch (name, node) ->
      translate ~ctx node ~branch
      |> List.map (fun (branch, value) ->
             let branch, value =
               Ssz_ops.coerce_field ~ctx ~at ~plan:record ~name ~branch value
             in
             let branch, value = bind ~ctx ~at:node.at branch ~term:value in
             (branch, (name, value))))
    branch keywords
  |> List.map (fun (branch, values) ->
         Ssz_ops.record ~ctx ~at ~plan:record values ~branch)

and repeat ~ctx ~at ~item input ~branch =
  arguments ~ctx [ item; input ] ~branch
  |> List.map (fun (branch, values) ->
         match values with
         | [ item; input ] -> Sequence_ops.repeat ~ctx ~at ~branch ~item input
         | _ -> assert false)

and extremum ~ctx ~at ~operation node ~branch =
  translate ~ctx node ~branch
  |> List.map (fun (branch, value) ->
         Sequence_ops.extremum ~ctx ~at ~operation ~branch value)

and sum ~ctx ~at args ~keywords ~branch =
  let values =
    match (args, keywords) with
    | ( [ { it = Syntax.Comprehension (element, target, iterable, filters); _ } ],
        [] ) ->
        comprehension ~set_iteration:true ~ctx ~at ~element ~target ~filters
          iterable ~branch
    | [ argument ], [] -> translate ~ctx argument ~branch
    | _ ->
        Error.reject ~at
          "sum requires one materialized uint64 or boolean sequence"
  in
  values
  |> List.concat_map (fun (branch, value) ->
         Sequence_ops.sum ~ctx ~at ~branch value)

and comprehension ?(set_iteration = false) ~ctx ~at ~element ~target ~filters
    (iterated : Syntax.expr) ~branch =
  let targets = Syntax.target_names target in
  let enumerated, iterated =
    enumeration ~ctx ~at ~branch
      ~target_error:"Comprehension target must be a name" iterated target
  in
  iterable ~ctx iterated ~branch
  |> List.map (fun (branch, value) ->
         let value =
           match Value.set_element ~types:(Ctx.types ctx) ~at value.kind with
           | Some element when set_iteration && not enumerated ->
               { value with kind = Sequence (element, None) }
           | Some _ ->
               Error.reject ~at
                 "Set iteration requires an immediate order-independent sum"
           | None -> value
         in
         Branch.check_promoted_capture ~at branch;
         let element_body initial index item =
           let initial =
             bind_loop_targets ~ctx ~at
               ~arity_error:"Comprehension tuple target arity" ~iterated
               ~enumerated ~target ~index ~branch:initial item
           in
           let live, skipped =
             List.fold_left
               (fun (live, skipped) predicate ->
                 ( List.concat_map
                     (fun branch ->
                       condition ~ctx predicate ~holds:true ~branch)
                     live,
                   skipped
                   @ List.concat_map
                       (fun branch ->
                         condition ~ctx predicate ~holds:false ~branch)
                       live ))
               ([ initial ], []) filters
           in
           let values =
             List.concat_map (fun branch -> translate ~ctx element ~branch) live
             |> List.map (fun (branch, value) ->
                    bind ~ctx ~at:element.at branch ~term:value)
           in
           (values, skipped)
         in
         Loop.map ~ctx ~at
           ~captures:(captures ~at ~branch ~bound:targets (element :: filters))
           ~element:element_body ~branch value)
