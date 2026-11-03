(** JSON type descriptors and values for {!Ssz}.

    A type expression is one of
    - ["uint8"] ... ["uint256"], ["boolean"], ["progressive_bitlist"]
    - a type name defined in the same schema
    - [{"vector": [T, N]}], [{"list": [T, N]}], [{"bitvector": N}],
      [{"bitlist": N}], [{"progressive_list": T}]
    - [{"container": [[name, T], ...]}]
    - [{"progressive_container": {"active_fields": [1, 0, 1], "fields": [[name,
       T], ...]}}]
    - [{"compatible_union": [[selector, T], ...]}]

    A schema is an object whose ["types"] member maps names to type expressions;
    other members are ignored, so tools can keep their own data alongside. *)

type t

(** Resolves every name; fails on unknown or cyclic references. *)
val of_json : Yojson.Safe.t -> (t, string) result

(** [of_json] on a file. *)
val load : string -> (t, string) result

val find : t -> string -> Ssz.typ option
val names : t -> string list

(** A type expression that may refer to names in [t]. *)
val typ_of_json : t -> Yojson.Safe.t -> (Ssz.typ, string) result

(** Values in the consensus-spec-tests YAML convention, as JSON: uints as
    numbers or decimal strings, byte sequences as 0x-hex, bitvectors and
    bitlists as 0x-hex serialized bits (bitlists with the delimiter bit),
    containers as objects keyed by field name, compatible unions as
    [{"selector": n, "data": v}]. *)
val value_of_json : Ssz.typ -> Yojson.Safe.t -> (Ssz.value, string) result
