(** An evaluated EL expression and its Python value kind. The kind retains
    source distinctions that the target type may erase. *)

open Lang.El

type kind =
  | Named of string
  | Optional of kind
  | ByteString of Bigint.t
  | ByteInteger (* A plain Python int in [0, 256) read from bytes. *)
  | G1Point
  | Sequence of kind * Bigint.t option
  | PythonList of kind
  | Set of kind
  | Empty
  | FrozenSequence of kind * Bigint.t
  | Product of kind list

type metadata = (string * Typed.python_type) list
type t = { exp : exp; kind : kind }

val boolean : kind
val integer : kind
val bits : types:metadata -> at:Common.Location.t -> kind -> int option
val is_integer : types:metadata -> at:Common.Location.t -> kind -> bool
val is_boolean : types:metadata -> at:Common.Location.t -> kind -> bool
val is_copyable_scalar : types:metadata -> at:Common.Location.t -> kind -> bool
val set_element : types:metadata -> at:Common.Location.t -> kind -> kind option

val check_set_value :
  types:metadata ->
  at:Common.Location.t ->
  kind ->
  expected:kind option ->
  diagnostic:string ->
  unit

(** Plain integers and byte reads share one number class. Unsigned types share a
    class exactly when their widths agree. *)
val is_same_number_class :
  types:metadata -> at:Common.Location.t -> kind -> kind -> bool

(** Checks number classes at call and return boundaries, where Python does not
    convert values to their annotations. Non-numeric kinds need separate checks.
*)
val check_number_class :
  types:metadata ->
  at:Common.Location.t ->
  kind ->
  declared:kind ->
  diagnostic:string ->
  unit

(** [length] is the fixed length of a vector or frozen sequence. [bitvector]
    marks an SSZ bitvector, whose elements are bits. *)
type sequence = { element : kind; length : Bigint.t option; bitvector : bool }

val sequence : types:metadata -> at:Common.Location.t -> kind -> sequence

val bounded_ssz_list :
  types:metadata -> at:Common.Location.t -> string -> (kind * Bigint.t) option

val product : types:metadata -> at:Common.Location.t -> kind -> kind list
val is_readonly_product : types:metadata -> at:Common.Location.t -> kind -> bool

val fields :
  types:metadata -> at:Common.Location.t -> kind -> (string * string) list

val byte_width :
  types:metadata -> at:Common.Location.t -> kind -> Bigint.t option

val is_byte_valued : types:metadata -> at:Common.Location.t -> kind -> bool

val is_named_container_or_set :
  types:metadata -> at:Common.Location.t -> kind -> bool

val is_flat_record : types:metadata -> at:Common.Location.t -> kind -> bool
val id : at:Common.Location.t -> string -> id
val var : at:Common.Location.t -> string -> exp
val number : at:Common.Location.t -> Bigint.t -> exp
val nat : at:Common.Location.t -> int -> exp
val bool : at:Common.Location.t -> bool -> exp
val atom : at:Common.Location.t -> string -> atom
val unarith : exp -> exp
val arithmetic : at:Common.Location.t -> op:binop -> exp -> exp -> exp
val comparison : at:Common.Location.t -> op:cmpop -> exp -> exp -> exp

val call :
  ?types:targ list -> at:Common.Location.t -> string -> args:exp list -> exp

val plaintyp_of_kind :
  types:metadata -> at:Common.Location.t -> kind -> plaintyp

val variable : at:Common.Location.t -> string -> typ:plaintyp -> exp

(** Builds a function declaration and its ordered clauses. Each equation gives a
    clause's argument patterns, result and premises. *)
val function_definitions :
  at:Common.Location.t ->
  string ->
  parameters:plaintyp list ->
  result:plaintyp ->
  equations:(exp list * exp * prem list) list ->
  spec

(** Fills a relation presentation's notation with the values in order. *)
val conclusion_of_relation :
  at:Common.Location.t -> def -> values:exp list -> exp
