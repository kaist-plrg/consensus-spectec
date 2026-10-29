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
    Spec_names.root;
    "Domain";
    "ExecutionAddress";
    Spec_names.bls_pubkey;
    Spec_names.new_payload_request;
    Spec_names.execution_engine_global;
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

type declarations =
  | NoneRequired
  | BeforeArity of string list
  | BeforeArguments of string list

type operand = Exact of Kind.t | Bytes of int | Sequence of Kind.t

type primitive_contract = {
  name : string;
  operands : operand list;
  result : Kind.t;
  bind_result : bool;
  arity_error : string;
  operand_error : string;
  declarations : declarations;
}

type operation =
  | Hash
  | Serialize
  | HashTreeRoot
  | All
  | Length
  | Bytes32Value
  | NominalBytesValue of string
  | NumericCast of string
  | Primitive of primitive_contract
  | LittleEndian
  | AggregatePubkeys

type t =
  | Eager of operation
  | Bytes32Constructor
  | NominalBytesConstructor of string
  | Range
  | Set
  | Sorted
  | Sum
  | Extremum of string

type contract = {
  arity : int;
  diagnostic : string;
  declarations : declarations;
}

let key_validate =
  {
    name = Syntax.primitive_name Syntax.BlsKeyValidate;
    operands = [ Exact (Kind.Named Spec_names.bls_pubkey) ];
    result = Kind.boolean;
    bind_result = false;
    arity_error = "KeyValidate requires one positional value";
    operand_error = "KeyValidate requires BLSPubkey";
    declarations = BeforeArity [ Syntax.primitive_name Syntax.BlsKeyValidate ];
  }

let of_primitive primitive =
  (* A G1 point is represented by its compressed encoding, so decoding and
     encoding share one builtin that validates and canonicalizes it. *)
  let name =
    match primitive with
    | Syntax.BlsG1Decode | Syntax.BlsG1Encode -> "bls_g1_canonicalize"
    | _ -> Syntax.primitive_name primitive
  in
  let g1 operands result operand_error =
    Primitive
      {
        name;
        operands;
        result;
        operand_error;
        bind_result = true;
        arity_error = "G1 primitive arity";
        declarations = BeforeArguments [ name ];
      }
  in
  let predicate operands arity_error operand_error =
    Primitive
      {
        name;
        operands;
        arity_error;
        operand_error;
        result = Kind.boolean;
        bind_result = false;
        declarations = BeforeArity [ name ];
      }
  in
  let open Kind in
  match primitive with
  | Syntax.BlsG1Decode ->
      g1 [ Bytes 48 ] G1Point "G1 decoding requires exactly 48 bytes"
  | Syntax.BlsG1Encode ->
      g1 [ Exact G1Point ]
        (ByteString (Bigint.of_int 48))
        "Expected a decoded G1 point"
  | Syntax.BlsG1Neg ->
      g1 [ Exact G1Point ] G1Point "Expected a decoded G1 point"
  | Syntax.BlsG1Add ->
      g1 [ Exact G1Point; Exact G1Point ] G1Point "Expected a decoded G1 point"
  | Syntax.BlsFastAggregateVerify ->
      predicate
        [
          Sequence (Named Spec_names.bls_pubkey);
          Bytes 32;
          Exact (Named Spec_names.bls_signature);
        ]
        "FastAggregateVerify requires three positional values"
        "FastAggregateVerify requires BLSPubkey sequence, 32-byte message, \
         BLSSignature"
  | Syntax.BlsVerify ->
      predicate
        [
          Exact (Named Spec_names.bls_pubkey);
          Exact (Named Spec_names.root);
          Exact (Named Spec_names.bls_signature);
        ]
        "Verify requires three positional values"
        "Verify requires BLSPubkey, Root, BLSSignature"
  | Syntax.BlsKeyValidate -> Primitive key_validate
  | Syntax.IntFromBytes -> LittleEndian
  | Syntax.BlsAggregatePubkeys -> AggregatePubkeys

let resolve ~builtins name =
  if not (List.mem name builtins) then None
  else
    match name with
    | "hash" -> Some (Eager Hash)
    | "uint_to_bytes" -> Some (Eager Serialize)
    | "hash_tree_root" -> Some (Eager HashTreeRoot)
    | "all" -> Some (Eager All)
    | "len" -> Some (Eager Length)
    | "Bytes32" -> Some Bytes32Constructor
    | name when List.mem name Spec_names.nominal_bytes_constructors ->
        Some (NominalBytesConstructor name)
    | "range" -> Some Range
    | "set" -> Some Set
    | "sorted" -> Some Sorted
    | "sum" -> Some Sum
    | "min" | "max" -> Some (Extremum name)
    | _ -> None

let contract operation =
  let arity, diagnostic, declarations =
    match operation with
    | Hash -> (1, "Hash requires one positional byte input", NoneRequired)
    | Serialize ->
        (1, "Unsigned serialization requires one positional input", NoneRequired)
    | HashTreeRoot ->
        (1, "SSZ hashing requires one positional argument", NoneRequired)
    | All -> (1, "all requires one materialized boolean sequence", NoneRequired)
    | Length -> (1, "len requires one reviewed sequence", NoneRequired)
    | Bytes32Value ->
        (1, "Bytes32 requires zero or one positional argument", NoneRequired)
    | NominalBytesValue name ->
        (1, name ^ " takes at most one positional byte value", NoneRequired)
    | NumericCast _ -> (1, "Numeric cast arity", NoneRequired)
    | Primitive primitive ->
        ( List.length primitive.operands,
          primitive.arity_error,
          primitive.declarations )
    | LittleEndian ->
        ( 1,
          "Byte decoding requires one positional little-endian input",
          NoneRequired )
    | AggregatePubkeys ->
        ( 1,
          "AggregatePKs requires one positional sequence",
          BeforeArguments [ "bls_aggregate_pubkeys"; "bls_key_validate" ] )
  in
  { arity; diagnostic; declarations }
