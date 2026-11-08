let state_type = "BeaconState"
let state_parameter = "state"
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
let set_or_append_list = "set_or_append_list"
let endianness = "ENDIANNESS"

let admitted_methods =
  [ "append"; "count"; "index"; "intersection"; new_payload_method ]

let nominal_bytes_constructors =
  [ root; "Domain"; "ExecutionAddress"; bls_pubkey ]

let library =
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
    "Bytes32";
    new_payload_request;
    execution_engine_global;
    "bls";
    "int";
    endianness;
  ]
  @ nominal_bytes_constructors

let primitive_sources =
  Syntax.
    [
      (BlsKeyValidate, ("bls", "KeyValidate"));
      (BlsAggregatePubkeys, ("bls", "AggregatePKs"));
      (BlsVerify, ("bls", "Verify"));
      (BlsFastAggregateVerify, ("bls", "FastAggregateVerify"));
      (BlsG1Decode, ("bls", "bytes48_to_G1"));
      (BlsG1Encode, ("bls", "G1_to_bytes48"));
      (BlsG1Add, ("bls", "add"));
      (BlsG1Neg, ("bls", "neg"));
      (IntFromBytes, ("int", "from_bytes"));
    ]

let primitive_of_name ~namespace name =
  List.find_map
    (fun (primitive, source) ->
      if source = (namespace, name) then Some primitive else None)
    primitive_sources

let namespace_of_primitive primitive =
  fst (List.assoc primitive primitive_sources)

type spectec_type = Int | Bool | Defined of string
type named = Type of string | ByteVector of int

let spectec_types =
  [
    (Type "BeaconState", Defined "beaconState");
    (Type "Validator", Defined "validator");
    (Type "Checkpoint", Defined "checkpoint");
    (Type "HistoricalSummary", Defined "historicalSummary");
    (Type "BeaconBlockHeader", Defined "beaconBlockHeader");
    (Type "BeaconBlock", Defined "beaconBlock");
    (Type "SignedBeaconBlock", Defined "signedBeaconBlock");
    (Type "BeaconBlockBody", Defined "beaconBlockBody");
    (Type "SignedBeaconBlockHeader", Defined "signedBeaconBlockHeader");
    (Type "ProposerSlashing", Defined "proposerSlashing");
    (Type "AttestationData", Defined "attestationData");
    (Type "IndexedAttestation", Defined "indexedAttestation");
    (Type "AttesterSlashing", Defined "attesterSlashing");
    (Type "Attestation", Defined "attestation");
    (Type "DepositData", Defined "depositData");
    (Type "Deposit", Defined "deposit");
    (Type "VoluntaryExit", Defined "voluntaryExit");
    (Type "SignedVoluntaryExit", Defined "signedVoluntaryExit");
    (Type "SyncAggregate", Defined "syncAggregate");
    (Type "Withdrawal", Defined "withdrawal");
    (Type "ExecutionPayload", Defined "executionPayload");
    (Type "BLSToExecutionChange", Defined "blsToExecutionChange");
    (Type "SignedBLSToExecutionChange", Defined "signedBlsToExecutionChange");
    (Type "BLSSignature", Defined "blsSignature");
    (Type "ExecutionAddress", Defined "executionAddress");
    (Type "Hash32", Defined "hash32");
    (Type "WithdrawalIndex", Defined "withdrawalIndex");
    (Type "ExecutionPayloadHeader", Defined "executionPayloadHeader");
    (Type "ExecutionEngine", Defined "executionEngine");
    (Type "Eth1Data", Defined "eth1Data");
    (Type "Fork", Defined "fork");
    (Type "SyncCommittee", Defined "syncCommittee");
    (Type "Epoch", Defined "epoch");
    (Type "Slot", Defined "slot");
    (Type "Gwei", Defined "gwei");
    (Type "ValidatorIndex", Defined "validatorIndex");
    (Type "CommitteeIndex", Defined "committeeIndex");
    (Type "Root", Defined "root");
    (Type "BLSPubkey", Defined "blsPubkey");
    (Type "DomainType", Defined "domainType");
    (Type "Version", Defined "version");
    (Type "Domain", Defined "domain");
    (Type "ForkData", Defined "forkdata");
    (Type "SigningData", Defined "signingData");
    (Type "DepositMessage", Defined "depositMessage");
    (Type "ParticipationFlags", Defined "participationFlags");
    (Type "uint8", Defined "uint8");
    (Type "uint32", Defined "uint32");
    (Type "uint64", Defined "uint64");
    (Type "uint256", Defined "uint256");
    (* Handwritten SSZ fields use [bool], and [StateTransition] uses [boolean].
       The handwritten types make [boolean] an alias of [bool]. *)
    (Type "boolean", Bool);
    (Type "bool", Defined "boolean");
    (Type "int", Int);
    (Type "bytes", Defined "bytes");
    (ByteVector 1, Defined "bytes1");
    (ByteVector 4, Defined "bytes4");
    (ByteVector 8, Defined "bytes8");
    (ByteVector 20, Defined "bytes20");
    (ByteVector 28, Defined "bytes28");
    (ByteVector 31, Defined "bytes31");
    (ByteVector 32, Defined "bytes32");
    (ByteVector 48, Defined "bytes48");
    (ByteVector 96, Defined "bytes96");
    (ByteVector 256, Defined "bytes256");
  ]

let primitive_names =
  [
    (Syntax.BlsKeyValidate, "bls_key_validate");
    (Syntax.BlsAggregatePubkeys, "bls_aggregate_pubkeys");
    (Syntax.BlsVerify, "bls_verify");
    (Syntax.BlsFastAggregateVerify, "bls_fast_aggregate_verify");
    (* Compressed G1 points use one builtin to validate and canonicalize both
       decoded and encoded values. *)
    (Syntax.BlsG1Decode, "bls_g1_canonicalize");
    (Syntax.BlsG1Encode, "bls_g1_canonicalize");
    (Syntax.BlsG1Add, "bls_g1_add");
    (Syntax.BlsG1Neg, "bls_g1_neg");
    (Syntax.IntFromBytes, "translated_bytes_le");
  ]

let spectec_type_of_named named = List.assoc_opt named spectec_types
let builtin_of_primitive primitive = List.assoc primitive primitive_names
let new_payload_builtin = "ee_verify_and_notify_new_payload"

let relation_of_function function_name =
  String.split_on_char '_' function_name
  |> List.map (fun word ->
         String.capitalize_ascii (String.lowercase_ascii word))
  |> String.concat ""

let string_of_spectec_type = function
  | Int -> "int"
  | Bool -> "bool"
  | Defined name -> name

let variable_of_parameter spectec_type parameter =
  string_of_spectec_type spectec_type ^ "_" ^ parameter
