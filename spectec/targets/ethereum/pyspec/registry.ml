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

let declared_type ~name registry = TIdSet.mem (name $ no_region) registry.types

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
