type t =
  | Named of string
  | Optional of t
  | ByteString of Bigint.t
  | ByteInteger (* Plain Python int in [0, 256), produced by byte iteration. *)
  | G1Point
  | Sequence of t * Bigint.t option
  | PythonList of t
  | Set of t
  | Empty
  | FrozenSequence of t * Bigint.t
  | Product of t list

type metadata = (string * Source.typ) list

val boolean : t
val integer : t

val source_type :
  types:metadata -> at:Common.Source.region -> string -> Source.typ

val descriptor :
  types:metadata -> at:Common.Source.region -> string -> Source.descriptor

val equal_byte_types :
  types:metadata -> at:Common.Source.region -> string -> string -> bool

val bits : types:metadata -> at:Common.Source.region -> t -> int option
val is_integer : types:metadata -> at:Common.Source.region -> t -> bool
val is_boolean : types:metadata -> at:Common.Source.region -> t -> bool
val is_copyable_scalar : types:metadata -> at:Common.Source.region -> t -> bool
val set_element : types:metadata -> at:Common.Source.region -> t -> t option

val check_set_value :
  types:metadata ->
  at:Common.Source.region ->
  t ->
  expected:t option ->
  diagnostic:string ->
  unit

val sequence :
  types:metadata -> at:Common.Source.region -> t -> t * Bigint.t option * bool

val bounded_ssz_list :
  types:metadata -> at:Common.Source.region -> string -> (t * Bigint.t) option

val product : types:metadata -> at:Common.Source.region -> t -> t list
val is_readonly_product : types:metadata -> at:Common.Source.region -> t -> bool

val fields :
  types:metadata -> at:Common.Source.region -> t -> (string * string) list

val byte_width :
  types:metadata -> at:Common.Source.region -> t -> Bigint.t option

val is_byte_valued : types:metadata -> at:Common.Source.region -> t -> bool

val is_named_container_or_set :
  types:metadata -> at:Common.Source.region -> t -> bool

val is_flat_record : types:metadata -> at:Common.Source.region -> t -> bool
