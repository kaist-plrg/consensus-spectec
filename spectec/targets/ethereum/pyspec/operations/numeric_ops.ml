open Common.Annotated
open Lang.El
open Value

type extremum = Min | Max

let string_of_extremum = function Min -> "min" | Max -> "max"

let natural_of_integer ~ctx ~at ~branch index =
  if Value.is_integer ~types:(Ctx.types ctx) ~at index.kind then
    let branch =
      Branch.guard ~at
        ~exp:(comparison ~at ~op:`LeOp (nat ~at 0) index.exp)
        branch
    in
    Branch.bind ~hint:"nat" ~ctx ~at branch ~term:index
  else (branch, index)

let unsigned_maximum width = Bigint.(pow (of_int 2) (of_int width) - one)

let unsigned_bounds ~at ~bits exp =
  [
    comparison ~at ~op:`LeOp (nat ~at 0) exp;
    comparison ~at ~op:`LtOp exp (number ~at Bigint.(pow (of_int 2) bits));
  ]

let guard_unsigned_bounds ~at ~bits ~branch value =
  List.fold_left
    (fun branch exp -> Branch.guard ~at ~exp branch)
    branch
    (unsigned_bounds ~at ~bits value.exp)

(* Nonnegativity follows from the source kind, expression structure or an
   existing branch condition. *)
let is_nonnegative ~ctx ~at ~branch value =
  let positive_literal exp =
    match exp.it with
    | NumE (_, `Nat n) -> Bigint.compare n Bigint.zero > 0
    | _ -> false
  in
  let rec known exp =
    match exp.it with
    | NumE (_, `Nat _) | LenE _ -> true
    | ParenE inner | ArithE inner -> known inner
    | BinE (left, (`AddOp | `MulOp | `PowOp | `DivOp), right) ->
        known left && known right
    (* The dividend of a translated modulo is already known nonnegative, so a
       positive divisor bounds the result to that divisor's range. *)
    | BinE (_, `ModOp, right) -> positive_literal right
    | _ ->
        List.exists
          (fun condition -> Branch.has_condition branch ~condition)
          [
            comparison ~at ~op:`LeOp (nat ~at 0) exp;
            comparison ~at ~op:`GeOp exp (nat ~at 0);
            comparison ~at ~op:`LtOp (nat ~at 0) exp;
            comparison ~at ~op:`GtOp exp (nat ~at 0);
            comparison ~at ~op:`EqOp exp (nat ~at 0);
            comparison ~at ~op:`EqOp (nat ~at 0) exp;
          ]
  in
  Value.bits ~types:(Ctx.types ctx) ~at value.kind <> None
  || value.kind = ByteInteger || known value.exp

let bitwise ~ctx ~at ~op ~branch left right =
  let plain =
    Value.is_integer ~types:(Ctx.types ctx) ~at left.kind
    && Value.is_integer ~types:(Ctx.types ctx) ~at right.kind
  in
  if plain then (
    if
      not
        (is_nonnegative ~ctx ~at ~branch left
        && is_nonnegative ~ctx ~at ~branch right)
    then
      Error.reject ~at
        "Plain integer bitwise operands must be provably nonnegative")
  else if
    Value.bits ~types:(Ctx.types ctx) ~at left.kind <> Some 8
    || Value.bits ~types:(Ctx.types ctx) ~at right.kind <> Some 8
  then
    Error.reject ~at
      "Bitwise operations require two uint8 values or nonnegative integers";
  let name =
    match op with
    | Syntax.BitAnd -> "and_uint64"
    | Syntax.BitOr -> "translated_bit_or"
    | Syntax.BitXor -> "translated_bit_xor"
    | _ -> invalid_arg "Numeric_ops.bitwise: not a bitwise operator"
  in
  let kind =
    if (not plain) || (left.kind = ByteInteger && right.kind = ByteInteger) then
      left.kind
    else Value.integer
  in
  let branch, left =
    if plain then natural_of_integer ~ctx ~at ~branch left else (branch, left)
  in
  let branch, right =
    if plain then natural_of_integer ~ctx ~at ~branch right else (branch, right)
  in
  Branch.bind ~ctx ~at branch
    ~term:{ exp = call ~at name ~args:[ left.exp; right.exp ]; kind }

(* The unsigned shift converts its amount to a plain integer instead of
   coercing it, and amounts at or above the operand width produce zero. *)
