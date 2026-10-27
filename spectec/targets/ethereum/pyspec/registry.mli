(** Definitions grouped by ownership during one translation. The registry
    preserves emission order and indexes function, builtin and type
    declarations. *)

(** [Source name] owns a source function's entry declarations and clauses.
    [Helper name] owns that source function's auxiliary definitions. Only source
    entries replace context symbols. *)
type ownership = Shared | Source of string | Helper of string

type t
type group

val make : unit -> t
val declared_function : ?builtin:bool -> name:string -> t -> bool
val declared_type : name:string -> t -> bool
val emit : registry:t -> ownership:ownership -> Lang.El.spec -> unit

(** Registration tests ordinary function declarations before generation. Builtin
    declarations have a distinct lookup policy. *)
val register :
  t ->
  ownership:ownership ->
  name:string ->
  generate:(unit -> Lang.El.spec) ->
  unit

val groups : t -> group list
val ownership : group -> ownership
val definitions : group -> Lang.El.spec
val contents : group list -> Lang.El.spec
