type t = private {
  source : Source.t;
  list_results : string list;
  mutable next : int;
  mutable reserved : string list;
  registry : Registry.t;
  declarations : (string * Lang.El.def) list;
}

(** Fresh names avoid [reserved]. *)
val make :
  Source.t ->
  list_results:string list ->
  reserved:string list ->
  declarations:(string * Lang.El.def) list ->
  t

(** A context that translates a generic helper written for [source]. It
    allocates fresh names from scratch and shares the registry of [ctx]. *)
val for_helper : t -> source:Source.t -> t

val types : t -> Kind.metadata

(** Allocates a variable pattern of the kind's target type, named so it differs
    from every source argument and earlier allocation in the function. *)
val fresh :
  ?hint:string -> t -> at:Common.Source.region -> kind:Kind.t -> Operand.t

val fresh_helper_name : t -> operation:string -> string

(** Registers a shared helper under its declaration name, building its
    definitions only when no ordinary declaration of that name exists. *)
val share_helper :
  t -> name:string -> definitions:(unit -> Lang.El.spec) -> unit

(** Registers a shared helper written as SpecTec text. *)
val share_helper_text :
  t ->
  at:Common.Source.region ->
  name:string ->
  operation:string ->
  text:string ->
  unit

(** Registers definitions owned by the function being translated. *)
val emit_helper : t -> definitions:Lang.El.spec -> unit
