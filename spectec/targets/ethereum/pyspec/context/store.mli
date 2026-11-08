(** Immutable local bindings and references for translating one function.
    [Store] depends only on [Value]. Callers validate source operations before
    applying store transitions. A state write invalidates overlapping views,
    except for the writing reference and iterator views. State locations overlap
    when they share their first field. *)

type step = Field of string | Element of Value.t
type location = step list

type reference = private {
  location : location option;
  iterator_parent : string option;
  identity : string;
  valid : bool;
}

type t

val make : (string * Value.t) list -> t
val bindings : t -> (string * Value.t) list
val references : t -> (string * reference) list

(** Representation updates retain reference identity. Source assignments use
    [bind_local] to establish or detach that identity. *)
val replace_value : name:string -> value:Value.t -> t -> t

val bind_local :
  name:string -> value:Value.t -> reference:reference option -> t -> t

val update_aliases : identity:string -> value:Value.t -> t -> t
val owned : string -> reference
val state_view : identity:string -> location -> reference

val iterator_view :
  string -> field:string -> index:Value.t -> parent:string -> reference

val read : key:string -> t -> Value.t option
val cache_read : key:string -> value:Value.t -> t -> t
val origin : key:string -> t -> location option
val remember_origin : key:string -> location:location -> t -> t

val write_state :
  ?identity:string ->
  state_name:string ->
  location:location ->
  value:Value.t ->
  t ->
  t

val loop_results : state_name:string -> values:(string * Value.t) list -> t -> t

(** While-loop entry keeps captured values and owned references and resets
    cached reads and origins. *)
val enter_while : t -> t

val enter_for : carried:string list -> iterated:string list -> t -> t
