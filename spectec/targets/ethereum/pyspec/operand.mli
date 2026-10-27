(** Operands, which pair an EL expression with its source kind.

    The operation modules take evaluated values and source type metadata. They
    also take the translation context, for metadata, fresh variables and
    definition registration, and the branch they extend with premises and
    bindings. Ordinary operand operations take no source expressions or
    statements. Sequence helper builders additionally accept callbacks supplied
    by source traversal. *)

open Common.Source
open Lang.El

type t = { exp : exp; kind : Kind.t }

val string_of_exp : exp -> string
val id : at:region -> string -> id
val var : at:region -> string -> exp
val number : at:region -> Bigint.t -> exp
val nat : at:region -> int -> exp
val bool : at:region -> bool -> exp
val atom : at:region -> string -> atom
val unarith : exp -> exp
val arithmetic : at:region -> op:binop -> exp -> exp -> exp
val comparison : at:region -> op:cmpop -> exp -> exp -> exp
val call : ?types:targ list -> at:region -> string -> args:exp list -> exp
val typ : types:Kind.metadata -> at:region -> Kind.t -> plaintyp
val variable : at:region -> string -> typ:plaintyp -> exp

(** Builds a function declaration and its ordered clauses. Each equation gives a
    clause's argument patterns, result and premises. *)
val function_definitions :
  ?type_parameters:string list ->
  at:region ->
  string ->
  parameters:plaintyp list ->
  result:plaintyp ->
  equations:(exp list * exp * prem list) list ->
  spec

(** Fills a relation presentation's notation with the values in order. *)
val conclusion : at:region -> def -> values:exp list -> exp
