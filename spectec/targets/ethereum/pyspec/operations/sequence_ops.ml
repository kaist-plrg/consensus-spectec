open Common.Annotated
open Lang.El
open Value

type search = Count | Index

let builtin_of_search = function
  | Count -> "count_occurrences_"
  | Index -> "index_of_"

let normalize_index ~ctx ~at ~branch value ~index =
  let python_sequence =
    match value.kind with
    | Sequence _ | FrozenSequence _ | PythonList _ -> true
    | Named name -> (
        match Typed.descriptor_of_name ~types:(Ctx.types ctx) ~at name with
        | Typed.Sequence { length = None; limit = None; bitvector = false; _ }
          ->
            if
              Value.is_integer ~types:(Ctx.types ctx) ~at index.kind
              && not (Numeric_ops.is_nonnegative ~ctx ~at ~branch index)
            then
              Error.reject ~at
                "Signed indexing through a generic Sequence requires a \
                 concrete sequence contract";
            false
        | _ -> false)
    | _ -> false
  in
  if
    (not python_sequence)
    || not (Value.is_integer ~types:(Ctx.types ctx) ~at index.kind)
  then Numeric_ops.natural_of_integer ~ctx ~at ~branch index
  else
    Branch.bind ~hint:"nat" ~ctx ~at branch
      ~term:
        {
          exp =
            call ~at "translated_list_index"
              ~args:[ index.exp; LenE value.exp $ at ];
          kind = Value.integer;
        }

let concat ~ctx ~at ~branch left ~right =
  let kind =
    match (left.kind, right.kind) with
    | Empty, kind | kind, Empty -> kind
    | Sequence (left, _), Sequence (right, _) when left = right ->
        Sequence (left, None)
    | _ -> Error.reject ~at "List concatenation requires matching element types"
  in
  Branch.bind ~ctx ~at branch
    ~term:{ exp = CatE (left.exp, right.exp) $ at; kind }

let shape ~ctx ~at ~branch value =
  let { Value.length; bitvector; _ } =
    Value.sequence ~types:(Ctx.types ctx) ~at value.kind
  in
  match (bitvector, length) with
  | true, Some length ->
      Branch.guard ~at
        ~exp:
          (comparison ~at ~op:`EqOp (LenE value.exp $ at) (number ~at length))
        branch
  | _ -> branch

let set_of_sequence ~ctx ~at ~element value =
  {
    exp =
      call
        ~types:[ Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at element ]
        ~at "to_set_" ~args:[ value.exp ];
    kind = Set element;
  }

let length ~ctx ~at ~branch value =
  if Value.set_element ~types:(Ctx.types ctx) ~at value.kind = None then
    ignore (Value.sequence ~types:(Ctx.types ctx) ~at value.kind);
  (branch, { exp = LenE value.exp $ at; kind = Value.integer })

let list_literal ~ctx ~at ~branch values =
  match values with
  | [] -> (branch, { exp = EpsE $ at; kind = Empty })
  | first :: _ ->
      if
        (not
           (Value.is_copyable_scalar ~types:(Ctx.types ctx) ~at first.kind
           || Value.is_byte_valued ~types:(Ctx.types ctx) ~at first.kind
           || Value.is_readonly_product ~types:(Ctx.types ctx) ~at first.kind))
        || not (List.for_all (fun value -> value.kind = first.kind) values)
      then
        Error.reject ~at
          "List literals require homogeneous scalars or read-only result tuples";
      Branch.bind ~ctx ~at branch
        ~term:
          {
            exp = ListE (List.map (fun value -> value.exp) values) $ at;
            kind =
              Sequence (first.kind, Some (Bigint.of_int (List.length values)));
          }

let prefix_slice ~ctx ~at ~element ~branch base ~upper =
  if
    Value.bits ~types:(Ctx.types ctx) ~at upper.kind <> Some 64
    && not
         (match upper.exp.it with
         | NumE (_, `Nat n) -> Bigint.compare n Bigint.zero >= 0
         | _ -> false)
  then Error.reject ~at "Python prefix slices require an unsigned bound";
  let branch, base = Branch.bind ~ctx ~at branch ~term:base in
  let branch, upper = Branch.bind ~ctx ~at branch ~term:upper in
  let kind = Sequence (element, None) in
  [
    ( Branch.guard ~at
        ~exp:(comparison ~at ~op:`EqOp upper.exp (nat ~at 0))
        branch,
      { exp = EpsE $ at; kind } );
    ( branch
      |> Branch.guard ~at ~exp:(comparison ~at ~op:`GtOp upper.exp (nat ~at 0))
      |> Branch.guard ~at
           ~exp:(comparison ~at ~op:`LeOp upper.exp (LenE base.exp $ at)),
      { exp = SliceE (base.exp, nat ~at 0, upper.exp) $ at; kind } );
    ( Branch.guard ~at
        ~exp:(comparison ~at ~op:`GtOp upper.exp (LenE base.exp $ at))
        branch,
      { base with kind } );
  ]

