open Common.Source

type descriptor =
  | Uint of int
  | Integer
  | Boolean
  | Opaque
  | SszParameter
  | Bytes of { length : Bigint.t option; limit : Bigint.t option }
  | Product of string list
  | Record of (string * string) list
  | Set of string
  | Sequence of {
      element : string;
      length : Bigint.t option;
      limit : Bigint.t option;
      bitvector : bool;
    }

type typ = { descriptor : descriptor; target : string option }

type sequence_helper = {
  name : string;
  parameters : string list;
  body : Syntax.statement list;
  at : region;
}

(** A [MutatesState] function changes its [state] argument in place and returns
    nothing. *)
type effect = Pure | MutatesState

type signature = {
  name : string;
  parameters : (string * string) list;
  optional : string list;
  (* Literal defaults, by parameter name. A call site that omits such a
     parameter binds this value, and the parameter keeps its present type. *)
  defaults : (string * bool) list;
  returns : string option;
  effect : effect;
  arguments : (string * string) list;
  declaration : string;
  relation : string option;
  (* The source review states that a tuple this function returns is newly
     built. *)
  fresh_result : bool;
}

type constant_value =
  | IntegerConstant of Bigint.t
  | SequenceConstant of Bigint.t list

type t = {
  all_expansion_limit : int;
  types : (string * typ) list;
  constants : (string * (string * constant_value)) list;
  casts : (string * string) list;
  state_reads : (string * string list) list;
  calls : signature list;
  sequence_helpers : sequence_helper list;
  builtins : string list;
  (* Record types the body calls by name to construct a value. *)
  constructors : string list;
  signature : signature;
  locals : string list;
  body : Syntax.statement list;
  at : region;
}

(** Recognized consensus names and builtin names admitted by source documents.
*)
module Contracts : sig
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

  val admitted : string list
end
