open Common.Source
open Source

type t = { documents : Source.t list; list_results : string list }

let consistent key entries message sources =
  let seen = ref [] in
  List.iter
    (fun source ->
      List.iter
        (fun entry ->
          let name = key entry in
          match List.assoc_opt name !seen with
          | None -> seen := (name, entry) :: !seen
          | Some previous when previous = entry -> ()
          | Some _ -> Error.reject ~at:no_region (message ^ name))
        (entries source))
    sources

let make sources =
  if sources = [] then Error.reject ~at:no_region "Empty source bundle";
  let names = List.map (fun source -> source.signature.name) sources in
  if List.length names <> List.length (List.sort_uniq String.compare names) then
    Error.reject ~at:no_region "Duplicate source function";
  consistent
    (fun (helper : sequence_helper) -> helper.name)
    (fun source -> source.sequence_helpers)
    "Conflicting generic helper: " sources;
  consistent
    (fun (signature : signature) -> signature.name)
    (fun source -> source.calls)
    "Conflicting bundle signature: " sources;
  { documents = sources; list_results = List_results.infer sources }

let documents bundle = bundle.documents
let list_results bundle = bundle.list_results
