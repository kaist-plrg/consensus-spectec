(** Controls whether completing a statement sequence returns from the function
    or continues a carried or returning loop. [returned] lists the carried
    locals returned by the function after the loop. *)
type body_kind =
  | FunctionBody
  | LoopBody of { at : Common.Location.t; returned : string list }
  | ReturningLoopBody

val translate :
  ctx:Ctx.t ->
  body_kind:body_kind ->
  Syntax.statement list ->
  branch:Branch.t ->
  (Branch.t * Loop.completion) list
