open Lang.El

type record

val validity_guards :
  ctx:Ctx.t -> at:Common.Location.t -> Value.t -> branch:Branch.t -> Branch.t

val targ_of_kind : ctx:Ctx.t -> at:Common.Location.t -> Value.kind -> targ

val prepare_record :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  string ->
  positional:bool ->
  keywords:string list ->
  record

(** Returns the value relabeled with [kind], and a branch with the premises the
    conversion needs. Rejects a value that remerkleable would refuse to store.
*)
val coerce :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  kind:Value.kind ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val coerce_field :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  plan:record ->
  name:string ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val record :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  plan:record ->
  (string * Value.t) list ->
  branch:Branch.t ->
  Branch.t * Value.t

val serialize :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val hash_tree_root :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t
