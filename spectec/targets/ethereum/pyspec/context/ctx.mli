(** Context shared by every path through one function. The source, list results
    and declarations stay fixed. One counter keeps fresh names distinct across
    clauses. All functions in a translation share the registry, which emits
    shared helpers once. [Branch.t] holds each path's data. *)

module Registry : sig
  (** A registry holds the definitions of one translation in emission order. *)

  type t

  val make : unit -> t
  val emit : t -> Lang.El.spec -> unit
  val definitions : t -> Lang.El.spec
end

type t

(** Fresh names avoid [reserved]. *)
val make :
  Typed.source ->
  list_results:string list ->
  registry:Registry.t ->
  reserved:string list ->
  declarations:(string * Lang.El.def) list ->
  t

val source : t -> Typed.source
val list_results : t -> string list
val declarations : t -> (string * Lang.El.def) list
val types : t -> Value.metadata

(** Allocates a variable pattern of the kind's target type, named so it differs
    from every source argument and earlier allocation in the function. *)
val fresh :
  ?hint:string -> t -> at:Common.Location.t -> kind:Value.kind -> Value.t

val fresh_helper_name : t -> operation:string -> string

(** Registers a shared helper by name. If the registry already contains a
    function declaration of that name, skips the builder and keeps the existing
    definitions. *)
val share_helper :
  t -> name:string -> definitions:(unit -> Lang.El.spec) -> unit

(** Registers definitions owned by the function being translated. *)
val emit_helper : t -> definitions:Lang.El.spec -> unit
