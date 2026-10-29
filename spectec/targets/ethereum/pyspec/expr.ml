open Common.Source
open Lang.El
open Store
open Kind
open Operand
open Ctx
open Branch
module S = Source
module B = Python_builtins

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

(* Each step prepares a branch selector. False selects stopped branches and
   runs before true selects continuing branches. *)
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

let constant ctx at name =
  let kind, value = Error.find_or_reject ~at ~name ctx.source.constants in
  let kind =
    match value with
    | S.IntegerConstant _ -> Named kind
    | S.SequenceConstant values -> (
        match Kind.descriptor ~types:ctx.source.types ~at kind with
        | S.Sequence { element; _ } ->
            FrozenSequence (Named element, Bigint.of_int (List.length values))
        | _ -> Error.reject ~at "Sequence constant type")
  in
  ({ exp = call ~at name ~args:[]; kind }, value)

let rec static_integer ctx (node : Syntax.expr) =
  match node.it with
  | Syntax.Int value -> value
  | Syntax.Negate value -> Bigint.(zero - static_integer ctx value)
  | Syntax.Name name when not (List.mem name ctx.source.locals) -> (
      match snd (constant ctx node.at name) with
      | S.IntegerConstant value -> value
      | _ -> Error.reject ~at:node.at "Expected an integer constant")
  | Syntax.Binary (((Syntax.Add | Syntax.Sub) as op), left, right) ->
      let l = static_integer ctx left and r = static_integer ctx right in
      (if op = Syntax.Add then Bigint.( + ) else Bigint.( - )) l r
  | _ ->
      Error.reject ~at:node.at
        "Slice bounds must be integer literals or constants"

let is_nonnegative_range ~ctx (node : Syntax.expr) =
  match node.it with
  | Syntax.Call ("range", args, [])
    when List.mem "range" ctx.source.builtins
         && not (List.mem "range" ctx.source.locals) -> (
      match args with
      | [ _ ] -> true
      | [ start; _ ] -> (
          try Bigint.compare (static_integer ctx start) Bigint.zero >= 0
          with Error.Rejected _ -> false)
      | _ -> false)
  | _ -> false

(* Python slices a byte string by clamping an in-range bound to its length,
   so a nominal source width determines the result width statically. A
   resolved bound below zero is relative to the sequence length in Python,
   which this subset does not implement. Translation rejects such a bound,
   because clamping it to zero would read [0 - 1 :] as [0:] instead of the
   last byte. *)
let byte_slice ctx at branch base lower upper step =
  if step <> None then Error.reject ~at "Stepped byte slices are unsupported";
  let width =
    match Kind.byte_width ~types:ctx.source.types ~at base.kind with
    | Some width -> width
    | None -> Error.reject ~at "Byte slices require a fixed source width"
  in
  let bound value =
    if Bigint.compare value Bigint.zero < 0 then
      Error.reject ~at
        "Byte slices require a nonnegative resolved bound; a negative bound is \
         relative to length and unsupported"
    else Bigint.min value width
  in
  let start =
    bound
      (match lower with None -> Bigint.zero | Some n -> static_integer ctx n)
  in
  let finish =
    bound (match upper with None -> width | Some n -> static_integer ctx n)
  in
  let count = Bigint.max Bigint.zero Bigint.(finish - start) in
  let branch, bytes_ = Byte_ops.to_bytes ~ctx ~at ~branch base in

  bind ~ctx ~at branch
    ~term:
      {
        exp =
          Target_builtins.bytes_slice ~ctx ~at bytes_.exp
            ~start:(number ~at start) ~count:(number ~at count);
        kind = ByteString count;
      }

let complement = function
  | `EqOp -> `NeOp
  | `NeOp -> `EqOp
  | `LtOp -> `GeOp
  | `LeOp -> `GtOp
  | `GtOp -> `LeOp
  | `GeOp -> `LtOp

let target_cmpop = function
  | Syntax.Eq -> `EqOp
  | Syntax.NotEq -> `NeOp
  | Syntax.Lt -> `LtOp
  | Syntax.LtE -> `LeOp
  | Syntax.Gt -> `GtOp
  | Syntax.GtE -> `GeOp
  | _ -> assert false

let bind_tuple_targets ~ctx ~at ~arity_error ~branch ~targets item =
  let elements = Kind.product ~types:ctx.source.types ~at item.kind in
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

