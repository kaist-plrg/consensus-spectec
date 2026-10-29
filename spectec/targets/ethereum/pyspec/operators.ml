open Kind
open Operand

let binary ~ctx ~at ~op ~branch left right =
  (* An accumulated loop result is a plain integer only when the loop body
     never ran, so it may only meet an operand that coerces it exactly as the
     unsigned class the body produced would. This runs before the operator
     dispatch, so byte, bitwise and shift operands are covered too. *)
  List.iter
    (fun (value, other) ->
      match List.assoc_opt (string_of_exp value.exp) branch.Branch.promoted with
      | Some kind
        when Kind.bits ~types:(Ctx.types ctx) ~at other.kind
             <> Kind.bits ~types:(Ctx.types ctx) ~at kind ->
          Error.reject ~at
            "An accumulated loop result needs an operand of the unsigned width \
             its loop produced"
      | _ -> ())
    [ (left, right); (right, left) ];
  if
    op = Syntax.Add
    && Kind.byte_width ~types:(Ctx.types ctx) ~at left.kind <> None
    && Kind.byte_width ~types:(Ctx.types ctx) ~at right.kind <> None
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

let target_cmpop = function
  | Syntax.Eq -> `EqOp
  | Syntax.NotEq -> `NeOp
  | Syntax.Lt -> `LtOp
  | Syntax.LtE -> `LeOp
  | Syntax.Gt -> `GtOp
  | Syntax.GtE -> `GeOp
  | _ -> assert false

let comparison ~ctx ~at ~op ~branch left right =
  let branch, left, right =
    match
      ( Kind.is_byte_valued ~types:(Ctx.types ctx) ~at left.kind,
        Kind.is_byte_valued ~types:(Ctx.types ctx) ~at right.kind )
    with
    | false, false -> (branch, left, right)
    | true, true when List.mem op Syntax.[ Eq; NotEq ] ->
        let branch, left = Byte_ops.to_bytes ~ctx ~at ~branch left in
        let branch, right = Byte_ops.to_bytes ~ctx ~at ~branch right in
        (branch, left, right)
    | _ ->
        Error.reject ~at "Byte comparisons require equality between byte values"
  in
  if
    Kind.set_element ~types:(Ctx.types ctx) ~at left.kind <> None
    || Kind.set_element ~types:(Ctx.types ctx) ~at right.kind <> None
  then Error.reject ~at "Set comparisons require a membership contract";
  let op = target_cmpop op in
  ( branch,
    (fun holds ->
      Operand.comparison ~at
        ~op:(if holds then op else complement op)
        left.exp right.exp),
    right )
