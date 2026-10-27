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
