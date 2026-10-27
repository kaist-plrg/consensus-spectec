open Common.Source

(** One execution branch of the function being translated. Each finished branch
    becomes one clause. *)
type t = {
  storage : Operand.t Store.t;
  premises : Lang.El.prem list;
  (* Head pattern for an optional parameter whose presence this branch has
     decided: eps when absent, the plain variable when present. *)
  options : (string * Lang.El.exp) list;
  (* Loop results whose Python value is an unsigned width when the loop body
     ran and a plain integer when it did not, keyed by rendered expression.
     The two agree only where an unsigned operand of that width coerces them
     the same way. *)
  promoted : (string * Kind.t) list;
  (* Nested source helpers this branch has executed the definition of. A
     branch that never reached a definition cannot call it. *)
  local_helpers : (string * Syntax.local_helper) list;
}

val make : Operand.t Store.t -> t

(** Premises are kept once each, in the order first required. *)
val require : prem:Lang.El.prem -> t -> t

val guard : at:region -> exp:Lang.El.exp -> t -> t

val guard_boolean_condition :
  at:region -> holds:bool -> exp:Lang.El.exp -> t -> t

val has_condition : t -> condition:Lang.El.exp -> bool

(** Binds a fresh variable equal to the value and returns the variable. *)
val bind :
  ?hint:string -> ctx:Ctx.t -> at:region -> t -> term:Operand.t -> t * Operand.t

val replace_local : name:string -> value:Operand.t -> t -> t
val update_aliases : identity:string -> value:Operand.t -> t -> t
val origin : t -> value:Operand.t -> Operand.t Store.location option

val remember_origin :
  t ->
  base:Operand.t ->
  step:Operand.t Store.step ->
  value:Operand.t ->
  t * Operand.t

val write_state :
  ?identity:string ->
  location:Operand.t Store.location ->
  value:Operand.t ->
  t ->
  t

(** Rejects a generated helper that would capture an accumulated loop result
    whose Python class is still unsettled. *)
val check_promoted_capture : at:region -> t -> unit
