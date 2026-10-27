open Common.Source
open Lang.El
open Operand

type t = {
  source : Source.t;
  list_results : string list;
  mutable next : int;
  mutable reserved : string list;
  registry : Registry.t;
  declarations : (string * def) list;
}

let make source ~list_results ~reserved ~declarations =
  {
    source;
    list_results;
    next = 0;
    reserved;
    registry = Registry.make ();
    declarations;
  }

let for_helper ctx ~source = { ctx with source; next = 0; reserved = [] }
let types ctx = ctx.source.types

let fresh ?hint ctx ~at ~kind =
  let typ = Operand.typ ~types:ctx.source.types ~at kind in
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
  Registry.register ctx.registry ~ownership:Shared ~name ~generate:definitions

let share_helper_text ctx ~at ~name ~operation ~text =
  share_helper ctx ~name ~definitions:(fun () ->
      match
        Spectec.parse_spec_source
          { filename = "<" ^ operation ^ ">"; contents = text }
      with
      | Ok definitions -> definitions
      | Error _ -> Error.reject ~at ("Invalid generated helper: " ^ name))

let emit_helper ctx ~definitions =
  Registry.emit ~registry:ctx.registry
    ~ownership:(Helper ctx.source.signature.name) definitions
