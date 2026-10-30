open Common.Source

(** What finishing a statement sequence means: returning from the function,
    continuing a carried loop whose result is the named local, or continuing a
    loop that returns. *)
type scope = FunctionBody | LoopBody of region * string | ReturningLoopBody

val translate :
  ctx:Ctx.t ->
  scope:scope ->
  Syntax.statement list ->
  branch:Branch.t ->
  (Branch.t * Loop.completion) list
