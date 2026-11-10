(** Rejects unsupported source and module documents that violate the accepted
    contracts. Rejections for a whole document carry [Common.Location.Unknown].
*)
exception Rejected of Common.Location.t * string

val reject : at:Common.Location.t -> string -> 'a

(** Finds the entry for a name or rejects the name as unresolved. *)
val find_or_reject :
  at:Common.Location.t -> name:string -> (string * 'a) list -> 'a

val check_distinct :
  at:Common.Location.t -> message:string -> string list -> unit
