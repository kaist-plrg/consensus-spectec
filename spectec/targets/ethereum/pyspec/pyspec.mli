(** A decoded module document from [python -m export]. *)
type document

(** A document or source construct outside the supported subset, with its source
    location and a message. *)
exception Rejected of Common.Location.t * string

(** Reads and decodes a module document. *)
val load : string -> document

(** Translates functions with bodies into EL definitions. Declarations precede
    bodies, with emission order preserved within each group. The result uses but
    omits the definitions in [prelude.spectec]. *)
val translate : document -> Lang.El.spec
