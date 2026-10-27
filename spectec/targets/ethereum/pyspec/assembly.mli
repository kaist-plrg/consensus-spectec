type t

(** Bundle sharing deduplicates shared definitions by rendered content. Source
    entries and their helpers retain their multiplicity. *)
val assemble : Registry.group list -> t

val definitions : t -> Lang.El.spec
val replace : context:Lang.El.spec -> t -> Lang.El.spec

val compile :
  context:Lang.El.spec -> t -> (Lang.Il.spec * Lang.Sl.spec) Spectec.result
