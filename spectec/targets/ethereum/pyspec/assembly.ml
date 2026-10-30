open Common.Source
open Lang.El

module Registry = struct
  open Common.Source
  open Common.Domain
  open Lang.El

  type ownership = Shared | Source of string | Helper of string
  type group = { ownership : ownership; definitions : spec }

  type t = {
    mutable groups : group list;
    mutable functions : FIdSet.t;
    mutable builtins : FIdSet.t;
    mutable types : TIdSet.t;
  }

  let make () =
    {
      groups = [];
      functions = FIdSet.empty;
      builtins = FIdSet.empty;
      types = TIdSet.empty;
    }

  let declared_function ?(builtin = false) ~name registry =
    let name = name $ no_region in
    FIdSet.mem name registry.functions
    || (builtin && FIdSet.mem name registry.builtins)

  let declared_type ~name registry =
    TIdSet.mem (name $ no_region) registry.types

  let index registry definition =
    match definition.it with
    | DecD (name, _, _, _, _) ->
        registry.functions <- FIdSet.add name registry.functions
    | BuiltinDecD (name, _, _, _, _) ->
        registry.builtins <- FIdSet.add name registry.builtins
    | TypD (name, _, _, _) -> registry.types <- TIdSet.add name registry.types
    | _ -> ()

  let emit ~registry ~ownership definitions =
    registry.groups <- { ownership; definitions } :: registry.groups;
    List.iter (index registry) definitions

  let register registry ~ownership ~name ~generate =
    if not (declared_function ~name registry) then
      emit ~registry ~ownership (generate ())

  let groups registry = List.rev registry.groups
  let ownership group = group.ownership
  let definitions group = group.definitions
  let contents (groups : group list) = List.concat_map definitions groups
end

module TextSet = Set.Make (String)

type symbol = Function of string | Relation of string | Type of string

type t = {
  definitions : spec;
  sources : symbol list;
  shared_declarations : spec;
}

let is_declaration definition =
  match definition.it with
  | TypD _ | RelD _ | DecD _ | BuiltinDecD _ -> true
  | _ -> false

let symbol definition =
  match definition.it with
  | RelD (name, _, _) | RuleD (name, _, _, _) -> Some (Relation name.it)
  | BuiltinDecD (name, _, _, _, _)
  | DecD (name, _, _, _, _)
  | DefD (name, _, _, _, _) ->
      Some (Function name.it)
  | TypD (name, _, _, _) -> Some (Type name.it)
  | _ -> None

let assemble groups =
  let _, reversed =
    List.fold_left
      (fun (seen, reversed) group ->
        List.fold_left
          (fun (seen, reversed) definition ->
            let shared =
              match Registry.ownership group with
              | Registry.Shared -> true
              | Registry.Source _ | Registry.Helper _ -> false
            in
            if not shared then (seen, definition :: reversed)
            else
              let printed = Lang.El.Unparse.string_of_def definition in
              if TextSet.mem printed seen then (seen, reversed)
              else (TextSet.add printed seen, definition :: reversed))
          (seen, reversed)
          (Registry.definitions group))
      (TextSet.empty, []) groups
  in
  let declarations, bodies =
    List.rev reversed |> List.partition is_declaration
  in
  let sources =
    groups
    |> List.filter (fun group ->
           match Registry.ownership group with
           | Registry.Source _ -> true
           | _ -> false)
    |> Registry.contents |> List.filter_map symbol
    |> List.sort_uniq Stdlib.compare
  in
  let shared_declarations =
    groups
    |> List.filter (fun group -> Registry.ownership group = Registry.Shared)
    |> Registry.contents
    |> List.filter (fun definition ->
           match definition.it with
           | BuiltinDecD _ | TypD _ -> true
           | _ -> false)
  in
  { definitions = declarations @ bodies; sources; shared_declarations }

let definitions (bundle : t) = bundle.definitions

let replace ~context (bundle : t) =
  let entries =
    List.filter
      (fun entry ->
        List.exists (fun definition -> symbol definition = Some entry) context)
      bundle.sources
  in
  let names = List.filter_map symbol bundle.definitions in
  let reused definition =
    List.exists (Lang.El.Eq.eq_def definition) bundle.shared_declarations
  in
  List.iter
    (fun definition ->
      match symbol definition with
      | Some key
        when List.mem key names
             && (not (List.mem key entries))
             && not (reused definition) ->
          let name = match key with Function n | Relation n | Type n -> n in
          Error.reject ~at:definition.at
            ("Generated helper name collision: " ^ name)
      | _ -> ())
    context;
  let existing_shared = List.filter reused context in
  let definitions =
    List.filter
      (fun definition ->
        not (List.exists (Lang.El.Eq.eq_def definition) existing_shared))
      bundle.definitions
  in
  let declarations, bodies = List.partition is_declaration definitions in
  let rec insert inserted = function
    | [] -> if inserted then [] else declarations
    | definition :: rest -> (
        match symbol definition with
        | Some name when List.mem name entries ->
            (if inserted then [] else declarations) @ insert true rest
        | _ -> definition :: insert inserted rest)
  in
  let replaced = insert false context @ bodies in
  if entries = [] then
    Error.reject ~at:no_region "Context has no source declaration to replace";
  replaced

let compile ~context bundle =
  Result.map
    (fun il -> (il, Spectec.structure il))
    (Spectec.elaborate (replace ~context bundle))
