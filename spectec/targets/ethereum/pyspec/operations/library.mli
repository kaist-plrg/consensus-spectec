(** Supported Python builtins and library functions, with contracts for argument
    counts, operands and results. *)

type operand = Exact of Value.kind | Bytes of int | Sequence of Value.kind

type primitive_contract = private {
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

val key_validate : primitive_contract
val operation_of_primitive : Syntax.primitive -> operation
val of_name : string -> t option
val contract_of_operation : operation -> contract
