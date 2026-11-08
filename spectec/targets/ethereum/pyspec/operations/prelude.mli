open Lang.El

(** The Ethereum target's builtins that generated definitions call.
    [prelude.spectec] declares every builtin these builders call. BLS primitives
    and the external engine's new-payload check are translated here. [Call]
    handles [bls.AggregatePKs], which needs a recursive sequence helper. *)

val invoke_primitive :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  Library.primitive_contract ->
  branch:Branch.t ->
  values:Value.t list ->
  Branch.t * Value.t

val notify_new_payload :
  ctx:Ctx.t ->
  at:Common.Location.t ->
  branch:Branch.t ->
  Value.t ->
  Branch.t * Value.t

val bytes_get : at:Common.Location.t -> exp -> index:exp -> exp
val bytes_valid : at:Common.Location.t -> exp -> exp
val bytes_length : at:Common.Location.t -> exp -> exp
val bytes_slice : at:Common.Location.t -> exp -> start:exp -> count:exp -> exp
val fixed_bytes : at:Common.Location.t -> exp -> width:exp -> exp
val concat_bytes : at:Common.Location.t -> exp -> right:exp -> exp
val hash : at:Common.Location.t -> exp -> exp

(** Serializes an unsigned integer of the given bit width, little-endian. *)
val uint_to_bytes : at:Common.Location.t -> width:int -> exp -> exp

(** Converts a fixed-width byte value of the given byte width to [bytes]. *)
val bytes_of_fixed : at:Common.Location.t -> width:Bigint.t -> exp -> exp

val bytes32_to_bytes : at:Common.Location.t -> exp -> exp
val aggregate_pubkeys : at:Common.Location.t -> exp -> exp

(** The builtin that hashes a kind's SSZ tree. The generic builtin takes the
    input's type as an argument. *)
type hasher = Generic | Specific of string

(** Selects the hashing builtin for a kind. *)
val hasher_of_kind : ctx:Ctx.t -> at:Common.Location.t -> Value.kind -> hasher

val hash_tree_root :
  at:Common.Location.t ->
  hasher:hasher ->
  type_argument:(unit -> targ) ->
  exp ->
  exp

(** Source types the generic SSZ hashing builtin accepts. *)
val accepts_polymorphic_hash_input : string -> bool
