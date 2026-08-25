(* Implements the value-event hooks over a vid-keyed side table. Each hook
   records a produced value's provenance keyed by its vid, reading its sources
   from the table via [lookup]. The dependency analysis reads back through
   [provenance_of]. The table is cleared per test. *)

open Common.Source
module Il = Lang.Il

(* === Side table === *)

let table : (Il.vid, Il.json_provenance list) Hashtbl.t = Hashtbl.create 4096
let clear () = Hashtbl.reset table

let lookup (vid : Il.vid) : Il.json_provenance list =
  match Hashtbl.find_opt table vid with Some provs -> provs | None -> []

(* === Hooks === *)

let on_created (prov : Il.json_provenance) (v : Il.Value.t) : Il.Value.t =
  Hashtbl.replace table v.note.vid [ prov ];
  v

let on_derived ~(source : Il.Value.t) (result : Il.Value.t) : Il.Value.t =
  (match lookup source.note.vid with
  | [] -> ()
  | provs -> Hashtbl.replace table result.note.vid provs);
  result

let merged_of (values : Il.Value.t list) : Il.json_provenance list =
  values
  |> List.concat_map (fun (v : Il.Value.t) -> lookup v.note.vid)
  |> List.sort_uniq compare

let on_combined ~(sources : Il.Value.t list) (result : Il.Value.t) : Il.Value.t
    =
  (match merged_of sources with
  | [] -> ()
  | deduped -> Hashtbl.replace table result.note.vid deduped);
  result

let on_field_updated ~(base : Il.Value.t) (result : Il.Value.t) : Il.Value.t =
  let struct_provs = lookup base.note.vid in
  (match result.it with
  | Il.StructV fields ->
      List.iter
        (fun (atom, (value_f : Il.Value.t)) ->
          if lookup value_f.note.vid = [] && struct_provs <> [] then
            let field_name =
              Lang.Xl.Atom.to_string atom.it |> String.lowercase_ascii
            in
            let field_provs =
              List.map
                (fun (src, steps) ->
                  (src, steps @ [ Il.FieldAccess field_name ]))
                struct_provs
            in
            Hashtbl.replace table value_f.note.vid field_provs)
        fields
  | _ -> ());
  (match struct_provs with
  | [] -> ()
  | _ -> Hashtbl.replace table result.note.vid struct_provs);
  result

(* Fallback for builtins with empty output provenance: union the inputs'
   provenance when the result carries none of its own. *)
let on_invoke_fallback ~(inputs : Il.Value.t list) (result : Il.Value.t) :
    Il.Value.t =
  (if lookup result.note.vid = [] then
     match merged_of inputs with
     | [] -> ()
     | deduped -> Hashtbl.replace table result.note.vid deduped);
  result

let hooks : Instrumentation_core.Value_hooks.t =
  { on_created; on_derived; on_combined; on_field_updated; on_invoke_fallback }

(* Union readset provenance (from on_func_result) into the result's entry. *)
let add_readset (result : Il.Value.t) (provs : Il.json_provenance list) : unit =
  if provs <> [] then
    let merged = List.sort_uniq compare (lookup result.note.vid @ provs) in
    Hashtbl.replace table result.note.vid merged

(* === Consumer read === *)

let provenance_of (v : Il.Value.t) : Il.json_provenance list = lookup v.note.vid

(* === Lifecycle === *)

module Handler : Instrumentation_api.Handler.S = struct
  let static_dependencies = []
  let init ~spec:_ = ()

  let handle = function
    | Instrumentation_api.Event.Test_start _ -> clear ()
    | _ -> ()

  let finish () = ()
end
