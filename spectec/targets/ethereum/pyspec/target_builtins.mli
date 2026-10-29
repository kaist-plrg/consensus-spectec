open Common.Source
open Lang.El

(** The Ethereum target's builtins that generated definitions call.

    [declare] declares a builtin once per translation, as a declaration shared
    by every generated definition. Helpers written as SpecTec text declare the
    builtins their text calls. *)
val declare : ctx:Ctx.t -> at:region -> string -> unit

(** Each builder below declares its builtin and returns the call. *)

val bytes_get : ctx:Ctx.t -> at:region -> exp -> index:exp -> exp
val bytes_valid : ctx:Ctx.t -> at:region -> exp -> exp
val bytes_length : ctx:Ctx.t -> at:region -> exp -> exp
val bytes_slice : ctx:Ctx.t -> at:region -> exp -> start:exp -> count:exp -> exp
val fixed_bytes : ctx:Ctx.t -> at:region -> exp -> width:exp -> exp
val concat_bytes : ctx:Ctx.t -> at:region -> exp -> right:exp -> exp
val hash : ctx:Ctx.t -> at:region -> exp -> exp

(** Serializes an unsigned integer of the given bit width, little-endian. *)
val uint_to_bytes : ctx:Ctx.t -> at:region -> width:int -> exp -> exp

(** Converts a fixed-width byte value of the given byte width to [bytes]. *)
val to_bytes : ctx:Ctx.t -> at:region -> width:Bigint.t -> exp -> exp

val bytes32_to_bytes : ctx:Ctx.t -> at:region -> exp -> exp
val notify_new_payload : ctx:Ctx.t -> at:region -> exp -> exp
val aggregate_pubkeys : ctx:Ctx.t -> at:region -> exp -> exp

(** The builtin that hashes a kind's SSZ tree. The generic builtin takes the
    input's type as an argument. *)
type root = Generic | Specific of string

(** Selects and declares the hashing builtin for a kind. *)
val hash_tree_root_builtin : ctx:Ctx.t -> at:region -> Kind.t -> root

val hash_tree_root :
  at:region -> root:root -> type_argument:(unit -> targ) -> exp -> exp

(** Source types the generic SSZ hashing builtin accepts. *)
val accepts_polymorphic_hash_input : string -> bool

(** Declares the unit type that models the external execution engine. *)
val declare_execution_engine : ctx:Ctx.t -> at:region -> unit