let bitvector_slice ~at ~element ~branch base ~start ~finish =
  let count = Bigint.max Bigint.zero Bigint.(finish - start) in
  let exp =
    if Bigint.equal count Bigint.zero then EpsE $ at
    else SliceE (base.exp, number ~at start, number ~at count) $ at
  in
  [ (branch, { exp; kind = Sequence (element, Some count) }) ]

let read_index ~ctx ~at ~branch value ~index =
  let { Value.element; _ } =
    Value.sequence ~types:(Ctx.types ctx) ~at value.kind
  in
  let branch = shape ~ctx ~at ~branch value in
  let exp = IdxE (value.exp, unarith index.exp) $ at in
  let key = Lang.El.Unparse.string_of_exp exp in
  match Store.read ~key branch.Branch.storage with
  | Some result -> (branch, result)
  | None ->
      let branch =
        if Value.is_integer ~types:(Ctx.types ctx) ~at index.kind then
          Branch.guard ~at
            ~exp:(comparison ~at ~op:`LeOp (nat ~at 0) index.exp)
            branch
        else branch
      in
      let branch =
        Branch.guard ~at
          ~exp:(comparison ~at ~op:`LtOp index.exp (LenE value.exp $ at))
          branch
      in
      let branch, result =
        Branch.bind ~ctx ~at branch ~term:{ exp; kind = element }
      in
      ( Branch.map_storage ~f:(Store.cache_read ~key ~value:result) branch,
        result )

let all_expansion_limit = 4

