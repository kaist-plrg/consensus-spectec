(** Python functions whose declarations carry complete types. The declarations
    include SSZ bounds, Python-list results and state effects. Bodies remain
    [Syntax] until translation determines their expression kinds. Decoding
    assigns SpecTec names to types, argument variables and relations. *)

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

type spectec_type = Names.spectec_type = Int | Bool | Defined of string

(** [spectec_type] comes from the [Names] type table. An SSZ type parameter
    keeps its source name. *)
type python_type = {
  descriptor : descriptor;
  spectec_type : spectec_type option;
}

(** A [MutatesState] function changes its [state] argument in place and returns
    nothing. *)
type effect = Pure | MutatesState

type signature = {
  name : string;
  parameters : (string * string) list;
  optional : string list;
  (* Literal defaults by parameter name. Omitting an argument binds its default
     without making the parameter optional. *)
  defaults : (string * bool) list;
  returns : string option;
  effect : effect;
  (* Each parameter's SpecTec variable, in parameter order. *)
  variables : (string * string) list;
  (* A mutator's SpecTec relation name. *)
  relation : string option;
  (* Listed in the module document as returning a newly built tuple. *)
  fresh_result : bool;
}

type constant_value =
  | IntegerConstant of Bigint.t
  | SequenceConstant of Bigint.t list

(** Locals and used library bindings for one body, together with the module's
    record constructors and function signatures. *)
type namespace

(** One function body with its signature and namespace. All sources share the
    module's types, constants and state-read tables. *)
type source = private {
  signature : signature;
  body : Syntax.statement list;
  at : Common.Location.t;
  namespace : namespace;
  types : (string * python_type) list;
  constants : (string * (string * constant_value)) list;
  state_reads : (string * string list) list;
}

type name_role =
  | Local
  | Function of signature
  | Constructor
  | Cast
  | LibraryBinding
  | SetOrAppendList

(** All function signatures and a source for each function with a body. *)
type t

(** Validates the document and infers Python-list results once for the module.
    Each body gets its locals and library uses from syntax. Validation rejects
    names shared by record constructors, library bindings, unsigned classes,
    functions or [set_or_append_list]. Local helpers cannot reuse these names.
*)
val of_json : Yojson.Safe.t -> t

(** Rejects a file that cannot be read or does not hold JSON. *)
val load : string -> t

val types : t -> (string * python_type) list
val signatures : t -> signature list

(** Rejects a name missing from [types], reporting its location as [at]. *)
val python_type_of_name :
  types:(string * python_type) list ->
  at:Common.Location.t ->
  string ->
  python_type

val descriptor_of_name :
  types:(string * python_type) list ->
  at:Common.Location.t ->
  string ->
  descriptor

(** Sources are sorted by function name. *)
val sources : t -> source list

(** Functions that return a Python list rather than an SSZ list. *)
val list_results : t -> string list

(** Locals take precedence over every other role. Decoding gives each other name
    at most one role. [None] means no supported role was found. *)
val role_of_name : source -> string -> name_role option
