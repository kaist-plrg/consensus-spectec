open Lang.El

val bytes_of_value :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val sequence_of_bytes :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val bytes32_kind :
  ctx:Ctx.t -> at:Common.Location.t -> diagnostic:string -> Value.kind

val bytes32_of_sequence :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val length :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * exp

val concat :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  right:Value.t ->
  Branch.t * Value.t

val bytes_of_hex : at:Common.Location.t -> string -> Value.t

val integer_of_bytes :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val index :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  index:Value.t ->
  Branch.t * Value.t

val bytes32_of_value :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val nominal_bytes_of_value :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  name:string ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val hash :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t
