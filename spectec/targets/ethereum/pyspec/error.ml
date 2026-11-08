exception Rejected of Common.Location.t * string

let reject ~at message = raise (Rejected (at, message))

let find_or_reject ~at ~name entries =
  match List.assoc_opt name entries with
  | Some x -> x
  | None -> reject ~at ("Unresolved name: " ^ name)

let check_distinct ~at ~message names =
  if List.length names <> List.length (List.sort_uniq String.compare names) then
    reject ~at message
