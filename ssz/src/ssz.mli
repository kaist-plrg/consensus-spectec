(** SSZ [hash_tree_root].

    Types and values follow the SSZ specification directly. Serialization is out
    of scope. *)

type typ =
  | Uint of int  (** byte width: 1, 2, 4, 8, 16 or 32 *)
  | Boolean
  | Vector of typ * int
  | List of typ * int  (** element type, limit *)
  | Bitvector of int
  | Bitlist of int  (** limit *)
  | Container of (string * typ) list
  | Progressive_list of typ  (** EIP-7916 *)
  | Progressive_bitlist  (** EIP-7916 *)
  | Progressive_container of {
      active_fields : bool list;
      fields : (string * typ) list;
    }  (** EIP-7495. [fields] holds the active positions only, in order. *)
  | Compatible_union of (int * typ) list
      (** EIP-8016: selector (1..127), option *)

type value =
  | Uint of string  (** little-endian, exactly the type's byte width *)
  | Bool of bool
  | Bytes of string
      (** Serialized elements of a vector or list of a basic type, concatenated:
          the usual form for byte vectors and byte lists. *)
  | Seq of value list  (** vector or list elements *)
  | Bits of bool list  (** bitvector or bitlist, without delimiter bit *)
  | Fields of value list
      (** container fields by position (active fields only) *)
  | Union of int * value  (** selector, data *)

(** The 32-byte root, or an error naming the first mismatch between type and
    value. *)
val hash_tree_root : typ -> value -> (string, string) result

(** @raise Invalid_argument on a type/value mismatch. *)
val hash_tree_root_exn : typ -> value -> string

(** {1 Value helpers} *)

(** Reads the argument as unsigned. *)
val uint64 : int64 -> value

(** @raise Invalid_argument if negative. *)
val uint_of_int : size:int -> int -> value

(** {1 Merkleization primitives} *)

(** Root of a zero tree of the given depth. *)
val zero_hash : int -> string

(** @raise Invalid_argument if more chunks than [limit]. *)
val merkleize : ?limit:int -> string list -> string

val merkleize_progressive : string list -> string
val mix_in_length : string -> int -> string
