open Common.Source

(** Operations that the exporter resolves from BLS and integer byte-decoding
    calls. An ordinary call keeps its source name and cannot select one of these
    operations by spelling. *)
type primitive =
  | BlsKeyValidate
  | BlsAggregatePubkeys
  | BlsVerify
  | BlsFastAggregateVerify
  | BlsG1Decode
  | BlsG1Encode
  | BlsG1Add
  | BlsG1Neg
  | IntFromBytes

(** Python's arithmetic, bitwise and shift operators, named after their [ast]
    classes. *)
type binop =
  | Add
  | Sub
  | Mult
  | Mod
  | FloorDiv
  | Pow
  | BitAnd
  | BitOr
  | BitXor
  | RShift

type boolop = And | Or

(** Python's comparison operators, named after their [ast] classes. *)
type cmpop = Eq | NotEq | Lt | LtE | Gt | GtE | In | NotIn | Is | IsNot

(** A loop or comprehension target as written. [Single] binds one name, as in
    [for x in xs]. [Unpacked] unpacks each element into a tuple of names, as in
    [for x, y in pairs]. *)
type target = Single of string | Unpacked of string list

type expr = expr' phrase

and expr' =
  | Name of string
  | Int of Bigint.t
  | BytesLiteral of string
  | Bool of bool
  | Empty
  | NoneValue
  | ListLiteral of expr list
  | Tuple of expr list
  | Lambda of string * expr
  | Attribute of expr * string
  | Index of expr * expr
  | Slice of expr option * expr option * expr option
  | Binary of binop * expr * expr
  | Boolop of boolop * expr list
  | Not of expr
  | Negate of expr
  | Compare of expr * (cmpop * expr) list
  | Conditional of expr * expr * expr
  | Primitive of primitive * expr list
  | Call of string * expr list * (string * expr) list
  | Method of expr * string * expr list
  | Comprehension of expr * target * expr * expr list
  | Generator of expr * target * expr * expr list

type statement = statement' phrase

and statement' =
  | Assign of expr * expr
  | AnnotatedAssign of expr * string * expr
  | AugAssign of binop * expr * expr
  | Return of expr option
  | If of expr * statement list * statement list
  | While of expr * statement list
  | For of target * expr * statement list
  | Assert of expr
  | Expression of expr
  | Break
  | LocalHelper of local_helper

and local_helper = {
  helper : string;
  elements : string;
  mutator : string;
  element : string;
  captured : string;
}

val target_names : target -> string list

(** The operator's Python [ast] class name. *)
val string_of_binop : binop -> string

val primitive_name : primitive -> string

(** The direct subexpressions of an expression, in source order. *)
val expr_children : expr -> expr list

val free_names : expr -> string list

(** The statements nested directly in a branch or loop body, in source order.
    Local helper definitions form separate scopes and contribute none. *)
val statement_children : statement -> statement list

(** The expressions a statement holds itself, excluding nested statements. *)
val statement_exprs : statement -> expr list

val fold_statements_preorder :
  f:('a -> statement -> 'a) -> init:'a -> statement list -> 'a

val iter_statements_preorder : f:(statement -> unit) -> statement list -> unit
val exists_statement : f:(statement -> bool) -> statement list -> bool

(** Every statement's own expressions, in preorder. *)
val statement_exprs_preorder : statement list -> expr list

(** Local names bound by assignments and loop targets anywhere in the
    statements. *)
val assigned_names : statement list -> string list