let call_arguments ~at ~(signature : S.signature) args ~keywords =
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

let read_name ~ctx ~at ~branch name =
  match List.assoc_opt name (Store.bindings branch.storage) with
  | Some { kind = Optional _; _ } ->
      (* Only an identity test against None consumes an optional value, so
         every other reader needs the presence decided first. *)
      Error.reject ~at
        ("An optional value needs a None test before use: " ^ name)
  | Some value -> value
  | None when List.mem name ctx.source.locals ->
      Error.reject ~at ("Read before local assignment: " ^ name)
  | None
    when name = Spec_names.execution_engine_global
         && List.mem name ctx.source.builtins ->
      { exp = TupleE [] $ at; kind = Named Spec_names.execution_engine }
  | None -> fst (constant ctx at name)

let rec translate ~ctx (node : Syntax.expr) ~branch =
  let at = node.at in
  match node.it with
  | Syntax.Name name -> [ (branch, read_name ~ctx ~at ~branch name) ]
  | Syntax.Int value ->
      if Bigint.compare value Bigint.zero < 0 then
        Error.reject ~at "Negative literals require unary-minus support";
      [ (branch, { exp = number ~at value; kind = Kind.integer }) ]
  | Syntax.Negate value ->
      translate ~ctx value ~branch
      |> List.map (fun (branch, value) ->
             Numeric_ops.negate ~ctx ~at ~branch value)
  | Syntax.BytesLiteral value -> [ (branch, Byte_ops.literal ~ctx ~at value) ]
  | Syntax.Bool value ->
      [ (branch, { exp = bool ~at value; kind = Kind.boolean }) ]
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
                    (Kind.fields ~types:ctx.source.types ~at base.kind))
             in
             remember_origin branch ~base ~step:(Field field)
               ~value:{ exp = DotE (base.exp, atom ~at field) $ at; kind })
  | Syntax.Index (base, { it = Syntax.Slice (lower, upper, step); _ }) ->
      translate ~ctx base ~branch
      |> List.concat_map (fun (branch, base) ->
             if Kind.is_byte_valued ~types:ctx.source.types ~at base.kind then
               [ byte_slice ctx at branch base lower upper step ]
             else
               let element, length, bitvector =
                 Kind.sequence ~types:ctx.source.types ~at base.kind
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
      expression_pair ctx base index branch (fun branch base index ->
          if Kind.is_byte_valued ~types:ctx.source.types ~at base.kind then
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
    when method_ = Spec_names.new_payload_method ->
      if not (List.mem Spec_names.new_payload_request ctx.source.builtins) then
        Error.reject ~at "Unreviewed execution-payload request";
      if List.mem Spec_names.new_payload_request ctx.source.locals then
        Error.reject ~at "Calls through locally bound names: NewPayloadRequest";
      let payload =
        match request.it with
        | Syntax.Call (name, [], [ (keyword, payload) ])
          when name = Spec_names.new_payload_request
               && keyword = Spec_names.execution_payload_keyword ->
            payload
        | _ ->
            Error.reject ~at
              "The external engine requires an immediate execution-payload \
               request"
      in
      translate ~ctx receiver ~branch
      |> List.concat_map (fun (branch, receiver) ->
             if receiver.kind <> Named Spec_names.execution_engine then
               Error.reject ~at "Expected an external execution engine";
             translate ~ctx payload ~branch
             |> List.map (fun (branch, payload) ->
                    Call_ops.notify_new_payload ~ctx ~at ~branch payload))
  | Syntax.Method (receiver, "intersection", [ other ]) ->
      intersection ctx at receiver other branch
  | Syntax.Method (receiver, (("count" | "index") as method_), [ needle ]) ->
      search ctx at method_ receiver needle branch
  | Syntax.Method _ ->
      Error.reject ~at "Method calls require a reviewed sequence operation"
  | Syntax.Slice _ -> Error.reject ~at "Slice outside subscript"
  | Syntax.Binary
      ( Syntax.Mult,
        { it = Syntax.ListLiteral [ item ]; _ },
        { it = Syntax.Call ("len", [ sequence ], []); _ } )
    when List.mem "len" ctx.source.builtins
         && not (List.mem "len" ctx.source.locals) ->
      repeat ctx at item sequence branch
  | Syntax.Binary (Syntax.Mult, { it = Syntax.BytesLiteral value; _ }, count)
  | Syntax.Binary (Syntax.Mult, count, { it = Syntax.BytesLiteral value; _ }) ->
      translate ~ctx count ~branch
      |> List.map (fun (branch, value_count) ->
             if
               not
                 (Kind.is_integer ~types:ctx.source.types ~at value_count.kind
                 || Kind.bits ~types:ctx.source.types ~at value_count.kind
                    <> None)
             then
               Error.reject ~at
                 "Byte literal repetition requires an integer count";
             let count = static_integer ctx count in
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
             if value = "" then (branch, Byte_ops.literal ~ctx ~at "")
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
               (branch, Byte_ops.literal ~ctx ~at repeated)))
  | Syntax.Binary (Syntax.Pow, base, exponent) ->
      expression_pair ctx base exponent branch (fun branch base exponent ->
          Numeric_ops.power ~ctx ~at ~branch base ~exponent)
  | Syntax.Binary (op, left, right) ->
      expression_pair ctx left right branch (fun branch ->
          Operators.binary ~ctx ~at ~op ~branch)
  | Syntax.Conditional (test, yes, no) ->
      [ (true, yes); (false, no) ]
      |> List.concat_map (fun (truth, body) ->
             condition ~ctx test ~holds:truth ~branch
             |> List.concat_map (fun branch -> translate ~ctx body ~branch))
  | Syntax.Compare _ | Syntax.Boolop _ | Syntax.Not _ ->
      [ true; false ]
      |> List.concat_map (fun truth ->
             condition ~ctx node ~holds:truth ~branch
             |> List.map (fun branch ->
                    (branch, { exp = bool ~at truth; kind = Kind.boolean })))
  | Syntax.Primitive (primitive, args) ->
      if not (List.mem (Syntax.primitive_name primitive) ctx.source.builtins)
      then Error.reject ~at "Unreviewed primitive";
      eager_call ctx at (B.of_primitive primitive) args [] branch
  | Syntax.Call (name, args, keywords) -> (
      if List.mem name ctx.source.locals then
        Error.reject ~at ("Calls through locally bound names: " ^ name);
      if List.mem name ctx.source.constructors then
        record_constructor ctx at name args keywords branch
      else
        match B.resolve ~builtins:ctx.source.builtins name with
        | Some (B.Eager operation) ->
            eager_call ctx at operation args keywords branch
        | Some B.Bytes32Constructor -> (
            match (args, keywords) with
            | [], [] ->
                [
                  ( branch,
                    {
                      exp =
                        Target_builtins.bytes32_to_bytes ~ctx ~at (nat ~at 0);
                      kind = Named Spec_names.root;
                    } );
                ]
            | ( [
                  {
                    it = Syntax.Generator (element, target, iterable, filters);
                    _;
                  };
                ],
                [] ) ->
                comprehension ctx at element target iterable filters branch
                |> List.map (fun (branch, value) ->
                       Byte_ops.bytes32_of_sequence ~ctx ~at ~branch value)
            | _ -> eager_call ctx at B.Bytes32Value args keywords branch)
        | Some (B.NominalBytesConstructor name) -> (
            match (args, keywords) with
            | [], [] ->
                let width =
                  match
                    Kind.byte_width ~types:(Ctx.types ctx) ~at (Named name)
                  with
                  | Some width -> width
                  | None ->
                      Error.reject ~at
                        "A default byte value needs a fixed width"
                in
                [
                  ( branch,
                    {
                      exp =
                        Target_builtins.fixed_bytes ~ctx ~at (nat ~at 0)
                          ~width:(number ~at width);
                      kind = Named name;
                    } );
                ]
            | _ ->
                eager_call ctx at (B.NominalBytesValue name) args keywords
                  branch)
        | Some B.Range ->
            Error.reject ~at
              "Range objects are supported only as loop or comprehension \
               iterables"
        | Some B.Set -> (
            match (args, keywords) with
            | [ argument ], [] ->
                let values =
                  match argument.it with
                  | Syntax.Generator (element, target, iterable, filters) ->
                      comprehension ctx at element target iterable filters
                        branch
                  | Syntax.Call
                      ( "filter",
                        [
                          { it = Syntax.Lambda (local, predicate); _ }; iterable;
                        ],
                        [] )
                    when List.mem "filter" ctx.source.builtins
                         && not (List.mem "filter" ctx.source.locals) ->
                      comprehension ~set_iteration:true ctx at
                        (Syntax.Name local $ at) (Syntax.Single local) iterable
                        [ predicate ] branch
                  | _ -> translate ~ctx argument ~branch
                in
                values
                |> List.map (fun (branch, value) ->
                       let element =
                         match
                           Kind.set_element ~types:ctx.source.types ~at
                             value.kind
                         with
                         | Some element -> element
                         | None ->
                             let element, _, _ =
                               Kind.sequence ~types:ctx.source.types ~at
                                 value.kind
                             in
                             element
                       in
                       if
                         Kind.bits ~types:ctx.source.types ~at element = None
                         && not
                              (Kind.is_integer ~types:ctx.source.types ~at
                                 element
                              || Kind.is_boolean ~types:ctx.source.types ~at
                                   element)
                       then
                         Error.reject ~at
                           "Set construction requires homogeneous scalar values";
                       (branch, Sequence_ops.make_set ~ctx ~at ~element value))
            | _ ->
                Error.reject ~at "set requires one typed materialized sequence")
        | Some B.Sorted -> sorted ctx at args keywords branch
        | Some B.Sum -> sum ctx at args keywords branch
        | Some (B.Extremum name) -> (
            match (args, keywords) with
            | [ _; _ ], [] ->
                arguments ~ctx args ~branch
                |> List.concat_map (fun (branch, values) ->
                       Numeric_ops.extremum ~ctx ~at ~name ~branch values)
            | [ value ], [] -> extremum ctx at name value branch
            | _ ->
                Error.reject ~at
                  "Min and max require two values or one materialized sequence")
        | None -> (
            if keywords <> [] && List.mem_assoc name ctx.source.casts then
              Error.reject ~at "Keyword calls require a reviewed constructor";
            match List.assoc_opt name ctx.source.casts with
            | Some name -> (
                match args with
                | [
                 {
                   it =
                     Syntax.Binary
                       (Syntax.Pow, { it = Syntax.Int base; _ }, exponent);
                   _;
                 };
                ]
                  when Bigint.equal base (Bigint.of_int 2)
                       && Kind.bits ~types:ctx.source.types ~at (Named name)
                          = Some 8 ->
                    translate ~ctx exponent ~branch
                    |> List.map (fun (branch, value) ->
                           Numeric_ops.cast_power_of_two ~ctx ~at ~name ~branch
                             value)
                | _ -> eager_call ctx at (B.NumericCast name) args [] branch)
            | None ->
                let signature = call_signature ~ctx ~at name in
                if signature.effect = S.MutatesState then
                  Error.reject ~at ("Call effects are not reviewed for " ^ name);
                let written, order =
                  call_arguments ~at ~signature args ~keywords
                in
                let returns = Named (Option.get signature.returns) in
                if
                  (match
                     Kind.descriptor ~types:ctx.source.types ~at
                       (Option.get signature.returns)
                   with
                  | S.Product _ -> true
                  | _ -> false)
                  && ((not
                         (Kind.is_readonly_product ~types:ctx.source.types ~at
                            returns))
                     || not signature.fresh_result)
                then
                  Error.reject ~at
                    "Tuple-valued calls require a reviewed fresh-result \
                     contract";
                arguments ~ctx written ~branch
                |> List.map (fun (branch, written) ->
                       let supplied =
                         Call_ops.parameter_values written ~order
                       in
                       Call_ops.invoke ~ctx ~at signature
                         ~list_result:(List.mem name ctx.list_results)
                         ~supplied ~branch)))
  | Syntax.Comprehension (element, target, iterable, filters) ->
      comprehension ctx at element target iterable filters branch
  | Syntax.Generator _ ->
      Error.reject ~at "Generator expressions require immediate set consumption"

and intersection ctx at receiver other branch =
  arguments ~ctx [ receiver; other ] ~branch
  |> List.map (fun (branch, values) ->
         match values with
         | [ left; right ] ->
             Sequence_ops.intersection ~ctx ~at ~branch left ~right
         | _ -> assert false)

and search ctx at method_ receiver needle branch =
  arguments ~ctx [ receiver; needle ] ~branch
  |> List.map (fun (branch, values) ->
         match values with
         | [ input; needle ] ->
             Sequence_ops.search ~ctx ~at ~method_name:method_ ~branch input
               ~needle
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
  | Syntax.Call ("zip", [ left; right ], [])
    when List.mem "zip" ctx.source.builtins
         && not (List.mem "zip" ctx.source.locals) ->
      arguments ~ctx [ left; right ] ~branch
      |> List.map (fun (branch, values) ->
             let backed =
               List.exists2
                 (fun node value ->
                   (not
                      (Kind.is_byte_valued ~types:ctx.source.types
                         ~at:iterable.at value.kind))
                   && (origin branch ~value <> None
                      ||
                      match node.it with
                      | Syntax.Name name -> (
                          match
                            List.assoc_opt name
                              (Store.references branch.storage)
                          with
                          | Some { location = Some _; _ } -> true
                          | _ -> false)
                      | _ -> false))
                 [ left; right ] values
             in
             let branch, values =
               List.fold_left_map
                 (fun branch value ->
                   let branch, value =
                     if
                       Kind.is_byte_valued ~types:ctx.source.types
                         ~at:iterable.at value.kind
                     then Byte_ops.elements ~ctx ~at:iterable.at ~branch value
                     else (branch, value)
                   in
                   ignore
                     (Kind.sequence ~types:ctx.source.types ~at:iterable.at
                        value.kind);
                   (branch, value))
                 branch values
             in
             let value = Sequence_ops.zip ~ctx ~at:iterable.at values in
             let branch =
               if backed then
                 {
                   branch with
                   storage =
                     Store.remember_origin ~key:(string_of_exp value.exp)
                       ~location:[] branch.storage;
                 }
               else branch
             in
             (branch, value))
  | Syntax.Call ("range", args, keywords)
    when List.mem "range" ctx.source.builtins
         && not (List.mem "range" ctx.source.locals) ->
      range ctx iterable.at args keywords branch
  | _ ->
      translate ~ctx iterable ~branch
      |> List.map (fun (branch, value) ->
             if
               Kind.is_byte_valued ~types:ctx.source.types ~at:iterable.at
                 value.kind
             then Byte_ops.elements ~ctx ~at:iterable.at ~branch value
             else (branch, value))

and range ctx at args keywords branch =
  if keywords <> [] || (List.length args <> 1 && List.length args <> 2) then
    Error.reject ~at "Range requires one or two positional bounds";
  Sequence_ops.declare_range ~ctx ~at;
  arguments ~ctx args ~branch
  |> List.map (fun (branch, values) ->
         Sequence_ops.range ~ctx ~at ~branch values)

and sorted ctx at args keywords branch =
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
           match Kind.set_element ~types:ctx.source.types ~at input.kind with
           | Some element when numeric_order ->
               { input with kind = Sequence (element, None) }
           | Some _ ->
               Error.reject ~at
                 "Sorting a set with a key may expose its iteration order"
           | None -> input
         in
         let element, _, _ =
           Kind.sequence ~types:ctx.source.types ~at input.kind
         in
         if
           not
             (Kind.is_integer ~types:ctx.source.types ~at element
             || Kind.bits ~types:ctx.source.types ~at element = Some 64)
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
                     Kind.is_integer ~types:ctx.source.types ~at kind
                     || Kind.bits ~types:ctx.source.types ~at kind = Some 64)
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
           Sequence_ops.map ~ctx ~at
             ~captures:(captures ~at ~branch ~bound:[ local ] [ key ])
             ~element:decorate ~branch input
         in
         Sequence_ops.sort ~ctx ~at ~element ~branch decorated)

