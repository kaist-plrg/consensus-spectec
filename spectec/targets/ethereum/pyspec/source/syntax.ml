open Common.Source

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
type cmpop = Eq | NotEq | Lt | LtE | Gt | GtE | In | NotIn | Is | IsNot
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

let string_of_binop = function
  | Add -> "Add"
  | Sub -> "Sub"
  | Mult -> "Mult"
  | Mod -> "Mod"
  | FloorDiv -> "FloorDiv"
  | Pow -> "Pow"
  | BitAnd -> "BitAnd"
  | BitOr -> "BitOr"
  | BitXor -> "BitXor"
  | RShift -> "RShift"

let target_names = function Single name -> [ name ] | Unpacked names -> names

let primitive_name = function
  | BlsKeyValidate -> "bls_key_validate"
  | BlsAggregatePubkeys -> "bls_aggregate_pubkeys"
  | BlsVerify -> "bls_verify"
  | BlsFastAggregateVerify -> "bls_fast_aggregate_verify"
  | BlsG1Decode -> "bls_g1_decode"
  | BlsG1Encode -> "bls_g1_encode"
  | BlsG1Add -> "bls_g1_add"
  | BlsG1Neg -> "bls_g1_neg"
  | IntFromBytes -> "int_from_bytes"

let expr_children (node : expr) =
  match node.it with
  | Name _ | Int _ | BytesLiteral _ | Bool _ | Empty | NoneValue -> []
  | ListLiteral items | Tuple items -> items
  | Lambda (_, body) -> [ body ]
  | Attribute (value, _) -> [ value ]
  | Index (value, index) -> [ value; index ]
  | Slice (lower, upper, step) -> List.filter_map Fun.id [ lower; upper; step ]
  | Binary (_, left, right) -> [ left; right ]
  | Boolop (_, values) -> values
  | Not value | Negate value -> [ value ]
  | Compare (left, rights) -> left :: List.map snd rights
  | Conditional (test, yes, no) -> [ test; yes; no ]
  | Primitive (_, args) -> args
  | Call (_, args, keywords) -> args @ List.map snd keywords
  | Method (receiver, _, args) -> receiver :: args
  | Comprehension (element, _, iterable, filters)
  | Generator (element, _, iterable, filters) ->
      element :: iterable :: filters

let rec free_names (node : expr) =
  let without names nodes =
    List.filter
      (fun name -> not (List.mem name names))
      (List.concat_map free_names nodes)
  in
  match node.it with
  | Name name -> [ name ]
  | Lambda (name, body) -> without [ name ] [ body ]
  | Comprehension (element, target, iterable, filters)
  | Generator (element, target, iterable, filters) ->
      free_names iterable @ without (target_names target) (element :: filters)
  | _ -> List.concat_map free_names (expr_children node)

let statement_children (node : statement) =
  match node.it with
  | If (_, yes, no) -> yes @ no
  | While (_, body) | For (_, _, body) -> body
  | _ -> []

let statement_exprs (node : statement) =
  match node.it with
  | Assign (target, value) | AugAssign (_, target, value) -> [ target; value ]
  | AnnotatedAssign (target, _, value) -> [ target; value ]
  | Return value -> Option.to_list value
  | If (test, _, _) | While (test, _) | Assert test -> [ test ]
  | For (_, iterable, _) | Expression iterable -> [ iterable ]
  | Break | LocalHelper _ -> []

let rec fold_statements_preorder ~f ~init:acc nodes =
  List.fold_left
    (fun acc node ->
      fold_statements_preorder ~f ~init:(f acc node) (statement_children node))
    acc nodes

let iter_statements_preorder ~f nodes =
  fold_statements_preorder ~f:(fun () node -> f node) ~init:() nodes

let rec exists_statement ~f:predicate nodes =
  List.exists
    (fun node ->
      predicate node || exists_statement ~f:predicate (statement_children node))
    nodes

let statement_exprs_preorder nodes =
  fold_statements_preorder
    ~f:(fun expressions node ->
      List.rev_append (statement_exprs node) expressions)
    ~init:[] nodes
  |> List.rev

let assigned_names nodes =
  fold_statements_preorder
    ~f:(fun names node ->
      match node.it with
      | Assign ({ it = Name name; _ }, _)
      | AnnotatedAssign ({ it = Name name; _ }, _, _)
      | AugAssign (_, { it = Name name; _ }, _) ->
          name :: names
      | For (target, _, _) -> target_names target @ names
      | _ -> names)
    ~init:[] nodes
