(* A side table of value provenance keyed by vid. [handle_value] records
   entries from value events. [add_readset] adds the origins of fields named
   by a readset. *)

open Common.Annotated
module Il = Lang.Il

(* === Side table === *)

let table : (Il.vid, Il.json_provenance list) Hashtbl.t = Hashtbl.create 4096
let clear () = Hashtbl.reset table

let lookup (vid : Il.vid) : Il.json_provenance list =
  match Hashtbl.find_opt table vid with Some provs -> provs | None -> []

let provenance_of (v : Il.Value.t) : Il.json_provenance list = lookup v.note.vid

let merged_of (values : Il.Value.t list) : Il.json_provenance list =
  values
  |> List.concat_map (fun (v : Il.Value.t) -> lookup v.note.vid)
  |> List.sort_uniq compare

let add_readset (result : Il.Value.t) (provs : Il.json_provenance list) : unit =
  if provs <> [] then
    let merged = List.sort_uniq compare (lookup result.note.vid @ provs) in
    Hashtbl.replace table result.note.vid merged

(* === Value events === *)

let record_decoded ~(prov : Il.json_provenance) (v : Il.Value.t) : unit =
  Hashtbl.replace table v.note.vid [ prov ]

let record_derived ~(source : Il.Value.t) (result : Il.Value.t) : unit =
  match lookup source.note.vid with
  | [] -> ()
  | provs -> Hashtbl.replace table result.note.vid provs

(* A list or option takes the provenance of the other values it was computed
   from, such as the lists an iteration ranges over, but not of its elements,
   which keep their own. *)
let record_combined ~(sources : Il.Value.t list) (result : Il.Value.t) : unit =
  let elements =
    match result.it with
    | Il.ListV values -> values
    | Il.OptV value_opt -> Option.to_list value_opt
    | _ -> []
  in
  let element_vids = Hashtbl.create (List.length elements) in
  List.iter
    (fun (element : Il.Value.t) ->
      Hashtbl.replace element_vids element.note.vid ())
    elements;
  let sources =
    List.filter
      (fun (source : Il.Value.t) ->
        not (Hashtbl.mem element_vids source.note.vid))
      sources
  in
  match merged_of sources with
  | [] -> ()
  | deduped -> Hashtbl.replace table result.note.vid deduped

let record_updated ~(base : Il.Value.t) (result : Il.Value.t) : unit =
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
  match struct_provs with
  | [] -> ()
  | _ -> Hashtbl.replace table result.note.vid struct_provs

(* A call's output with no entry of its own, such as one built by a builtin, a
   literal or a constructor expression, takes the union of the call's inputs'
   provenance. *)
let record_invoked ~(inputs : Il.Value.t list) (result : Il.Value.t) : unit =
  if lookup result.note.vid = [] then
    match merged_of inputs with
    | [] -> ()
    | deduped -> Hashtbl.replace table result.note.vid deduped

let handle_value : Instrumentation_api.Value_event.t -> unit = function
  | Decoded { value; origin } -> (
      let source =
        match origin.label with
        | "state" -> Some Il.JsonState
        | "block" -> Some Il.JsonBlock
        | _ -> None
      in
      let path =
        List.map
          (function
            | Instrumentation_api.Origin.Struct atom ->
                Il.FieldAccess
                  (Lang.Xl.Atom.to_string atom |> String.lowercase_ascii)
            | List index -> Il.IndexAccess index)
          origin.path
      in
      match source with
      | Some source -> record_decoded ~prov:(source, path) value
      | None -> ())
  | Derived { value; source } -> record_derived ~source value
  (* A constructed value gets no entry of its own, so a mutation target names
     the field a premise reads, not the whole value. *)
  | Constructed _ -> ()
  | Combined { value; sources } -> record_combined ~sources value
  | Updated { value; base; _ } -> record_updated ~base value
  | Invoked { inputs; outputs; _ } -> List.iter (record_invoked ~inputs) outputs