and call_signature ~ctx ~at name : S.signature =
  match
    List.find_opt (fun (s : S.signature) -> s.name = name) ctx.source.calls
  with
  | Some s -> s
  | None -> Error.reject ~at ("Call effects are not reviewed for " ^ name)

and arguments ~ctx nodes ~branch =
  collect_values (fun branch node -> translate ~ctx node ~branch) branch nodes

and eager_call ctx at operation args keywords branch =
  let contract = B.contract operation in
  let declare = List.iter (Target_builtins.declare ~ctx ~at) in
  (match contract.declarations with
  | B.BeforeArity names -> declare names
  | _ -> ());
  if keywords <> [] || List.length args <> contract.arity then
    Error.reject ~at contract.diagnostic;
  (match contract.declarations with
  | B.BeforeArguments names -> declare names
  | _ -> ());
  arguments ~ctx args ~branch
  |> List.map (fun (branch, values) ->
         let unary apply =
           match values with
           | [ value ] -> apply ~branch value
           | _ -> assert false
         in
         match operation with
         | B.Hash -> unary (Byte_ops.hash ~ctx ~at)
         | B.Serialize -> unary (Ssz_ops.serialize ~ctx ~at)
         | B.HashTreeRoot -> unary (Ssz_ops.hash_tree_root ~ctx ~at)
         | B.All -> unary (Sequence_ops.all ~ctx ~at)
         | B.Length -> unary (Sequence_ops.length ~ctx ~at)
         | B.Bytes32Value -> unary (Byte_ops.bytes32 ~ctx ~at)
         | B.NominalBytesValue name ->
             unary (Byte_ops.nominal_bytes ~ctx ~at ~name)
         | B.NumericCast name -> unary (Numeric_ops.cast ~ctx ~at ~name)
         | B.Primitive primitive ->
             Call_ops.invoke_primitive ~ctx ~at primitive ~branch ~values
         | B.LittleEndian -> unary (Byte_ops.little_endian ~ctx ~at)
         | B.AggregatePubkeys -> unary (Call_ops.aggregate_pubkeys ~ctx ~at))

