open Common.Source
open Lang.El
open Kind
open Operand
module S = Source

let normalize_index ~ctx ~at ~branch value ~index =
  let python_sequence =
    match value.kind with
    | Sequence _ | FrozenSequence _ | PythonList _ -> true
    | Named name -> (
        match Kind.descriptor ~types:(Ctx.types ctx) ~at name with
        | S.Sequence { length = None; limit = None; bitvector = false; _ } ->
            if
              Kind.is_integer ~types:(Ctx.types ctx) ~at index.kind
              && (not
                    (match index.exp.it with
                    | NumE (_, `Nat n) -> Bigint.compare n Bigint.zero >= 0
                    | _ -> false))
              && not
                   (Branch.has_condition branch
                      ~condition:
                        (comparison ~at ~op:`LeOp (nat ~at 0) index.exp))
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
    || not (Kind.is_integer ~types:(Ctx.types ctx) ~at index.kind)
  then Numeric_ops.to_natural ~ctx ~at ~branch index
  else
    let name = "translated_list_index" in
    Ctx.share_helper_text ctx ~at ~name ~operation:"python_list_index"
      ~text:
        "dec $translated_list_index(int, nat): nat\n\
         def $translated_list_index(int_index, nat_length) = nat_index\n\
        \  -- if $(0 <= int_index)\n\
        \  -- if int_index = nat_index\n\
         def $translated_list_index(int_index, nat_length) = nat_index\n\
        \  -- if $(int_index < 0)\n\
        \  -- if $(0 <= nat_length + int_index)\n\
        \  -- if $(nat_length + int_index) = nat_index\n";
    Branch.bind ~hint:"nat" ~ctx ~at branch
      ~term:
        {
          exp = call ~at name ~args:[ index.exp; LenE value.exp $ at ];
          kind = Named "int";
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
  let _, length, bitvector =
    Kind.sequence ~types:(Ctx.types ctx) ~at value.kind
  in
  match (bitvector, length) with
  | true, Some length ->
      Branch.guard ~at
        ~exp:
          (comparison ~at ~op:`EqOp (LenE value.exp $ at) (number ~at length))
        branch
  | _ -> branch

let make_set ~ctx ~at ~element value =
  let name = "translated_set" in
  Ctx.share_helper ctx ~name ~definitions:(fun () ->
      let type_argument = VarT (id ~at "X", []) $ at in
      let sequence = IterT (type_argument, List) $ at in
      let x = var ~at "X_first" in
      let tail = IterE (var ~at "X_rest", List) $ at in
      let member = MemE (x, tail) $ at in
      let recursive = call ~types:[ type_argument ] ~at name ~args:[ tail ] in
      let def input output premises = ([ input ], output, premises) in
      Operand.function_definitions ~type_parameters:[ "X" ] ~at name
        ~parameters:[ sequence ] ~result:sequence
        ~equations:
          [
            def (EpsE $ at) (EpsE $ at) [];
            def (ConsE (x, tail) $ at) recursive [ IfPr member $ at ];
            def
              (ConsE (x, tail) $ at)
              (ConsE (x, recursive) $ at)
              [ IfPr (UnE (`NotOp, ParenE member $ at) $ at) $ at ];
          ]);
  {
    exp =
      call
        ~types:[ Operand.typ ~types:(Ctx.types ctx) ~at element ]
        ~at name ~args:[ value.exp ];
    kind = Set element;
  }

let length ~ctx ~at ~branch value =
  if Kind.set_element ~types:(Ctx.types ctx) ~at value.kind = None then
    ignore (Kind.sequence ~types:(Ctx.types ctx) ~at value.kind);
  (branch, { exp = LenE value.exp $ at; kind = Kind.integer })