let all ~ctx ~at ~branch value =
  let { Value.element; length; _ } =
    Value.sequence ~types:(Ctx.types ctx) ~at value.kind
  in
  if not (Value.is_boolean ~types:(Ctx.types ctx) ~at element) then
    Error.reject ~at "all requires boolean elements";
  let branch = shape ~ctx ~at ~branch value in
  let branch, value = Branch.bind ~ctx ~at branch ~term:value in
  match length with
  | Some n when Bigint.compare n (Bigint.of_int all_expansion_limit) <= 0 ->
      let branch, values =
        List.fold_left_map
          (fun branch i ->
            let branch, value =
              read_index ~ctx ~at ~branch value
                ~index:{ exp = nat ~at i; kind = Value.integer }
            in
            (branch, value.exp))
          branch
          (List.init (Bigint.to_int_exn n) Fun.id)
      in
      let exp =
        List.fold_left
          (fun left right -> ParenE (BinE (left, `AndOp, right) $ at) $ at)
          (bool ~at true) values
      in
      (branch, { exp; kind = Value.boolean })
  | _ ->
      ( branch,
        {
          exp = call ~at "translated_all" ~args:[ value.exp ];
          kind = Value.boolean;
        } )

let intersection ~ctx ~at ~branch left ~right =
  let element =
    match Value.set_element ~types:(Ctx.types ctx) ~at left.kind with
    | Some element -> element
    | None -> Error.reject ~at "Intersection requires a set receiver"
  in
  let other_element =
    match Value.set_element ~types:(Ctx.types ctx) ~at right.kind with
    | Some element -> element
    | None ->
        let { Value.element; _ } =
          Value.sequence ~types:(Ctx.types ctx) ~at right.kind
        in
        element
  in
  if element <> other_element then
    Error.reject ~at "Intersection requires matching element types";
  ( branch,
    {
      exp =
        call
          ~types:[ Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at element ]
          ~at "set_intersection_" ~args:[ left.exp; right.exp ];
      kind = Set element;
    } )

let search ~ctx ~at ~search ~branch input ~needle =
  let { Value.element; _ } =
    Value.sequence ~types:(Ctx.types ctx) ~at input.kind
  in
  if needle.kind <> element then
    Error.reject ~at "Sequence search requires the declared element type";
  ( branch,
    {
      exp =
        call
          ~types:[ Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at element ]
          ~at (builtin_of_search search) ~args:[ input.exp; needle.exp ];
      kind = Value.integer;
    } )

let zip ~ctx ~at values =
  let kinds =
    List.map
      (fun value ->
        let { Value.element; _ } =
          Value.sequence ~types:(Ctx.types ctx) ~at value.kind
        in
        element)
      values
  in
  let value =
    {
      exp =
        call
          ~types:
            (List.map (Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at) kinds)
          ~at "translated_zip"
          ~args:(List.map (fun value -> value.exp) values);
      kind = Sequence (Product kinds, None);
    }
  in
  value

let range ~ctx ~at ~branch values =
  if
    not
      (List.for_all
         (fun value ->
           Value.is_integer ~types:(Ctx.types ctx) ~at value.kind
           || Value.bits ~types:(Ctx.types ctx) ~at value.kind <> None)
         values)
  then Error.reject ~at "Range bounds require integers";
  let actuals =
    match values with
    | [ stop ] -> [ nat ~at 0; stop.exp ]
    | [ first; stop ] -> [ first.exp; stop.exp ]
    | _ -> assert false
  in
  ( branch,
    {
      exp = call ~at "translated_range" ~args:actuals;
      kind = Sequence (Value.integer, None);
    } )

let sort ~ctx ~at ~element ~branch decorated =
  let branch, decorated = Branch.bind ~ctx ~at branch ~term:decorated in
  let { Value.element = decorated_kind; _ } =
    Value.sequence ~types:(Ctx.types ctx) ~at decorated.kind
  in
  let kinds = Value.product ~types:(Ctx.types ctx) ~at decorated_kind in
  let key_count = List.length kinds - 1 in
  let sequence_kind = decorated.kind in
  let insert_name = Ctx.fresh_helper_name ctx ~operation:"sort_insert" in
  let sort_name = Ctx.fresh_helper_name ctx ~operation:"sort" in
  let values_name = Ctx.fresh_helper_name ctx ~operation:"sort_values" in
  let helper name inputs result equations =
    Value.function_definitions ~at name
      ~parameters:
        (List.map (Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at) inputs)
      ~result:(Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at result)
      ~equations
  in
  let first = List.map (fun kind -> Ctx.fresh ctx ~at ~kind) kinds in
  let second = List.map (fun kind -> Ctx.fresh ctx ~at ~kind) kinds in
  let tuple values = TupleE (List.map (fun value -> value.exp) values) $ at in
  let first_tuple = tuple first and second_tuple = tuple second in
  let tail = Ctx.fresh ctx ~at ~kind:sequence_kind in
  let rec less_equal left right =
    match (left, right) with
    | [ left ], [ right ] -> comparison ~at ~op:`LeOp left.exp right.exp
    | left :: lefts, right :: rights ->
        ParenE
          (BinE
             ( comparison ~at ~op:`LtOp left.exp right.exp,
               `OrOp,
               ParenE
                 (BinE
                    ( comparison ~at ~op:`EqOp left.exp right.exp,
                      `AndOp,
                      less_equal lefts rights )
                 $ at)
               $ at )
          $ at)
        $ at
    | _ -> assert false
  in
  let take_keys values =
    List.filteri (fun index _ -> index < key_count) values
  in
  let precedes = less_equal (take_keys first) (take_keys second) in
  let nonempty = ConsE (second_tuple, tail.exp) $ at in
  let definitions =
    helper insert_name
      [ decorated_kind; sequence_kind ]
      sequence_kind
      [
        ([ first_tuple; EpsE $ at ], ListE [ first_tuple ] $ at, []);
        ( [ first_tuple; nonempty ],
          ConsE (first_tuple, nonempty) $ at,
          [ IfPr precedes $ at ] );
        ( [ first_tuple; nonempty ],
          ConsE
            (second_tuple, call ~at insert_name ~args:[ first_tuple; tail.exp ])
          $ at,
          [ IfPr (UnE (`NotOp, ParenE precedes $ at) $ at) $ at ] );
      ]
    @ helper sort_name [ sequence_kind ] sequence_kind
        [
          ([ EpsE $ at ], EpsE $ at, []);
          ( [ ConsE (first_tuple, tail.exp) $ at ],
            call ~at insert_name
              ~args:[ first_tuple; call ~at sort_name ~args:[ tail.exp ] ],
            [] );
        ]
    @ helper values_name [ sequence_kind ]
        (Sequence (element, None))
        [
          ([ EpsE $ at ], EpsE $ at, []);
          ( [ ConsE (first_tuple, tail.exp) $ at ],
            ConsE
              ( (List.hd (List.rev first)).exp,
                call ~at values_name ~args:[ tail.exp ] )
            $ at,
            [] );
        ]
  in
  Ctx.emit_helper ctx ~definitions;
  ( branch,
    {
      exp =
        call ~at values_name
          ~args:[ call ~at sort_name ~args:[ decorated.exp ] ];
      kind = Sequence (element, None);
    } )

let repeat ~ctx ~at ~branch ~item input =
  if not (Value.is_copyable_scalar ~types:(Ctx.types ctx) ~at item.kind) then
    Error.reject ~at "List repetition requires an immutable scalar element";
  ignore (Value.sequence ~types:(Ctx.types ctx) ~at input.kind);
  ( branch,
    {
      exp =
        call
          ~types:[ Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at item.kind ]
          ~at "repeat_"
          ~args:[ item.exp; LenE input.exp $ at ];
      kind = Sequence (item.kind, None);
    } )

let extremum ~ctx ~at ~operation ~branch value =
  if Value.set_element ~types:(Ctx.types ctx) ~at value.kind <> None then
    Error.reject ~at "Set extrema require a reviewed consumer";
  let { Value.element; _ } =
    Value.sequence ~types:(Ctx.types ctx) ~at value.kind
  in
  if
    not
      (Value.is_integer ~types:(Ctx.types ctx) ~at element
      || Value.bits ~types:(Ctx.types ctx) ~at element = Some 64)
  then
    Error.reject ~at
      "Sequence extrema require homogeneous integer or uint64 elements";
  let branch, value = Branch.bind ~ctx ~at branch ~term:value in
  let branch, first =
    read_index ~ctx ~at ~branch value
      ~index:{ exp = nat ~at 0; kind = Value.integer }
  in
  let branch, remaining =
    Branch.bind ~hint:"nat" ~ctx ~at branch
      ~term:
        {
          exp = arithmetic ~at ~op:`SubOp (LenE value.exp $ at) (nat ~at 1);
          kind = Value.integer;
        }
  in
  let name =
    Ctx.fresh_helper_name ctx
      ~operation:(Numeric_ops.string_of_extremum operation)
  in
  let head = Ctx.fresh ctx ~at ~kind:element in
  let tail = Ctx.fresh ctx ~at ~kind:(Sequence (element, None)) in
  let accumulator = Ctx.fresh ctx ~at ~kind:element in
  let definition input result premises =
    ([ input; accumulator.exp ], result, premises)
  in
  let cons = ConsE (head.exp, tail.exp) $ at in
  let definitions =
    Value.function_definitions ~at name
      ~parameters:
        [
          Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at tail.kind;
          Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at element;
        ]
      ~result:(Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at element)
      ~equations:
        ([ definition (EpsE $ at) accumulator.exp [] ]
        @ List.map
            (fun (branch, selected) ->
              definition cons
                (call ~at name ~args:[ tail.exp; selected.exp ])
                branch.Branch.premises)
            (Numeric_ops.extremum ~ctx ~at ~operation
               ~branch:(Branch.make (Store.make []))
               [ accumulator; head ]))
  in
  Ctx.emit_helper ctx ~definitions;
  ( branch,
    {
      exp =
        call ~at name
          ~args:[ SliceE (value.exp, nat ~at 1, remaining.exp) $ at; first.exp ];
      kind = element;
    } )

let sum ~ctx ~at ~branch value =
  let value =
    match Value.set_element ~types:(Ctx.types ctx) ~at value.kind with
    | Some element -> { value with kind = Sequence (element, None) }
    | None -> value
  in
  if value.kind = Empty then
    [ (branch, { exp = nat ~at 0; kind = Value.integer }) ]
  else
    let { Value.element; _ } =
      Value.sequence ~types:(Ctx.types ctx) ~at value.kind
    in
    if Value.is_boolean ~types:(Ctx.types ctx) ~at element then
      let branch = shape ~ctx ~at ~branch value in
      let branch, result =
        Branch.bind ~ctx ~at branch
          ~term:
            {
              exp = call ~at "translated_sum_booleans" ~args:[ value.exp ];
              kind = Value.integer;
            }
      in
      let branch =
        Branch.guard ~at
          ~exp:(comparison ~at ~op:`LeOp (nat ~at 0) result.exp)
          branch
      in
      [ (branch, result) ]
    else (
      if Value.bits ~types:(Ctx.types ctx) ~at element <> Some 64 then
        Error.reject ~at "sum requires uint64 or boolean elements";
      let branch, value = Branch.bind ~ctx ~at branch ~term:value in
      let name = Ctx.fresh_helper_name ctx ~operation:"sum" in
      let values = Ctx.fresh ctx ~at ~kind:(Sequence (element, None)) in
      let initial = Branch.make (Store.make []) in
      let length = LenE values.exp $ at in
      let split =
        Branch.guard ~at
          ~exp:(comparison ~at ~op:`GtOp length (nat ~at 1))
          initial
      in
      let split, middle =
        Branch.bind ~hint:"nat" ~ctx ~at split
          ~term:
            {
              exp = arithmetic ~at ~op:`DivOp length (nat ~at 2);
              kind = Value.integer;
            }
      in
      let split, remaining =
        Branch.bind ~hint:"nat" ~ctx ~at split
          ~term:
            {
              exp = arithmetic ~at ~op:`SubOp length middle.exp;
              kind = Value.integer;
            }
      in
      let half start count =
        call ~at name ~args:[ SliceE (values.exp, start, count) $ at ]
      in
      let split, left =
        Branch.bind ~ctx ~at split
          ~term:{ exp = half (nat ~at 0) middle.exp; kind = element }
      in
      let split, right =
        Branch.bind ~ctx ~at split
          ~term:{ exp = half middle.exp remaining.exp; kind = element }
      in
      let split, result =
        Numeric_ops.binary ~ctx ~at ~op:Syntax.Add ~branch:split left right
      in
      let single =
        Branch.guard ~at
          ~exp:(comparison ~at ~op:`EqOp length (nat ~at 1))
          initial
      in
      let single, item =
        read_index ~ctx ~at ~branch:single values
          ~index:{ exp = nat ~at 0; kind = Value.integer }
      in
      let definition result branch =
        ([ values.exp ], result, branch.Branch.premises)
      in
      let definitions =
        Value.function_definitions ~at name
          ~parameters:
            [ Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at values.kind ]
          ~result:(Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at element)
          ~equations:[ definition item.exp single; definition result.exp split ]
      in
      Ctx.emit_helper ctx ~definitions;
      let empty =
        Branch.guard ~at
          ~exp:(comparison ~at ~op:`EqOp (LenE value.exp $ at) (nat ~at 0))
          branch
      in
      let nonempty =
        Branch.guard ~at
          ~exp:(comparison ~at ~op:`GtOp (LenE value.exp $ at) (nat ~at 0))
          branch
      in
      [
        (empty, { exp = nat ~at 0; kind = Value.integer });
        (nonempty, { exp = call ~at name ~args:[ value.exp ]; kind = element });
      ])