and expression_pair ctx left right branch finish =
  translate ~ctx left ~branch
  |> List.concat_map (fun (branch, left) ->
         translate ~ctx right ~branch
         |> List.map (fun (branch, right) -> finish branch left right))

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
                {
                  branch with
                  storage = Store.replace_value ~name ~value branch.storage;
                  options = (name, pattern) :: branch.options;
                };
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
                      (Kind.is_named_container_or_set ~types:ctx.source.types
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
                            || Kind.is_named_container_or_set
                                 ~types:ctx.source.types ~at value.kind
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
                        Kind.set_element ~types:ctx.source.types ~at right.kind
                      with
                      | Some element -> element
                      | None ->
                          let element, _, _ =
                            Kind.sequence ~types:ctx.source.types ~at right.kind
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
                          let branch, left, right =
                            match
                              ( Kind.is_byte_valued ~types:ctx.source.types ~at
                                  left.kind,
                                Kind.is_byte_valued ~types:ctx.source.types ~at
                                  right.kind )
                            with
                            | false, false -> (branch, left, right)
                            | true, true when List.mem op Syntax.[ Eq; NotEq ]
                              ->
                                let branch, left =
                                  Byte_ops.to_bytes ~ctx ~at ~branch left
                                in
                                let branch, right =
                                  Byte_ops.to_bytes ~ctx ~at ~branch right
                                in
                                (branch, left, right)
                            | _ ->
                                Error.reject ~at
                                  "Byte comparisons require equality between \
                                   byte values"
                          in
                          if
                            Kind.set_element ~types:ctx.source.types ~at
                              left.kind
                            <> None
                            || Kind.set_element ~types:ctx.source.types ~at
                                 right.kind
                               <> None
                          then
                            Error.reject ~at
                              "Set comparisons require a membership contract";
                          (branch, left, right)))
          in
          fun truth ->
            List.map
              (fun (branch, left, right) ->
                let op = target_cmpop op in
                ( guard ~at
                    ~exp:
                      (comparison ~at
                         ~op:(if truth then op else complement op)
                         left.exp right.exp)
                    branch,
                  right ))
              combinations)
        (translate ~ctx left ~branch)
        comparisons
      |> List.map fst
  | _ ->
      translate ~ctx node ~branch
      |> List.map (fun (branch, value) ->
             if
               Kind.is_integer ~types:ctx.source.types ~at value.kind
               || Kind.bits ~types:ctx.source.types ~at value.kind <> None
             then
               (* A numeric source condition is true exactly when it is
                  nonzero. *)
               guard ~at
                 ~exp:
                   (comparison ~at
                      ~op:(if holds then `NeOp else `EqOp)
                      value.exp (nat ~at 0))
                 branch
             else (
               if not (Kind.is_boolean ~types:ctx.source.types ~at value.kind)
               then Error.reject ~at "Non-boolean truthiness";
               guard_boolean_condition ~at ~holds ~exp:value.exp branch))

