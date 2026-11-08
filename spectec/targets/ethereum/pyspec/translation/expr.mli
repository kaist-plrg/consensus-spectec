(** Each expression yields its alternatives: one value per branch that reaches
    it, with premises in source evaluation order. *)
val translate :
  ctx:Ctx.t -> Syntax.expr -> branch:Branch.t -> (Branch.t * Value.t) list

val binary_operator :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  op:Syntax.binop ->
  branch:Branch.t ->
  Value.t ->
  Value.t ->
  Branch.t * Value.t

(** Branches on which the condition's truth value is [holds]. *)
val condition :
  ctx:Ctx.t -> Syntax.expr -> holds:bool -> branch:Branch.t -> Branch.t list

val arguments :
  ctx:Ctx.t ->
  Syntax.expr list ->
  branch:Branch.t ->
  (Branch.t * Value.t list) list

(** Evaluates an iterable into a stored sequence value. *)
val iterable :
  ctx:Ctx.t -> Syntax.expr -> branch:Branch.t -> (Branch.t * Value.t) list

val read_name :
  ctx:Ctx.t -> at:Common.Location.t -> branch:Branch.t -> string -> Value.t

type callee =
  | Local
  | LocalHelper of Syntax.local_helper
  | SetOrAppendList
  | Constructor
  | Builtin of Library.t
  | Cast
  | Function of Typed.signature
  | Unsupported

(** Checks locals before defined local helpers, then consults
    [Typed.role_of_name]. [Unsupported] covers unrecognized names and library
    bindings with no builtin implementation. *)
val callee_of_name : ctx:Ctx.t -> branch:Branch.t -> string -> callee

(** Binds a loop or comprehension target to one element. A [range] with a
    nonnegative start gives its element a nonnegativity premise. *)
val bind_loop_targets :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  arity_error:string ->
  iterated:Syntax.expr ->
  enumerated:bool ->
  target:Syntax.target ->
  index:Value.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t

(** For [enumerate] unpacked into two names, returns [true] and the underlying
    sequence. Otherwise returns [false] and the original iterable. Rejects an
    empty unpacking with [target_error]. *)
val enumeration :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  target_error:string ->
  Syntax.expr ->
  Syntax.target ->
  bool * Syntax.expr

(** A value is state-backed when its recorded origin is a [state] location or
    when the expression is a name bound to a state view. *)
val state_backed : branch:Branch.t -> Syntax.expr -> Value.t -> bool

val slice_bounds :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Bigint.t ->
  lower:Syntax.expr option ->
  upper:Syntax.expr option ->
  step:Syntax.expr option ->
  Branch.t * Bigint.t * Bigint.t
