open Common.Source

val binary :
  ctx:Ctx.t ->
  at:region ->
  op:Syntax.binop ->
  branch:Branch.t ->
  Operand.t ->
  Operand.t ->
  Branch.t * Operand.t

(** Operand conversions run once before either truth value is selected. The
    converted right operand continues a chained comparison. *)
val comparison :
  ctx:Ctx.t ->
  at:region ->
  op:Syntax.cmpop ->
  branch:Branch.t ->
  Operand.t ->
  Operand.t ->
  Branch.t * (bool -> Lang.El.exp) * Operand.t
