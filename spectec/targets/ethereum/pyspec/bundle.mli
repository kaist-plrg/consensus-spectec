(** A nonempty set of source documents with unique functions that agree on
    shared call signatures and generic helpers. *)
type t

(** Validates the documents and infers which functions return Python lists.
    Raises [Error.Rejected] on disagreement. *)
val make : Source.t list -> t

val documents : t -> Source.t list

(** Functions that return a Python list rather than an SSZ list. *)
val list_results : t -> string list
