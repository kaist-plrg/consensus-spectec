(* Common types and utilities for dependency analysis. *)

module Il = Lang.Il

(* === Types === *)

type input_source = State | Block
type field_step = FieldAccess of string | IndexAccess of int
type field_path = { source : input_source; steps : field_step list }

(* === Centralized Whitelist === *)

val eth_whitelist : string list
val is_whitelisted : string -> bool

(* === String Formatting === *)

val string_of_input_source : input_source -> string
val string_of_field_step : field_step -> string
val string_of_field_path : field_path -> string

(* === Input origins === *)

val origin_of_input_source : input_source -> Instrumentation_api.Origin.t
val field_path_of_origin_opt : Instrumentation_api.Origin.t -> field_path option

(* === Readsets: provenance rules for the spec's generic list helpers === *)

module StringMap : Map.S with type key = string

(* Field chains a predicate reads, per component of its element parameter *)
type readset = field_step list list array

val readset_of_clauses : Il.clause list -> readset
val readsets_of_spec : Il.spec -> readset StringMap.t

val call_provenance :
  lookup:(string -> readset option) ->
  string ->
  Il.Value.t list ->
  Instrumentation_api.Origin.t list
