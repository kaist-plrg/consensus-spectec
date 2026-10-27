(** Names from the consensus specification that translation recognizes. *)

val state_type : string
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

(** Byte types whose constructor the source may call directly. *)
val nominal_bytes_constructors : string list
