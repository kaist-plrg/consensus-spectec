(** Assignment destinations and their updates.

    [resolve] evaluates an assignment destination and produces a [target] with a
    container, an EL selection and the state or reference that owns it.
    Reference indexing converts the source index, and direct state indexing uses
    natural indices. Each destination kind checks its own slice and replacement
    rules. [apply] builds the update and propagates it through aliases, retained
    iterator parents and the state. An empty slice write keeps the current state
    value and still invalidates state reads. *)

open Common.Source

type owner =
  | StateWrite of Operand.t Store.location
  | ReferenceWrite of Operand.t Store.reference

type target = { container : Operand.t; selection : Lang.El.path; owner : owner }

(** Updates the container and propagates the new value to aliases, retained
    iterator parents and the state. *)
val apply :
  ctx:Ctx.t ->
  at:region ->
  target ->
  replacement:Lang.El.exp ->
  branch:Branch.t ->
  Branch.t

(** Stores a value into an assignment destination. A local name binding also
    establishes or detaches the reference identity. *)
val store :
  ?copied:string ->
  ctx:Ctx.t ->
  Syntax.expr ->
  value:Operand.t ->
  branch:Branch.t ->
  Branch.t
