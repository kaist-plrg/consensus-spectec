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

type effect = Pure | MutatesState

type signature = {
  name : string;
  parameters : (string * string) list;
  optional : string list;
  defaults : (string * bool) list;
  returns : string option;
  effect : effect;
  arguments : (string * string) list;
  declaration : string;
  relation : string option;
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

module Contracts = struct
  let state_type = "BeaconState"
  let validator_index = "ValidatorIndex"
  let root = "Root"
  let bls_pubkey = "BLSPubkey"
  let bls_signature = "BLSSignature"
  let signing_data = "SigningData"
  let execution_engine = "ExecutionEngine"
  let execution_engine_global = "EXECUTION_ENGINE"
  let execution_payload = "ExecutionPayload"
  let new_payload_request = "NewPayloadRequest"
  let new_payload_method = "verify_and_notify_new_payload"
  let execution_payload_keyword = "execution_payload"

  let nominal_bytes_constructors =
    [ root; "Domain"; "ExecutionAddress"; bls_pubkey ]

  let admitted =
    [
      "all";
      "enumerate";
      "len";
      "min";
      "max";
      "sum";
      "set";
      "filter";
      "sorted";
      "zip";
      "range";
      "hash_tree_root";
      "hash";
      "uint_to_bytes";
      "int_from_bytes";
      "Bytes32";
      root;
      "Domain";
      "ExecutionAddress";
      bls_pubkey;
      new_payload_request;
      execution_engine_global;
      "bls_key_validate";
      "bls_aggregate_pubkeys";
      "bls_verify";
      "bls_fast_aggregate_verify";
      "bls_g1_decode";
      "bls_g1_encode";
      "bls_g1_canonicalize";
      "bls_g1_add";
      "bls_g1_neg";
    ]
end
