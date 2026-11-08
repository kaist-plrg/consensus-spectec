open Lang.El

type extremum = Min | Max

val string_of_extremum : extremum -> string

val natural_of_integer :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val unsigned_maximum : int -> Bigint.t
val unsigned_bounds : at:Common.Location.t -> bits:Bigint.t -> exp -> exp list

val guard_unsigned_bounds :
  at:Common.Location.t ->
  bits:Bigint.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t

val is_nonnegative :
  ctx:Ctx.t -> at:Common.Location.t -> branch:Branch.t -> Value.t -> bool

val bitwise :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  op:Syntax.binop ->
  branch:Branch.t ->
  Value.t ->
  Value.t ->
  Branch.t * Value.t

val binary :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  op:Syntax.binop ->
  branch:Branch.t ->
  Value.t ->
  Value.t ->
  Branch.t * Value.t

val negate :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val power :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  exponent:Value.t ->
  Branch.t * Value.t

val extremum :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  operation:extremum ->
  branch:Branch.t ->
  Value.t list ->
  (Branch.t * Value.t) list

val cast_power_of_two :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  name:string ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val cast :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  name:string ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t