let list_literal ~ctx ~at ~branch values =
  match values with
  | [] -> (branch, { exp = EpsE $ at; kind = Empty })
  | first :: _ ->
      if
        (not
           (Kind.is_copyable_scalar ~types:(Ctx.types ctx) ~at first.kind
           || Kind.is_byte_valued ~types:(Ctx.types ctx) ~at first.kind
           || Kind.is_readonly_product ~types:(Ctx.types ctx) ~at first.kind))
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
    Kind.bits ~types:(Ctx.types ctx) ~at upper.kind <> Some 64
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
  let branch =
    if Bigint.equal count Bigint.zero then branch
    else
      Branch.guard ~at
        ~exp:(comparison ~at ~op:`LeOp (number ~at finish) (LenE base.exp $ at))
        branch
  in
  let exp =
    if Bigint.equal count Bigint.zero then EpsE $ at
    else SliceE (base.exp, number ~at start, number ~at count) $ at
  in
  [ (branch, { exp; kind = Sequence (element, Some count) }) ]

let read_index ~ctx ~at ~branch value ~index =
  let element, _, _ = Kind.sequence ~types:(Ctx.types ctx) ~at value.kind in
  let branch = shape ~ctx ~at ~branch value in
  let exp = IdxE (value.exp, unarith index.exp) $ at in
  let key = string_of_exp exp in
  match Store.read ~key branch.Branch.storage with
  | Some result -> (branch, result)
  | None ->
      let branch =
        if Kind.is_integer ~types:(Ctx.types ctx) ~at index.kind then
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
      ( {
          branch with
          Branch.storage =
            Store.cache_read ~key ~value:result branch.Branch.storage;
        },
        result )

let all ~ctx ~at ~branch value =
  let element, length, _ =
    Kind.sequence ~types:(Ctx.types ctx) ~at value.kind
  in
  if not (Kind.is_boolean ~types:(Ctx.types ctx) ~at element) then
    Error.reject ~at "all requires boolean elements";
  let branch = shape ~ctx ~at ~branch value in
  let branch, value = Branch.bind ~ctx ~at branch ~term:value in
  match length with
  | Some n
    when Bigint.compare n (Bigint.of_int ctx.Ctx.source.all_expansion_limit)
         <= 0 ->
      let branch, values =
        List.fold_left_map
          (fun branch i ->
            let branch, value =
              read_index ~ctx ~at ~branch value
                ~index:{ exp = nat ~at i; kind = Kind.integer }
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
      (branch, { exp; kind = Kind.boolean })
  | _ ->
      let name = Ctx.fresh_helper_name ctx ~operation:"all" in
      let kind = Sequence (Kind.boolean, None) in
      let tail = Ctx.fresh ctx ~at ~kind in
      let definitions =
        Operand.function_definitions ~at name
          ~parameters:[ Operand.typ ~types:(Ctx.types ctx) ~at kind ]
          ~result:(BoolT $ at)
          ~equations:
            [
              ([ EpsE $ at ], bool ~at true, []);
              ([ ConsE (bool ~at false, tail.exp) $ at ], bool ~at false, []);
              ( [ ConsE (bool ~at true, tail.exp) $ at ],
                call ~at name ~args:[ tail.exp ],
                [] );
            ]
      in
      Ctx.emit_helper ctx ~definitions;
      (branch, { exp = call ~at name ~args:[ value.exp ]; kind = Kind.boolean })

let map ~ctx ~at ~captures ~element ~branch value =
  ignore (Kind.sequence ~types:(Ctx.types ctx) ~at value.kind);
  let branch, value = Branch.bind ~ctx ~at branch ~term:value in
  let index = Ctx.fresh ~hint:"nat" ctx ~at ~kind:Kind.integer in
  let name = Ctx.fresh_helper_name ctx ~operation:"comprehension" in
  let captured_values = List.map snd captures in
  let arguments = captured_values @ [ value; index ] in
  let initial =
    Branch.make (Store.make captures)
    |> Branch.guard ~at ~exp:(comparison ~at ~op:`LeOp (nat ~at 0) index.exp)
  in
  let initial, item = read_index ~ctx ~at ~branch:initial value ~index in
  let values, skipped = element initial index item in
  let kind =
    match values with
    | (_, value) :: _
      when List.for_all (fun (_, v) -> v.kind = value.kind) values ->
        Sequence (value.kind, None)
    | _ -> Error.reject ~at "Comprehension requires a uniform result type"
  in
  let parameters =
    List.map
      (fun value -> Operand.typ ~types:(Ctx.types ctx) ~at value.kind)
      (captured_values @ [ value ])
    @ [ NumT `NatT $ at ]
  in
  let actuals = List.map (fun t -> t.exp) (captured_values @ [ value ]) in
  let tail =
    call ~at name
      ~args:(actuals @ [ arithmetic ~at ~op:`AddOp index.exp (nat ~at 1) ])
  in
  let def result prems = (List.map (fun t -> t.exp) arguments, result, prems) in
  let end_prems =
    [
      IfPr (comparison ~at ~op:`LeOp (nat ~at 0) index.exp) $ at;
      IfPr (comparison ~at ~op:`GeOp index.exp (LenE value.exp $ at)) $ at;
    ]
  in
  let definitions =
    Operand.function_definitions ~at name ~parameters
      ~result:(Operand.typ ~types:(Ctx.types ctx) ~at kind)
      ~equations:
        ([ def (EpsE $ at) end_prems ]
        @ List.map
            (fun (branch, value) ->
              def
                (CatE (ListE [ value.exp ] $ at, tail) $ at)
                branch.Branch.premises)
            values
        @ List.map (fun branch -> def tail branch.Branch.premises) skipped)
  in
  Ctx.emit_helper ctx ~definitions;
  (branch, { exp = call ~at name ~args:(actuals @ [ nat ~at 0 ]); kind })

