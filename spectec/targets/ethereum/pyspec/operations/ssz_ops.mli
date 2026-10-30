open Common.Source
open Lang.El

type record

val validity_guards :
  ctx:Ctx.t -> at:region -> Operand.t -> branch:Branch.t -> Branch.t

val type_argument : ctx:Ctx.t -> at:region -> Kind.t -> targ

val prepare_record :
  ctx:Ctx.t ->
  at:region ->
  string ->
  positional:bool ->
  keywords:string list ->
  record

val record_field :
  ctx:Ctx.t ->
  at:region ->
  plan:record ->
  name:string ->
  branch:Branch.t ->
  Operand.t ->
  Branch.t * Operand.t

val record :
  ctx:Ctx.t ->
  at:region ->
  plan:record ->
  (string * Operand.t) list ->
  branch:Branch.t ->
  Branch.t * Operand.t

val serialize :
  ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> Branch.t * Operand.t

val hash_tree_root :
  ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> Branch.t * Operand.t
