(** Updates assignment destinations, list appends and [set_or_append_list].
    Updates propagate through aliases, retained iterator parents and the state.
    Even an empty slice write invalidates cached state reads. *)

type owner = StateWrite of Store.location | ReferenceWrite of Store.reference

type destination = {
  container : Value.t;
  selection : Lang.El.path;
  owner : owner;
}

(** Updates the container and propagates the new value to aliases, retained
    iterator parents and the state. *)
val apply :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  destination ->
  replacement:Lang.El.exp ->
  branch:Branch.t ->
  Branch.t

(** Stores a value into an assignment destination. A local name binding also
    establishes or detaches the reference identity. *)
val store :
  ?copied:string ->
  ctx:Ctx.t ->
  Syntax.expr ->
  value:Value.t ->
  branch:Branch.t ->
  Branch.t

(** The name of an owned list receiver. Pure functions may extend their own
    lists. *)
val owned_list_name : branch:Branch.t -> Syntax.expr -> string option

val append :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  Syntax.expr ->
  value:Syntax.expr ->
  branch:Branch.t ->
  Branch.t list

val set_or_append_list :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  Syntax.expr list ->
  branch:Branch.t ->
  Branch.t list
