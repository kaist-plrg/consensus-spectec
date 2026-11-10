(** Plans loops and builds recursive helpers from translated values and
    callbacks. [Loop] does not depend on [Expr], so both [Call] and [Expr] can
    use its builders. *)

(** Loop plans depend on source syntax and storage facts. Planning allocates no
    names and emits no premises or definitions. *)

type plan = private {
  carried : (string * Value.t) list;
  captures : (string * Value.t) list;
}

type access = Independent | Snapshot of string | Live of string
type iteration = private { access : access; iterated : string list }

val select_carried :
  ?returning:bool ->
  types:Value.metadata ->
  at:Common.Location.t ->
  Syntax.statement list ->
  storage:Store.t ->
  (string * Value.t) list

val capture :
  at:Common.Location.t ->
  carried:(string * Value.t) list ->
  body:Syntax.statement list ->
  Store.t ->
  plan

val iteration :
  types:Value.metadata ->
  at:Common.Location.t ->
  target:Syntax.target ->
  enumerated:bool ->
  iterable:Syntax.expr ->
  element:Value.kind ->
  storage:Store.t ->
  sequence:Value.t ->
  state_backed:(unit -> bool) ->
  set_iterated:bool ->
  Syntax.statement list ->
  iteration

val check_set_loop :
  types:Value.metadata ->
  at:Common.Location.t ->
  target:string ->
  carried:(string * Value.t) list ->
  references:(string * Store.reference) list ->
  state_reads:(string * string list) list ->
  Syntax.statement list ->
  unit

val check_accumulation :
  at:Common.Location.t ->
  promotions:(string * Value.kind) list ->
  guards:Syntax.expr list ->
  Syntax.statement list ->
  unit

val check_promoted_use :
  promotions:(string * Value.kind) list -> Syntax.statement list -> unit

val returns_inside : Syntax.statement list -> bool

(** How a statement sequence finishes on one branch, its completion. *)
type completion = Returned of Value.t | Broken | Fallthrough

type body = {
  promotions : (string * Value.kind) list;
  iterations : (Branch.t * [ `Continue | `Break ]) list;
}

type t =
  | Indexed of {
      sequence : Value.t;
      index : Value.t;
      access : access;
      parent : string;
      initial : Branch.t;
      body : body;
    }
  | Conditional of { finished : Branch.t list; body : body }
  | Returning of {
      kind : Value.kind;
      continuing : Branch.t list;
      returned : (Branch.t * Value.t) list;
    }

(** Settles the promotions of a carried loop's iterations and checks the source
    uses that depend on them. *)
val carried_body :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  carried:(string * Value.t) list ->
  tests:Syntax.expr list ->
  body:Syntax.statement list ->
  rest:Syntax.statement list ->
  (Branch.t * completion) list ->
  body

(** Emits the recursive helper for a loop and binds its result on the entering
    branch. *)
val build :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  name:string ->
  plan:plan ->
  t ->
  branch:Branch.t ->
  Branch.t * completion

(** Generates a helper that applies [element] to each item. The callback returns
    branches that emit a value and branches that skip the item. *)
val map :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  captures:(string * Value.t) list ->
  element:
    (Branch.t ->
    Value.t ->
    Value.t ->
    (Branch.t * Value.t) list * Branch.t list) ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t
