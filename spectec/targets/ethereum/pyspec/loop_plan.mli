(** Loop plans built from source syntax and storage facts.

    [select_carried] selects a loop's carried values, the locals that the loop
    body assigns and later code reads, from source assignments and storage
    references. [capture] fixes the ordered captures after the iterable is
    evaluated or before a while body is entered. [iteration] selects one of
    three access modes: independent values, a snapshot field or a live parent
    field. It also records the owned identities that iteration protects. The
    planner has no dependency on EL, premises, fresh names or definition
    emission. *)

type 'value t = private {
  carried : (string * 'value) list;
  captures : (string * 'value) list;
}

type access = Independent | Snapshot of string | Live of string
type iteration = private { access : access; iterated : string list }

val select_carried :
  ?returning:bool ->
  types:Kind.metadata ->
  kind:('value -> Kind.t) ->
  at:Common.Source.region ->
  Syntax.statement list ->
  storage:'value Store.t ->
  (string * 'value) list

val capture : carried:(string * 'value) list -> 'value Store.t -> 'value t

val iteration :
  types:Kind.metadata ->
  at:Common.Source.region ->
  target:Syntax.target ->
  enumerated:bool ->
  iterable:Syntax.expr ->
  element:Kind.t ->
  storage:'value Store.t ->
  same_value:('value -> bool) ->
  state_backed:(unit -> bool) ->
  set_iterated:bool ->
  Syntax.statement list ->
  iteration

val check_set_loop :
  types:Kind.metadata ->
  kind:('value -> Kind.t) ->
  at:Common.Source.region ->
  target:string ->
  carried:(string * 'value) list ->
  references:(string * 'value Store.reference) list ->
  state_reads:(string * string list) list ->
  Syntax.statement list ->
  unit

val check_accumulation :
  at:Common.Source.region ->
  promotions:(string * Kind.t) list ->
  guards:Syntax.expr list ->
  Syntax.statement list ->
  unit

val check_promoted_use :
  promotions:(string * Kind.t) list -> Syntax.statement list -> unit

val returns_inside : Syntax.statement list -> bool
