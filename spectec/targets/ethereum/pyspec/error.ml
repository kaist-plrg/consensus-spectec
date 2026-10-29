open Common.Source

exception Rejected of region * string

let reject ~at message = raise (Rejected (at, message))

let to_string ~at message =
  if at = no_region then message else string_of_region at ^ " " ^ message

let find_or_reject ~at ~name entries =
  match List.assoc_opt name entries with
  | Some x -> x
  | None -> reject ~at ("Unresolved name: " ^ name)