and slice_bounds ~ctx ~at ~branch length ~lower ~upper ~step =
  if step <> None then
    Error.reject ~at "Stepped bitvector slices are unsupported";
  let bound branch fallback = function
    | None -> (branch, fallback)
    | Some node -> (
        let n = static_integer ctx node in
        if Bigint.compare n Bigint.zero < 0 then
          Error.reject ~at "Negative bitvector slice bounds are unsupported";
        match translate ~ctx node ~branch with
        | [ (branch, _) ] -> (branch, n)
        | _ -> Error.reject ~at "Branching slice bound")
  in
  let branch, start = bound branch Bigint.zero lower in
  let branch, finish = bound branch length upper in
  (branch, start, finish)

and record_constructor ctx at name args keywords branch =
  let record =
    Ssz_ops.prepare_record ~ctx ~at name ~positional:(args <> [])
      ~keywords:(List.map fst keywords)
  in
  collect_values
    (fun branch (name, node) ->
      translate ~ctx node ~branch
      |> List.map (fun (branch, value) ->
             let branch, value =
               Ssz_ops.record_field ~ctx ~at ~plan:record ~name ~branch value
             in
             let branch, value = bind ~ctx ~at:node.at branch ~term:value in
             (branch, (name, value))))
    branch keywords
  |> List.map (fun (branch, values) ->
         Ssz_ops.record ~ctx ~at ~plan:record values ~branch)

