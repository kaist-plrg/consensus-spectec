open Common.Source
open Lang.El

val to_bytes :
  ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> Branch.t * Operand.t

val elements :
  ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> Branch.t * Operand.t

val bytes32_kind : ctx:Ctx.t -> at:region -> missing:string -> Kind.t

val bytes32_of_sequence :
  ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> Branch.t * Operand.t

val length :
  ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> Branch.t * exp

val concat :
  ctx:Ctx.t ->
  at:region ->
  branch:Branch.t ->
  Operand.t ->
  right:Operand.t ->
  Branch.t * Operand.t

val literal : ctx:Ctx.t -> at:region -> string -> Operand.t

val little_endian :
  ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> Branch.t * Operand.t

val index :
  ctx:Ctx.t ->
  at:region ->
  branch:Branch.t ->
  Operand.t ->
  index:Operand.t ->
  Branch.t * Operand.t

val bytes32 :
  ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> Branch.t * Operand.t

val nominal_bytes :
  ctx:Ctx.t ->
  at:region ->
  name:string ->
  branch:Branch.t ->
  Operand.t ->
  Branch.t * Operand.t

val hash :
  ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> Branch.t * Operand.t
