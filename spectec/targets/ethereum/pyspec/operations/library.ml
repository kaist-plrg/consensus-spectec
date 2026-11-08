open Value

type operand = Exact of Value.kind | Bytes of int | Sequence of Value.kind

type primitive_contract = {
  name : string;
  operands : operand list;
  result : Value.kind;
  bind_result : bool;
  arity_error : string;
  operand_error : string;
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
  | Zip
  | Enumerate
  | Filter
  | Set
  | Sorted
  | Sum
  | Extremum of Numeric_ops.extremum

type contract = { arity : int; diagnostic : string }

let key_validate =
  {
    name = Names.builtin_of_primitive Syntax.BlsKeyValidate;
    operands = [ Exact (Value.Named Names.bls_pubkey) ];
    result = Value.boolean;
    bind_result = false;
    arity_error = "KeyValidate requires one positional value";
    operand_error = "KeyValidate requires BLSPubkey";
  }

let operation_of_primitive primitive =
  let name = Names.builtin_of_primitive primitive in
  let g1 operands result operand_error =
    Primitive
      {
        name;
        operands;
        result;
        operand_error;
        bind_result = true;
        arity_error = "G1 primitive arity";
      }
  in
  let predicate operands arity_error operand_error =
    Primitive
      {
        name;
        operands;
        arity_error;
        operand_error;
        result = Value.boolean;
        bind_result = false;
      }
  in
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
          Sequence (Named Names.bls_pubkey);
          Bytes 32;
          Exact (Named Names.bls_signature);
        ]
        "FastAggregateVerify requires three positional values"
        "FastAggregateVerify requires BLSPubkey sequence, 32-byte message, \
         BLSSignature"
  | Syntax.BlsVerify ->
      predicate
        [
          Exact (Named Names.bls_pubkey);
          Exact (Named Names.root);
          Exact (Named Names.bls_signature);
        ]
        "Verify requires three positional values"
        "Verify requires BLSPubkey, Root, BLSSignature"
  | Syntax.BlsKeyValidate -> Primitive key_validate
  | Syntax.IntFromBytes -> LittleEndian
  | Syntax.BlsAggregatePubkeys -> AggregatePubkeys

let of_name name =
  match name with
  | "hash" -> Some (Eager Hash)
  | "uint_to_bytes" -> Some (Eager Serialize)
  | "hash_tree_root" -> Some (Eager HashTreeRoot)
  | "all" -> Some (Eager All)
  | "len" -> Some (Eager Length)
  | "Bytes32" -> Some Bytes32Constructor
  | name when List.mem name Names.nominal_bytes_constructors ->
      Some (NominalBytesConstructor name)
  | "range" -> Some Range
  | "zip" -> Some Zip
  | "enumerate" -> Some Enumerate
  | "filter" -> Some Filter
  | "set" -> Some Set
  | "sorted" -> Some Sorted
  | "sum" -> Some Sum
  | "min" -> Some (Extremum Numeric_ops.Min)
  | "max" -> Some (Extremum Numeric_ops.Max)
  | _ -> None

let contract_of_operation operation =
  let arity, diagnostic =
    match operation with
    | Hash -> (1, "Hash requires one positional byte input")
    | Serialize -> (1, "Unsigned serialization requires one positional input")
    | HashTreeRoot -> (1, "SSZ hashing requires one positional argument")
    | All -> (1, "all requires one materialized boolean sequence")
    | Length -> (1, "len requires one reviewed sequence")
    | Bytes32Value -> (1, "Bytes32 requires zero or one positional argument")
    | NominalBytesValue name ->
        (1, name ^ " takes at most one positional byte value")
    | NumericCast _ -> (1, "Numeric cast arity")
    | Primitive primitive ->
        (List.length primitive.operands, primitive.arity_error)
    | LittleEndian ->
        (1, "Byte decoding requires one positional little-endian input")
    | AggregatePubkeys -> (1, "AggregatePKs requires one positional sequence")
  in
  { arity; diagnostic }