let intersection ~ctx ~at ~branch left ~right =
  let element =
    match Kind.set_element ~types:(Ctx.types ctx) ~at left.kind with
    | Some element -> element
    | None -> Error.reject ~at "Intersection requires a set receiver"
  in
  let other_element =
    match Kind.set_element ~types:(Ctx.types ctx) ~at right.kind with
    | Some element -> element
    | None ->
        let element, _, _ =
          Kind.sequence ~types:(Ctx.types ctx) ~at right.kind
        in
        element
  in
  if element <> other_element then
    Error.reject ~at "Intersection requires matching element types";
  let name = Ctx.fresh_helper_name ctx ~operation:"intersection" in
  let head = Ctx.fresh ctx ~at ~kind:element in
  let tail = Ctx.fresh ctx ~at ~kind:(Sequence (element, None)) in
  let others = Ctx.fresh ctx ~at ~kind:(Sequence (element, None)) in
  let member = MemE (head.exp, others.exp) $ at in
  let recurse = call ~at name ~args:[ tail.exp; others.exp ] in
  let definition input result premises =
    ( [ input; others.exp ],
      result,
      List.map (fun premise -> IfPr premise $ at) premises )
  in
  let definitions =
    Operand.function_definitions ~at name
      ~parameters:
        (List.map
           (fun value -> Operand.typ ~types:(Ctx.types ctx) ~at value.kind)
           [ tail; others ])
      ~result:(Operand.typ ~types:(Ctx.types ctx) ~at tail.kind)
      ~equations:
        [
          definition (EpsE $ at) (EpsE $ at) [];
          definition
            (ConsE (head.exp, tail.exp) $ at)
            (ConsE (head.exp, recurse) $ at)
            [ member ];
          definition
            (ConsE (head.exp, tail.exp) $ at)
            recurse
            [ UnE (`NotOp, ParenE member $ at) $ at ];
        ]
  in
  Ctx.emit_helper ctx ~definitions;
  ( branch,
    { exp = call ~at name ~args:[ left.exp; right.exp ]; kind = Set element } )

let search ~ctx ~at ~method_name:method_ ~branch input ~needle =
  let element, _, _ = Kind.sequence ~types:(Ctx.types ctx) ~at input.kind in
  if needle.kind <> element then
    Error.reject ~at "Sequence search requires the declared element type";
  let name = Ctx.fresh_helper_name ctx ~operation:method_ in
  let sequence_kind = Sequence (element, None) in
  let items = Ctx.fresh ctx ~at ~kind:sequence_kind in
  let wanted = Ctx.fresh ctx ~at ~kind:element in
  let index = Ctx.fresh ~hint:"nat" ctx ~at ~kind:Kind.integer in
  let parameters =
    [
      Operand.typ ~types:(Ctx.types ctx) ~at sequence_kind;
      Operand.typ ~types:(Ctx.types ctx) ~at element;
      NumT `NatT $ at;
    ]
  in
  let actuals = [ items.exp; wanted.exp; index.exp ] in
  let bounded = comparison ~at ~op:`LtOp index.exp (LenE items.exp $ at) in
  let equal =
    comparison ~at ~op:`EqOp (IdxE (items.exp, index.exp) $ at) wanted.exp
  in
  let next =
    call ~at name
      ~args:
        [
          items.exp; wanted.exp; arithmetic ~at ~op:`AddOp index.exp (nat ~at 1);
        ]
  in
  let definition result guards =
    (actuals, result, List.map (fun guard -> IfPr guard $ at) guards)
  in
  let clauses =
    if method_ = "count" then
      [
        definition (nat ~at 0)
          [ comparison ~at ~op:`GeOp index.exp (LenE items.exp $ at) ];
        definition
          (arithmetic ~at ~op:`AddOp (nat ~at 1) next)
          [ bounded; equal ];
        definition next [ bounded; UnE (`NotOp, ParenE equal $ at) $ at ];
      ]
    else
      [
        definition index.exp [ bounded; equal ];
        definition next [ bounded; UnE (`NotOp, ParenE equal $ at) $ at ];
      ]
  in
  let definitions =
    Operand.function_definitions ~at name ~parameters ~result:(NumT `IntT $ at)
      ~equations:clauses
  in
  Ctx.emit_helper ctx ~definitions;
  ( branch,
    {
      exp = call ~at name ~args:[ input.exp; needle.exp; nat ~at 0 ];
      kind = Kind.integer;
    } )

let zip ~ctx ~at values =
  let kinds =
    List.map
      (fun value ->
        let element, _, _ =
          Kind.sequence ~types:(Ctx.types ctx) ~at value.kind
        in
        element)
      values
  in
  let name = "translated_zip" in
  Ctx.share_helper_text ctx ~at ~name ~operation:"zip"
    ~text:
      {|
            dec $translated_zip<X, Y>(X*, Y*): (X, Y)*
            def $translated_zip<X, Y>(eps, Y_tail*) = eps
            def $translated_zip<X, Y>(X_head :: X_tail*, eps) = eps
            def $translated_zip<X, Y>(X_head :: X_tail*, Y_head :: Y_tail*) = [(X_head, Y_head)] ++ $translated_zip<X, Y>(X_tail*, Y_tail*)
          |};
  let value =
    {
      exp =
        call
          ~types:(List.map (Operand.typ ~types:(Ctx.types ctx) ~at) kinds)
          ~at name
          ~args:(List.map (fun value -> value.exp) values);
      kind = Sequence (Product kinds, None);
    }
  in
  value

let range_name = "translated_range"

let declare_range ~ctx ~at =
  let name = range_name in
  if not (Registry.declared_function ~name ctx.Ctx.registry) then
    let first = var ~at "int_range_start" and stop = var ~at "int_range_stop" in
    let typ = NumT `IntT $ at in
    let def value test = ([ first; stop ], value, [ IfPr test $ at ]) in
    Registry.emit ~registry:ctx.Ctx.registry ~ownership:Shared
      (Operand.function_definitions ~at name ~parameters:[ typ; typ ]
         ~result:(IterT (typ, List) $ at)
         ~equations:
           [
             def (EpsE $ at) (comparison ~at ~op:`GeOp first stop);
             def
               (CatE
                  ( ListE [ first ] $ at,
                    call ~at name
                      ~args:
                        [ arithmetic ~at ~op:`AddOp first (nat ~at 1); stop ] )
               $ at)
               (comparison ~at ~op:`LtOp first stop);
           ])

let range ~ctx ~at ~branch values =
  let name = range_name in
  if
    not
      (List.for_all
         (fun value ->
           Kind.is_integer ~types:(Ctx.types ctx) ~at value.kind
           || Kind.bits ~types:(Ctx.types ctx) ~at value.kind <> None)
         values)
  then Error.reject ~at "Range bounds require integers";
  let actuals =
    match values with
    | [ stop ] -> [ nat ~at 0; stop.exp ]
    | [ first; stop ] -> [ first.exp; stop.exp ]
    | _ -> assert false
  in
  ( branch,
    { exp = call ~at name ~args:actuals; kind = Sequence (Kind.integer, None) }
  )

let sort ~ctx ~at ~element ~branch decorated =
  let branch, decorated = Branch.bind ~ctx ~at branch ~term:decorated in
  let decorated_kind, _, _ =
    Kind.sequence ~types:(Ctx.types ctx) ~at decorated.kind
  in
  let kinds = Kind.product ~types:(Ctx.types ctx) ~at decorated_kind in
  let key_count = List.length kinds - 1 in
  let sequence_kind = decorated.kind in
  let insert_name = Ctx.fresh_helper_name ctx ~operation:"sort_insert" in
  let sort_name = Ctx.fresh_helper_name ctx ~operation:"sort" in
  let values_name = Ctx.fresh_helper_name ctx ~operation:"sort_values" in
  let helper name inputs result equations =
    Operand.function_definitions ~at name
      ~parameters:(List.map (Operand.typ ~types:(Ctx.types ctx) ~at) inputs)
      ~result:(Operand.typ ~types:(Ctx.types ctx) ~at result)
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
  if not (Kind.is_copyable_scalar ~types:(Ctx.types ctx) ~at item.kind) then
    Error.reject ~at "List repetition requires an immutable scalar element";
  ignore (Kind.sequence ~types:(Ctx.types ctx) ~at input.kind);
  let name = "translated_repeat_to_length" in
  Ctx.share_helper_text ctx ~at ~name
    ~operation:"singleton_repetition_to_length"
    ~text:
      "dec $translated_repeat_to_length<X>(X, nat): X*\n\
       def $translated_repeat_to_length<X>(X_value, 0) = eps\n\
       def $translated_repeat_to_length<X>(X_value, nat_count) = X_value :: \
       $translated_repeat_to_length<X>(X_value, $(nat_count - 1))\n\
      \  -- if $(0 < nat_count)\n";
  ( branch,
    {
      exp =
        call
          ~types:[ Operand.typ ~types:(Ctx.types ctx) ~at item.kind ]
          ~at name
          ~args:[ item.exp; LenE input.exp $ at ];
      kind = Sequence (item.kind, None);
    } )

let extremum ~ctx ~at ~operation ~branch value =
  if Kind.set_element ~types:(Ctx.types ctx) ~at value.kind <> None then
    Error.reject ~at "Set extrema require a reviewed consumer";
  let element, _, _ = Kind.sequence ~types:(Ctx.types ctx) ~at value.kind in
  if
    not
      (Kind.is_integer ~types:(Ctx.types ctx) ~at element
      || Kind.bits ~types:(Ctx.types ctx) ~at element = Some 64)
  then
    Error.reject ~at
      "Sequence extrema require homogeneous integer or uint64 elements";
  let branch, value = Branch.bind ~ctx ~at branch ~term:value in
  let branch, first =
    read_index ~ctx ~at ~branch value
      ~index:{ exp = nat ~at 0; kind = Kind.integer }
  in
  let branch, remaining =
    Branch.bind ~hint:"nat" ~ctx ~at branch
      ~term:
        {
          exp = arithmetic ~at ~op:`SubOp (LenE value.exp $ at) (nat ~at 1);
          kind = Kind.integer;
        }
  in
  let name = Ctx.fresh_helper_name ctx ~operation in
  let head = Ctx.fresh ctx ~at ~kind:element in
  let tail = Ctx.fresh ctx ~at ~kind:(Sequence (element, None)) in
  let accumulator = Ctx.fresh ctx ~at ~kind:element in
  let definition input result premises =
    ([ input; accumulator.exp ], result, premises)
  in
  let cons = ConsE (head.exp, tail.exp) $ at in
  let definitions =
    Operand.function_definitions ~at name
      ~parameters:
        [
          Operand.typ ~types:(Ctx.types ctx) ~at tail.kind;
          Operand.typ ~types:(Ctx.types ctx) ~at element;
        ]
      ~result:(Operand.typ ~types:(Ctx.types ctx) ~at element)
      ~equations:
        ([ definition (EpsE $ at) accumulator.exp [] ]
        @ List.map
            (fun (branch, selected) ->
              definition cons
                (call ~at name ~args:[ tail.exp; selected.exp ])
                branch.Branch.premises)
            (Numeric_ops.extremum ~ctx ~at ~name:operation
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
  if value.kind = Empty then
    [ (branch, { exp = nat ~at 0; kind = Kind.integer }) ]
  else
    let element, _, _ = Kind.sequence ~types:(Ctx.types ctx) ~at value.kind in
    if Kind.is_boolean ~types:(Ctx.types ctx) ~at element then (
      let branch = shape ~ctx ~at ~branch value in
      let name = "translated_sum_booleans" in
      Ctx.share_helper_text ctx ~at ~name ~operation:"boolean_sum"
        ~text:
          {|
               dec $translated_sum_booleans(bool*): int
               def $translated_sum_booleans(eps) = 0
               def $translated_sum_booleans(true :: bool_tail*) = $(1 + $translated_sum_booleans(bool_tail*))
               def $translated_sum_booleans(false :: bool_tail*) = $translated_sum_booleans(bool_tail*)
             |};
      let branch, result =
        Branch.bind ~ctx ~at branch
          ~term:{ exp = call ~at name ~args:[ value.exp ]; kind = Kind.integer }
      in
      let branch =
        Branch.guard ~at
          ~exp:(comparison ~at ~op:`LeOp (nat ~at 0) result.exp)
          branch
      in
      [ (branch, result) ])
    else (
      if Kind.bits ~types:(Ctx.types ctx) ~at element <> Some 64 then
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
              kind = Kind.integer;
            }
      in
      let split, remaining =
        Branch.bind ~hint:"nat" ~ctx ~at split
          ~term:
            {
              exp = arithmetic ~at ~op:`SubOp length middle.exp;
              kind = Kind.integer;
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
          ~index:{ exp = nat ~at 0; kind = Kind.integer }
      in
      let definition result branch =
        ([ values.exp ], result, branch.Branch.premises)
      in
      let definitions =
        Operand.function_definitions ~at name
          ~parameters:[ Operand.typ ~types:(Ctx.types ctx) ~at values.kind ]
          ~result:(Operand.typ ~types:(Ctx.types ctx) ~at element)
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
        (empty, { exp = nat ~at 0; kind = Kind.integer });
        (nonempty, { exp = call ~at name ~args:[ value.exp ]; kind = element });
      ])
