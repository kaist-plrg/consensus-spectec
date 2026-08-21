(* Value-event hooks: an observer seam over value production. The interpreter
   emits one at each value-production site, defaulting to noop. A handler keeps
   provenance off the value type, in its own vid-keyed side table.

   - on_created: value from external input (the JSON seed).
   - on_derived: 1:1 transform (cast, length, index update, destructure).
   - on_combined: N:1 combination (binop, concat, iteration).
   - on_field_updated: record with one field replaced.
   - on_invoke_fallback: function or relation output fallback. *)

module Il = Lang.Il

type value = Il.Value.t
type json_provenance = Il.json_provenance

type t = {
  on_created : json_provenance -> value -> value;
  on_derived : source:value -> value -> value;
  on_combined : sources:value list -> value -> value;
  on_field_updated : base:value -> value -> value;
  on_invoke_fallback : inputs:value list -> value -> value;
}

let noop : t =
  {
    on_created = (fun _ v -> v);
    on_derived = (fun ~source:_ v -> v);
    on_combined = (fun ~sources:_ v -> v);
    on_field_updated = (fun ~base:_ v -> v);
    on_invoke_fallback = (fun ~inputs:_ v -> v);
  }

(* Active hooks, installed by config only under dependency analysis. *)
let current : t ref = ref noop
let set (hooks : t) = current := hooks
let reset () = current := noop

(* Emit wrappers for the production sites. Each returns its value unchanged. *)
let on_created prov v = !current.on_created prov v
let on_derived ~source v = !current.on_derived ~source v
let on_combined ~sources v = !current.on_combined ~sources v
let on_field_updated ~base v = !current.on_field_updated ~base v
let on_invoke_fallback ~inputs v = !current.on_invoke_fallback ~inputs v