let shift_right ~ctx ~at ~branch left right =
  let width =
    match Value.bits ~types:(Ctx.types ctx) ~at left.kind with
    | Some width -> width
    | None -> Error.reject ~at "Right shifts require an unsigned left operand"
  in
  if
    (not (Value.is_integer ~types:(Ctx.types ctx) ~at right.kind))
    && Value.bits ~types:(Ctx.types ctx) ~at right.kind = None
  then Error.reject ~at "Right shifts require a numeric amount";
  (* A plain integer amount is checked nonnegative and rebound to a
     statically nat-typed value, since the helper's nat parameter does not
     accept an int-typed argument even under a separate premise. An amount
     that already carries an unsigned source width unfolds to nat directly. *)
  let branch, right = natural_of_integer ~ctx ~at ~branch right in
  Branch.bind ~ctx ~at branch
    ~term:
      {
        exp =
          call ~at "translated_shift_right"
            ~args:[ left.exp; right.exp; nat ~at width ];
        kind = left.kind;
      }

let binary ~ctx ~at ~op ~branch left right =
  if
    Value.set_element ~types:(Ctx.types ctx) ~at left.kind <> None
    || Value.set_element ~types:(Ctx.types ctx) ~at right.kind <> None
  then Error.reject ~at "Set arithmetic is unsupported";
  if
    not
      (List.for_all
         (fun value ->
           Value.is_integer ~types:(Ctx.types ctx) ~at value.kind
           || Value.bits ~types:(Ctx.types ctx) ~at value.kind <> None)
         [ left; right ])
  then
    Error.reject ~at
      "Arithmetic requires numeric values or reviewed list concatenation";
  if op = Syntax.RShift then shift_right ~ctx ~at ~branch left right
  else (
    (match
       ( Value.bits ~types:(Ctx.types ctx) ~at left.kind,
         Value.bits ~types:(Ctx.types ctx) ~at right.kind )
     with
    | Some l, Some r when l <> r ->
        Error.reject ~at "Unsigned operands of different widths reject coercion"
    | _ -> ());
    let width, kind =
      match Value.bits ~types:(Ctx.types ctx) ~at left.kind with
      | Some n -> (Some n, left.kind)
      | None -> (
          match Value.bits ~types:(Ctx.types ctx) ~at right.kind with
          | Some width -> (Some width, right.kind)
          | None -> (None, Value.integer))
    in
    (* Python first coerces a plain integer to the unsigned operand's class,
       raising if the value is out of range. *)
    let branch =
      match width with
      | None -> branch
      | Some width ->
          List.fold_left
            (fun branch value ->
              if not (Value.is_integer ~types:(Ctx.types ctx) ~at value.kind)
              then branch
              else
                guard_unsigned_bounds ~at ~bits:(Bigint.of_int width) ~branch
                  value)
            branch [ left; right ]
    in
    let bound =
      Option.map (fun width -> number ~at (unsigned_maximum width)) width
    in
    let branch, op =
      match op with
      | Syntax.Add ->
          let branch =
            match bound with
            | None -> branch
            | Some bound ->
                Branch.guard ~at
                  ~exp:(comparison ~at ~op:`LeOp right.exp bound)
                  branch
                |> Branch.guard ~at
                     ~exp:
                       (comparison ~at ~op:`LeOp left.exp
                          (arithmetic ~at ~op:`SubOp bound right.exp))
          in
          (branch, `AddOp)
      | Syntax.Sub ->
          ( (if width = None then branch
             else
               Branch.guard ~at
                 ~exp:(comparison ~at ~op:`LeOp right.exp left.exp)
                 branch),
            `SubOp )
      | Syntax.Mult ->
          ( (match bound with
            | None -> branch
            | Some bound ->
                Branch.guard ~at
                  ~exp:
                    (comparison ~at ~op:`LeOp
                       (arithmetic ~at ~op:`MulOp left.exp right.exp)
                       bound)
                  branch),
            `MulOp )
      | Syntax.Mod | Syntax.FloorDiv ->
          (* Python floors toward negative infinity while the target
               truncates toward zero. They agree only when neither operand is
               negative, which unsigned operands give for free. *)
          if
            width = None
            && not
                 (is_nonnegative ~ctx ~at ~branch left
                 && is_nonnegative ~ctx ~at ~branch right)
          then
            Error.reject ~at
              "Integer division and modulo require operands that cannot be \
               negative, since Python floors and the target truncates";
          ( Branch.guard ~at
              ~exp:(comparison ~at ~op:`NeOp right.exp (nat ~at 0))
              branch,
            if op = Syntax.Mod then `ModOp else `DivOp )
      | Syntax.Pow ->
          Error.reject ~at
            "Exponentiation requires a statically known nonnegative exponent"
      | _ -> Error.reject ~at "Unsupported arithmetic"
    in
    let result = { exp = arithmetic ~at ~op left.exp right.exp; kind } in
    (* The unsigned class coerces a plain integer operand, so the Python
         result is unsigned even though the target expression carries the
         operand's signed type. Rebinding gives the result its unsigned type
         for later use. *)
    if
      width <> None
      && (Value.is_integer ~types:(Ctx.types ctx) ~at left.kind
         || Value.is_integer ~types:(Ctx.types ctx) ~at right.kind)
    then Branch.bind ~ctx ~at branch ~term:result
    else (branch, result))

let negate ~ctx ~at ~branch value =
  if not (Value.is_integer ~types:(Ctx.types ctx) ~at value.kind) then
    Error.reject ~at "Unary minus requires a plain Python integer";
  ( branch,
    {
      exp = arithmetic ~at ~op:`SubOp (nat ~at 0) value.exp;
      kind = Value.integer;
    } )

let power ~ctx ~at ~branch base ~exponent =
  if
    (not (Value.is_integer ~types:(Ctx.types ctx) ~at base.kind))
    || not (Value.is_integer ~types:(Ctx.types ctx) ~at exponent.kind)
  then Error.reject ~at "Exponentiation requires plain integer operands";
  if not (is_nonnegative ~ctx ~at ~branch exponent) then
    Error.reject ~at
      "Exponentiation requires a known nonnegative exponent, since a negative \
       one returns a Python float";
  ( branch,
    {
      exp = arithmetic ~at ~op:`PowOp base.exp exponent.exp;
      kind = Value.integer;
    } )

let extremum ~ctx ~at ~operation ~branch values =
  match values with
  | [ left; right ]
    when (Value.bits ~types:(Ctx.types ctx) ~at left.kind = Some 64
         || Value.is_integer ~types:(Ctx.types ctx) ~at left.kind)
         && (Value.bits ~types:(Ctx.types ctx) ~at right.kind = Some 64
            || Value.is_integer ~types:(Ctx.types ctx) ~at right.kind) ->
      [
        ( Branch.guard ~at
            ~exp:
              (comparison ~at
                 ~op:(match operation with Min -> `LeOp | Max -> `GeOp)
                 left.exp right.exp)
            branch,
          left );
        ( Branch.guard ~at
            ~exp:
              (comparison ~at
                 ~op:(match operation with Min -> `GtOp | Max -> `LtOp)
                 left.exp right.exp)
            branch,
          right );
      ]
  | _ -> Error.reject ~at "Min and max require integer or uint64 values"

let cast_power_of_two ~ctx ~at ~name ~branch value =
  if not (Value.is_integer ~types:(Ctx.types ctx) ~at value.kind) then
    Error.reject ~at "Power-of-two uint8 casts require an integer exponent";
  let branch =
    Branch.guard ~at
      ~exp:(comparison ~at ~op:`LeOp (nat ~at 0) value.exp)
      branch
    |> Branch.guard ~at ~exp:(comparison ~at ~op:`LtOp value.exp (nat ~at 8))
  in
  Branch.bind ~ctx ~at branch
    ~term:
      {
        exp = arithmetic ~at ~op:`PowOp (nat ~at 2) value.exp;
        kind = Named name;
      }

let cast ~ctx ~at ~name ~branch value =
  let kind = Named name in
  (* The unsigned constructor rejects negative values and
     values wider than the target type. A plain integer and
     a wider unsigned source can both fail. A narrower
     unsigned source always fits. *)
  let converted =
    match
      ( Value.bits ~types:(Ctx.types ctx) ~at value.kind,
        Value.bits ~types:(Ctx.types ctx) ~at kind )
    with
    | _, None -> false
    | None, Some _ -> Value.is_integer ~types:(Ctx.types ctx) ~at value.kind
    | Some source, Some target -> source > target
  in
  let branch =
    if converted then
      guard_unsigned_bounds ~at
        ~bits:
          (Bigint.of_int
             (Option.get (Value.bits ~types:(Ctx.types ctx) ~at kind)))
        ~branch value
    else if
      Value.bits ~types:(Ctx.types ctx) ~at value.kind = None
      && Value.bits ~types:(Ctx.types ctx) ~at kind <> None
    then Error.reject ~at "Unsigned integer casts require an integer value"
    else branch
  in
  if converted then Branch.bind ~ctx ~at branch ~term:{ value with kind }
  else (branch, { value with kind })
