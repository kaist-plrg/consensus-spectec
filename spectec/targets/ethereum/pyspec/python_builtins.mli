(** Builtin calls in source documents: the names a document may declare in
    scope, their resolution into operations, and the contracts of the BLS and
    byte-decoding primitives. *)

(** Builtin names a source document may declare in scope. *)
val admitted : string list

type declarations =
  | NoneRequired
  | BeforeArity of string list
  | BeforeArguments of string list

type operand = Exact of Kind.t | Bytes of int | Sequence of Kind.t

type primitive_contract = private {
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

val key_validate : primitive_contract
val of_primitive : Syntax.primitive -> operation
val resolve : builtins:string list -> string -> t option
val contract : operation -> contract
