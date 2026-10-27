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
