(** Translation rejects source outside the supported subset and documents that
    break a reviewed contract. A rejection about a whole document or bundle
    carries [no_region]. *)
exception Rejected of Common.Source.region * string

val reject : at:Common.Source.region -> string -> 'a

(** Finds the entry for a name or rejects the name as unresolved. *)
val find_or_reject :
  at:Common.Source.region -> name:string -> (string * 'a) list -> 'a

val to_string : at:Common.Source.region -> string -> string
