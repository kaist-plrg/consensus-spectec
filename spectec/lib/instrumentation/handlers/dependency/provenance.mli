(** Clear the provenance table keyed by value identifier. Callers must call
    [clear] before each [Interp.with_target_state] call. *)
val clear : unit -> unit

(** Return an empty list when the value has no recorded provenance. *)
val origins : Lang.Il.Value.t -> Instrumentation_api.Origin.t list

(** Add origins to the value's recorded provenance, removing duplicates. *)
val add_readset : Lang.Il.Value.t -> Instrumentation_api.Origin.t list -> unit

val handle_value : Instrumentation_api.Value_event.t -> unit
