open Common.Annotated
open Lang.El
open Value

module Registry = struct
  open Common.Domain

  type t = { mutable reversed : spec; mutable functions : FIdSet.t }

  let make () = { reversed = []; functions = FIdSet.empty }

  let index registry definition =
    match definition.it with
    | DecD (name, _, _, _, _) ->
        registry.functions <- FIdSet.add name registry.functions
    | _ -> ()

  let emit registry definitions =
    registry.reversed <- List.rev_append definitions registry.reversed;
    List.iter (index registry) definitions

  let register registry ~name ~generate =
    if not (FIdSet.mem (name $ Common.Location.Unknown) registry.functions) then
      emit registry (generate ())

  let definitions registry = List.rev registry.reversed
end

type t = {
  source : Typed.source;
  list_results : string list;
  mutable next : int;
  mutable reserved : string list;
  registry : Registry.t;
  declarations : (string * def) list;
}

let make source ~list_results ~registry ~reserved ~declarations =
  { source; list_results; next = 0; reserved; registry; declarations }

let source ctx = ctx.source
let list_results ctx = ctx.list_results
let declarations ctx = ctx.declarations
let types ctx = ctx.source.types

let fresh ?hint ctx ~at ~kind =
  let typ = Value.plaintyp_of_kind ~types:ctx.source.types ~at kind in
  let rec prefix typ =
    match typ.it with
    | IterT (typ, _) -> prefix typ
    | VarT (name, []) -> name.it
    | BoolT -> "bool"
    | NumT `IntT -> "int"
    | NumT `NatT -> "nat"
    | _ -> Error.reject ~at "Unsupported fresh-variable type"
  in
  let rec allocate typ () =
    let name =
      Option.value hint ~default:(prefix typ)
      ^ "_translated" ^ string_of_int ctx.next
    in
    ctx.next <- ctx.next + 1;
    if List.mem name ctx.reserved then allocate typ ()
    else (
      ctx.reserved <- name :: ctx.reserved;
      name)
  in
  let rec expression typ =
    match typ.it with
    | IterT (element, iter) -> IterE (expression element, iter) $ at
    | TupleT elements -> TupleE (List.map expression elements) $ at
    | _ -> var ~at (allocate typ ())
  in
  { exp = expression typ; kind }

let fresh_helper_name ctx ~operation =
  let n = ctx.next in
  ctx.next <- n + 1;
  "translated_" ^ ctx.source.signature.name ^ "_" ^ operation ^ string_of_int n

let share_helper ctx ~name ~definitions =
  Registry.register ctx.registry ~name ~generate:definitions

let emit_helper ctx ~definitions = Registry.emit ctx.registry definitions
