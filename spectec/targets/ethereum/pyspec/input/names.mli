(** Consensus names, supported library bindings and their SpecTec names. *)

(** Names from the consensus specification that translation recognizes. *)

val state_type : string
val state_parameter : string
val validator_index : string
val root : string
val bls_pubkey : string
val bls_signature : string
val signing_data : string
val execution_engine : string
val execution_engine_global : string
val execution_payload : string
val new_payload_request : string
val new_payload_method : string
val execution_payload_keyword : string
val endianness : string

(** [prelude.spectec] implements this function as
    [$translated_set_or_append_list]. *)
val set_or_append_list : string

val admitted_methods : string list

(** Byte types whose constructor the source may call directly. *)
val nominal_bytes_constructors : string list

val library : string list

(** Resolves a Python primitive by namespace and attribute name. *)
val primitive_of_name : namespace:string -> string -> Syntax.primitive option

val namespace_of_primitive : Syntax.primitive -> string

(** [Int] and [Bool] denote SpecTec's [int] and [bool] types. [Defined] carries
    a SpecTec type name. *)
type spectec_type = Int | Bool | Defined of string

(** [Type] uses a pyspec class name. [ByteVector] uses a byte width. *)
type named = Type of string | ByteVector of int

val spectec_type_of_named : named -> spectec_type option
val builtin_of_primitive : Syntax.primitive -> string

(** The target builtin behind the engine's new-payload method. *)
val new_payload_builtin : string

(** Capitalizes and joins the underscore-separated words of a function name. *)
val relation_of_function : string -> string

val variable_of_parameter : spectec_type -> string -> string
