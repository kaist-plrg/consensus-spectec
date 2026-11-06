open Common.Source
open Lang.El

val to_natural :
  ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> Branch.t * Operand.t

val unsigned_maximum : int -> Bigint.t
val uint64_maximum : Bigint.t

val guard_unsigned_bounds :
  at:region -> upper:exp -> branch:Branch.t -> Operand.t -> Branch.t

val is_nonnegative :
  ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> bool

val bitwise :
  ctx:Ctx.t ->
  at:region ->
  op:Syntax.binop ->
  branch:Branch.t ->
  Operand.t ->
  Operand.t ->
  Branch.t * Operand.t

val binary :
  ctx:Ctx.t ->
  at:region ->
  op:Syntax.binop ->
  branch:Branch.t ->
  Operand.t ->
  Operand.t ->
  Branch.t * Operand.t

val negate :
  ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> Branch.t * Operand.t

val power :
  ctx:Ctx.t ->
  at:region ->
  branch:Branch.t ->
  Operand.t ->
  exponent:Operand.t ->
  Branch.t * Operand.t

val extremum :
  ctx:Ctx.t ->
  at:region ->
  name:string ->
  branch:Branch.t ->
  Operand.t list ->
  (Branch.t * Operand.t) list

val cast_power_of_two :
  ctx:Ctx.t ->
  at:region ->
  name:string ->
  branch:Branch.t ->
  Operand.t ->
  Branch.t * Operand.t

val cast :
  ctx:Ctx.t ->
  at:region ->
  name:string ->
  branch:Branch.t ->
  Operand.t ->
  Branch.t * Operand.t
