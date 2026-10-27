open Common.Source

val normalize_index :
  ctx:Ctx.t ->
  at:region ->
  branch:Branch.t ->
  Operand.t ->
  index:Operand.t ->
  Branch.t * Operand.t

val concat :
  ctx:Ctx.t ->
  at:region ->
  branch:Branch.t ->
  Operand.t ->
  right:Operand.t ->
  Branch.t * Operand.t

val shape : ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> Branch.t

val make_set :
  ctx:Ctx.t -> at:region -> element:Kind.t -> Operand.t -> Operand.t

val length :
  ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> Branch.t * Operand.t

val list_literal :
  ctx:Ctx.t ->
  at:region ->
  branch:Branch.t ->
  Operand.t list ->
  Branch.t * Operand.t

val prefix_slice :
  ctx:Ctx.t ->
  at:region ->
  element:Kind.t ->
  branch:Branch.t ->
  Operand.t ->
  upper:Operand.t ->
  (Branch.t * Operand.t) list

val bitvector_slice :
  at:region ->
  element:Kind.t ->
  branch:Branch.t ->
  Operand.t ->
  start:Bigint.t ->
  finish:Bigint.t ->
  (Branch.t * Operand.t) list

(** Reads an element, caching the read so repeated reads share one binding. *)
val read_index :
  ctx:Ctx.t ->
  at:region ->
  branch:Branch.t ->
  Operand.t ->
  index:Operand.t ->
  Branch.t * Operand.t

val all :
  ctx:Ctx.t -> at:region -> branch:Branch.t -> Operand.t -> Branch.t * Operand.t

(** Generates a recursive helper that applies [element] to each item. The
    callback returns the branches that emit a value and the branches that skip
    the item. Comprehensions supply target binding, filters and element
    evaluation through it. Sort-key decoration pairs each element with a
    validated scalar or tuple key, and public-key validation supplies a
    per-element predicate with no captures. *)
val map :
  ctx:Ctx.t ->
  at:region ->
  captures:(string * Operand.t) list ->
  element:
    (Branch.t ->
    Operand.t ->
    Operand.t ->
    (Branch.t * Operand.t) list * Branch.t list) ->
  branch:Branch.t ->
  Operand.t ->
  Branch.t * Operand.t

val intersection :
  ctx:Ctx.t ->
  at:region ->
  branch:Branch.t ->
  Operand.t ->
  right:Operand.t ->
  Branch.t * Operand.t

val search :
  ctx:Ctx.t ->
  at:region ->
  method_name:string ->
  branch:Branch.t ->
  Operand.t ->
  needle:Operand.t ->
  Branch.t * Operand.t

val zip : ctx:Ctx.t -> at:region -> Operand.t list -> Operand.t
val declare_range : ctx:Ctx.t -> at:region -> unit

val range :
  ctx:Ctx.t ->
  at:region ->
  branch:Branch.t ->
  Operand.t list ->
  Branch.t * Operand.t

val sort :
  ctx:Ctx.t ->
  at:region ->
  element:Kind.t ->
  branch:Branch.t ->
  Operand.t ->
  Branch.t * Operand.t

val repeat :
  ctx:Ctx.t ->
  at:region ->
  branch:Branch.t ->
  item:Operand.t ->
  Operand.t ->
  Branch.t * Operand.t

val extremum :
  ctx:Ctx.t ->
  at:region ->
  operation:string ->
  branch:Branch.t ->
  Operand.t ->
  Branch.t * Operand.t

val sum :
  ctx:Ctx.t ->
  at:region ->
  branch:Branch.t ->
  Operand.t ->
  (Branch.t * Operand.t) list
