(** Local bindings and their references during the translation of one function.

    A store is immutable and parameterized by the translator's value type. It
    has no dependency on source syntax, EL or JSON. Owned values, saved state
    views and iterator views use separate constructors.

    A source assignment uses [bind_local] to update a local's value and
    reference together. [replace_value] gives a local a new representation and
    keeps its reference identity. Alias updates replace the values of all locals
    that share an identity. Saved views with independent identities keep their
    values. Replacing the state clears read caches and origins, invalidates
    overlapping state views, and keeps the writing identity and iterator views.
    Installing loop results applies the same invalidation when it replaces the
    state. Two state locations overlap when they share their first field.

    Entering a body keeps captured values and clears cached facts. Helper bodies
    discard references. While bodies keep owned references. For bodies keep
    owned references and carried state views, and disable writes through
    iterated owned identities. Callers check the source and report rejections
    before applying these transitions. *)

type 'value step = Field of string | Element of 'value
type 'value location = 'value step list

type 'value reference = private {
  location : 'value location option;
  iterator_parent : string option;
  identity : string;
  valid : bool;
}

type 'value t

val make : (string * 'value) list -> 'value t
val bindings : 'value t -> (string * 'value) list
val references : 'value t -> (string * 'value reference) list

(** Representation updates retain reference identity. Source assignments use
    [bind_local] to establish or detach that identity. *)
val replace_value : name:string -> value:'value -> 'value t -> 'value t

val bind_local :
  name:string ->
  value:'value ->
  reference:'value reference option ->
  'value t ->
  'value t

val update_aliases : identity:string -> value:'value -> 'value t -> 'value t
val owned : string -> 'value reference
val state_view : identity:string -> 'value location -> 'value reference

val iterator_view :
  string -> field:string -> index:'value -> parent:string -> 'value reference

val read : key:string -> 'value t -> 'value option
val cache_read : key:string -> value:'value -> 'value t -> 'value t
val origin : key:string -> 'value t -> 'value location option

val remember_origin :
  key:string -> location:'value location -> 'value t -> 'value t

val write_state :
  ?identity:string ->
  location:'value location ->
  value:'value ->
  'value t ->
  'value t

val loop_results : values:(string * 'value) list -> 'value t -> 'value t

(** Body entry keeps captured values and resets reads and origins. Helpers
    discard references, while loops retain owned references, and for loops also
    retain carried state views and disable writes to iterated owned lists. *)
val enter_helper : 'value t -> 'value t

val enter_while : 'value t -> 'value t

val enter_for :
  carried:string list -> iterated:string list -> 'value t -> 'value t
