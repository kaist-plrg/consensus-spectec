open Lang.El

(** Orders written arguments for evaluation and maps them to parameter
    positions. An absent position takes the parameter's [None] default. *)
val bind_arguments :
  at:Common.Location.t ->
  signature:Typed.signature ->
  Syntax.expr list ->
  keywords:(string * Syntax.expr) list ->
  Syntax.expr list * int option list

val type_parameters :
  types:Value.metadata -> at:Common.Location.t -> Typed.signature -> string list

val type_arguments :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  Typed.signature ->
  supplied:Value.t option list ->
  branch:Branch.t ->
  Branch.t * targ list

val parameter_values :
  Value.t list -> order:int option list -> Value.t option list

val invoke :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  Typed.signature ->
  list_result:bool ->
  supplied:Value.t option list ->
  branch:Branch.t ->
  Branch.t * Value.t

val mutator_arguments :
  at:Common.Location.t ->
  Typed.signature ->
  Syntax.expr list ->
  keywords:(string * Syntax.expr) list ->
  Syntax.expr list * int option list

val mutate :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  Typed.signature ->
  order:int option list ->
  (Branch.t * Value.t list) list ->
  Branch.t list

(** Returns the sequence argument, the mutator's signature and the mutator's
    operation type. *)
val local_helper_arguments :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  Syntax.expr list ->
  Syntax.expr * Typed.signature * string

val local_helper :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  mutator:Typed.signature ->
  operation:string ->
  branch:Branch.t ->
  Value.t ->
  Branch.t

val aggregate_pubkeys :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t
