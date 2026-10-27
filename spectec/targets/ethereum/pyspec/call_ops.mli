open Common.Source
open Lang.El

val type_parameters : ctx:Ctx.t -> at:region -> Source.signature -> string list

val type_arguments :
  ctx:Ctx.t ->
  at:region ->
  Source.signature ->
  supplied:Operand.t option list ->
  branch:Branch.t ->
  Branch.t * targ list

val parameter_values :
  Operand.t list -> order:int option list -> Operand.t option list

val invoke :
  ctx:Ctx.t ->
  at:region ->
  Source.signature ->
  list_result:bool ->
  supplied:Operand.t option list ->
  branch:Branch.t ->
  Branch.t * Operand.t

val invoke_primitive :
  ctx:Ctx.t ->
  at:region ->
  Python_builtins.primitive_contract ->
  branch:Branch.t ->
  values:Operand.t list ->
  Branch.t * Operand.t

val notify_new_payload :
  ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> Branch.t * Operand.t

val aggregate_pubkeys :
  ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> Branch.t * Operand.t
