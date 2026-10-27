open Common.Source

val binary :
  ctx:Ctx.t ->
  at:region ->
  op:Syntax.binop ->
  branch:Branch.t ->
  Operand.t ->
  Operand.t ->
  Branch.t * Operand.t
