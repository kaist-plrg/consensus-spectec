type search = Count | Index

val normalize_index :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  index:Value.t ->
  Branch.t * Value.t

val concat :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  right:Value.t ->
  Branch.t * Value.t

val shape :
  ctx:Ctx.t -> at:Common.Location.t -> branch:Branch.t -> Value.t -> Branch.t

val set_of_sequence :
  ctx:Ctx.t -> at:Common.Location.t -> element:Value.kind -> Value.t -> Value.t

val length :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val list_literal :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t list ->
  Branch.t * Value.t

val prefix_slice :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  element:Value.kind ->
  branch:Branch.t ->
  Value.t ->
  upper:Value.t ->
  (Branch.t * Value.t) list

(** [finish] is at most the length that [shape]'s premise gives [base]. *)
val bitvector_slice :
  at:Common.Location.t ->
  element:Value.kind ->
  branch:Branch.t ->
  Value.t ->
  start:Bigint.t ->
  finish:Bigint.t ->
  (Branch.t * Value.t) list

(** Reads an element, caching the read so repeated reads share one binding. *)
val read_index :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  index:Value.t ->
  Branch.t * Value.t

val all :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val intersection :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  right:Value.t ->
  Branch.t * Value.t

val search :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  search:search ->
  branch:Branch.t ->
  Value.t ->
  needle:Value.t ->
  Branch.t * Value.t

val zip : ctx:Ctx.t -> at:Common.Location.t -> Value.t list -> Value.t

val range :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t list ->
  Branch.t * Value.t

val sort :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  element:Value.kind ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val repeat :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  item:Value.t ->
  Value.t ->
  Branch.t * Value.t

val extremum :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  operation:Numeric_ops.extremum ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val sum :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  (Branch.t * Value.t) list