and repeat ctx at item input branch =
  arguments ~ctx [ item; input ] ~branch
  |> List.map (fun (branch, values) ->
         match values with
         | [ item; input ] -> Sequence_ops.repeat ~ctx ~at ~branch ~item input
         | _ -> assert false)

and extremum ctx at operation node branch =
  translate ~ctx node ~branch
  |> List.map (fun (branch, value) ->
         Sequence_ops.extremum ~ctx ~at ~operation ~branch value)

and sum ctx at args keywords branch =
  let values =
    match (args, keywords) with
    | ( [ { it = Syntax.Comprehension (element, target, iterable, filters); _ } ],
        [] ) ->
        comprehension ~set_iteration:true ctx at element target iterable filters
          branch
    | [ argument ], [] -> translate ~ctx argument ~branch
    | _ ->
        Error.reject ~at
          "sum requires one materialized uint64 or boolean sequence"
  in
  values
  |> List.concat_map (fun (branch, value) ->
         Sequence_ops.sum ~ctx ~at ~branch value)

and comprehension ?(set_iteration = false) ctx at element target
    (iterated : Syntax.expr) filters branch =
  let targets = Syntax.target_names target in
  let enumerated, iterated =
    match (iterated.it, target) with
    | Syntax.Call ("enumerate", [ value ], []), Syntax.Unpacked [ _; _ ]
      when List.mem "enumerate" ctx.source.builtins
           && not (List.mem "enumerate" ctx.source.locals) ->
        (true, value)
    | _, (Syntax.Single _ | Syntax.Unpacked (_ :: _)) -> (false, iterated)
    | _, Syntax.Unpacked [] ->
        Error.reject ~at "Comprehension target must be a name"
  in
  iterable ~ctx iterated ~branch
  |> List.map (fun (branch, value) ->
         let value =
           match Kind.set_element ~types:ctx.source.types ~at value.kind with
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
             if is_nonnegative_range ~ctx iterated then
               guard ~at
                 ~exp:(comparison ~at ~op:`LeOp (nat ~at 0) item.exp)
                 initial
             else initial
           in
           let initial =
             if enumerated then
               replace_local ~name:(List.nth targets 0) ~value:index initial
               |> replace_local ~name:(List.nth targets 1) ~value:item
             else
               match target with
               | Syntax.Unpacked _ ->
                   bind_tuple_targets ~ctx ~at
                     ~arity_error:"Comprehension tuple target arity"
                     ~branch:initial ~targets item
               | Syntax.Single name -> replace_local ~name ~value:item initial
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
         Sequence_ops.map ~ctx ~at
           ~captures:(captures ~at ~branch ~bound:targets (element :: filters))
           ~element:element_body ~branch value)
