(** One execution branch of the function being translated. Each finished branch
    becomes one clause. *)
type t = private {
  storage : Store.t;
  premises : Lang.El.prem list;
  (* Head pattern for an optional parameter whose presence this branch has
     decided: eps when absent, the plain variable when present. *)
  options : (string * Lang.El.exp) list;
  (* Loop results whose Python number class depends on whether the body ran,
     keyed by rendered expression. A matching unsigned operand coerces the
     plain-integer and unsigned cases alike. *)
  promoted : (string * Value.kind) list;
  (* Nested source helpers this branch has executed the definition of. A
     branch that never reached a definition cannot call it. *)
  local_helpers : (string * Syntax.local_helper) list;
}

val make : Store.t -> t
val map_storage : f:(Store.t -> Store.t) -> t -> t
val decide_option : name:string -> pattern:Lang.El.exp -> t -> t
val promote : promoted:(string * Value.kind) list -> t -> t
val add_local_helper : Syntax.local_helper -> t -> t

(** Premises are kept once each, in the order first required. *)
val require : prem:Lang.El.prem -> t -> t

val guard : at:Common.Location.t -> exp:Lang.El.exp -> t -> t

val guard_boolean_condition :
  at:Common.Location.t -> holds:bool -> exp:Lang.El.exp -> t -> t

val has_condition : t -> condition:Lang.El.exp -> bool

(** Binds a fresh variable equal to the value and returns the variable. *)
val bind :
  ?hint:string ->
  ctx:Ctx.t ->
  at:Common.Location.t ->
  t ->
  term:Value.t ->
  t * Value.t

val replace_local : name:string -> value:Value.t -> t -> t
val update_aliases : identity:string -> value:Value.t -> t -> t
val origin : t -> value:Value.t -> Store.location option

val remember_origin :
  t -> base:Value.t -> step:Store.step -> value:Value.t -> t * Value.t

val write_state :
  ?identity:string -> location:Store.location -> value:Value.t -> t -> t

(** Rejects a helper that would capture a loop result whose Python number class
    depends on whether the loop body ran. *)
val check_promoted_capture : at:Common.Location.t -> t -> unit
