type 'value step = Field of string | Element of 'value
type 'value location = 'value step list

type 'value reference = {
  location : 'value location option;
  iterator_parent : string option;
  identity : string;
  valid : bool;
}

type 'value t = {
  bindings : (string * 'value) list;
  references : (string * 'value reference) list;
  reads : (string * 'value) list;
  origins : (string * 'value location) list;
}

let make bindings = { bindings; references = []; reads = []; origins = [] }
let bindings storage = storage.bindings
let references storage = storage.references

let replace_value ~name ~value storage =
  {
    storage with
    bindings = (name, value) :: List.remove_assoc name storage.bindings;
  }

let bind_local ~name ~value ~reference storage =
  let references = List.remove_assoc name storage.references in
  let references =
    match reference with
    | None -> references
    | Some reference -> (name, reference) :: references
  in
  { (replace_value ~name ~value storage) with references }

let update_aliases ~identity ~value storage =
  let bindings =
    List.map
      (fun (name, previous) ->
        match List.assoc_opt name storage.references with
        | Some reference when reference.identity = identity -> (name, value)
        | _ -> (name, previous))
      storage.bindings
  in
  { storage with bindings }

let owned identity =
  { location = None; iterator_parent = None; identity; valid = true }

let state_view ~identity location =
  { location = Some location; iterator_parent = None; identity; valid = true }

let iterator_view identity ~field ~index ~parent =
  {
    location = Some [ Field field; Element index ];
    iterator_parent = Some parent;
    identity;
    valid = true;
  }

let read ~key storage = List.assoc_opt key storage.reads

let cache_read ~key ~value storage =
  { storage with reads = (key, value) :: storage.reads }

let origin ~key storage = List.assoc_opt key storage.origins

let remember_origin ~key ~location storage =
  { storage with origins = (key, location) :: storage.origins }

let overlaps left right =
  match (left, right) with Field l :: _, Field r :: _ -> l = r | _ -> true

let invalidate ?identity location storage =
  let references =
    List.map
      (fun (name, reference) ->
        ( name,
          if
            Some reference.identity = identity
            || reference.iterator_parent <> None
          then reference
          else if
            Option.fold ~none:false ~some:(overlaps location) reference.location
          then { reference with valid = false }
          else reference ))
      storage.references
  in
  { storage with origins = []; reads = []; references }

let write_state ?identity ~location ~value storage =
  invalidate ?identity location (replace_value ~name:"state" ~value storage)

let loop_results ~values storage =
  let storage =
    List.fold_left
      (fun storage (name, value) -> replace_value ~name ~value storage)
      storage values
  in
  if List.mem_assoc "state" values then invalidate [] storage else storage

let enter_helper storage = make storage.bindings

let enter_while storage =
  {
    (make storage.bindings) with
    references =
      List.filter
        (fun (_, reference) -> reference.location = None)
        storage.references;
  }

let enter_for ~carried ~iterated storage =
  let references =
    List.filter_map
      (fun (name, reference) ->
        if reference.location <> None then
          if List.mem name carried then Some (name, reference) else None
        else
          Some
            ( name,
              if List.mem reference.identity iterated then
                { reference with valid = false }
              else reference ))
      storage.references
  in
  { (make storage.bindings) with references }
