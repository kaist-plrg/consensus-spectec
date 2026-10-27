open Common.Source

(** Each expression yields its alternatives: one value per branch that reaches
    it, with premises in source evaluation order. *)
val translate :
  ctx:Ctx.t -> Syntax.expr -> branch:Branch.t -> (Branch.t * Operand.t) list

(** Branches on which the condition's truth value is [holds]. *)
val condition :
  ctx:Ctx.t -> Syntax.expr -> holds:bool -> branch:Branch.t -> Branch.t list

val arguments :
  ctx:Ctx.t ->
  Syntax.expr list ->
  branch:Branch.t ->
  (Branch.t * Operand.t list) list

(** Evaluates an iterable to a materialized sequence. *)
val iterable :
  ctx:Ctx.t -> Syntax.expr -> branch:Branch.t -> (Branch.t * Operand.t) list

val read_name : ctx:Ctx.t -> at:region -> branch:Branch.t -> string -> Operand.t

val bind_tuple_targets :
  ctx:Ctx.t ->
  at:region ->
  arity_error:string ->
  branch:Branch.t ->
  targets:string list ->
  Operand.t ->
  Branch.t

(** Recognizes a [range] call whose elements cannot be negative. *)
val is_nonnegative_range : ctx:Ctx.t -> Syntax.expr -> bool

(** Orders written arguments for evaluation and maps them to parameter
    positions. An absent position takes the parameter's [None] default. *)
val call_arguments :
  at:region ->
  signature:Source.signature ->
  Syntax.expr list ->
  keywords:(string * Syntax.expr) list ->
  Syntax.expr list * int option list

val call_signature : ctx:Ctx.t -> at:region -> string -> Source.signature

val slice_bounds :
  ctx:Ctx.t ->
  at:region ->
  branch:Branch.t ->
  Bigint.t ->
  lower:Syntax.expr option ->
  upper:Syntax.expr option ->
  step:Syntax.expr option ->
  Branch.t * Bigint.t * Bigint.t
