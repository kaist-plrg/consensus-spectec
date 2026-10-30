(** Recursive helpers built from loop bodies.

    [build] generates the helper declaration, its recursive clauses, the
    transport of captured arguments, and result installation. For an indexed
    loop it also generates the end check and the index increment. An indexed
    loop supplies its sequence, index, access mode, initial branch and retained
    parent binding. A condition-driven loop supplies its exit branches. Result
    selection distinguishes carried locals from returns of the enclosing
    function.

    Checks that need a body's results run after the body is translated.
    Statement translation finds promoted accumulators in a translated body, then
    asks the planner to check their uses before building clauses. Rejections
    therefore follow the point where each needed fact becomes available. *)

open Common.Source

(** How a statement sequence finishes on one branch, its completion. *)
type completion = Returned of Operand.t | Broken | Fallthrough

type body = {
  promotions : (string * Kind.t) list;
  iterations : (Branch.t * [ `Continue | `Break ]) list;
}

type t =
  | Indexed of {
      sequence : Operand.t;
      index : Operand.t;
      access : Loop_plan.access;
      parent : string;
      initial : Branch.t;
      body : body;
    }
  | Conditional of { finished : Branch.t list; body : body }
  | Returning of {
      kind : Kind.t;
      continuing : Branch.t list;
      returned : (Branch.t * Operand.t) list;
    }

(** Settles the promotions of a carried loop's iterations and checks the source
    uses that depend on them. *)
val carried_body :
  ctx:Ctx.t ->
  at:region ->
  carried:(string * Operand.t) list ->
  tests:Syntax.expr list ->
  body:Syntax.statement list ->
  rest:Syntax.statement list ->
  (Branch.t * completion) list ->
  body

(** Emits the recursive helper for a loop and binds its result on the entering
    branch. *)
val build :
  ctx:Ctx.t ->
  at:region ->
  name:string ->
  plan:Operand.t Loop_plan.t ->
  t ->
  branch:Branch.t ->
  Branch.t * completion
