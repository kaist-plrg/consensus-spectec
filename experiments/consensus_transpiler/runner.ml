module V = Lang.Il.Value
module D = Spectec.Diagnostic
open Common.Source

module Pure_target : Interp.Target.S = struct
  let builtins = []
  let is_impure_func _ = false
  let is_impure_rel _ = false
  let state_version = ref 0

  let with_state f =
    let next = ref 0 in
    V.GlobalVidProvider.with_provider
      (fun () ->
        let value = !next in
        incr next;
        value)
      f
end

let diagnostics bag = D.Render.render_bag ~ansi:D.Ansi.plain bag

let value = function
  | `Bool b -> V.bool b
  | `String n -> V.int (Bigint.of_string n)
  | _ -> failwith "Expected a boolean or a decimal integer string"

let rec defaults (tdenv : Envs.Il.TDEnv.t) typ json =
  let open Lang.Il in
  match typ with
  | VarT { synid; targs = [] } -> (
      match Envs.Il.TDEnv.find synid tdenv with
      | _, { it = PlainT typ; _ } -> defaults tdenv typ.it json
      | _, { it = StructT fields; _ } ->
          let given =
            match json with
            | `Assoc fields -> fields
            | `Null -> []
            | _ -> failwith "Expected record"
          in
          `Assoc
            (List.map
               (fun (atom, typ) ->
                 let key = Lang.Xl.Atom.to_string atom.it in
                 let input =
                   List.find_opt
                     (fun (name, _) ->
                       String.lowercase_ascii name = String.lowercase_ascii key)
                     given
                 in
                 ( key,
                   defaults tdenv typ.it
                     (match input with
                     | Some (_, input) -> input
                     | None -> `Null) ))
               fields)
      | _ -> failwith "Unsupported fixture type")
  | IterT { typ; iter = List } ->
      let values =
        match json with
        | `List values -> values
        | `Assoc [ ("repeat", `Int count); ("value", value) ] ->
            List.init count (fun _ -> value)
        | `Null -> []
        | _ -> failwith "Expected list"
      in
      `List (List.map (defaults tdenv typ.it) values)
  | BoolT -> if json = `Null then `Bool false else json
  | NumT `NatT -> (
      match json with
      | `Null -> `Intlit "0"
      | `String n when not (String.starts_with ~prefix:"0x" n) -> `Intlit n
      | _ -> json)
  | NumT `IntT -> (
      match json with
      | `Null -> `String "0"
      | `Int n -> `String (string_of_int n)
      | _ -> json)
  | _ -> failwith "Unsupported fixture type"

let typed_value tdenv json =
  let open Common.Source in
  let open Yojson.Safe.Util in
  let name = json |> member "type" |> to_string in
  let typ = Lang.Il.Typ.var name [] in
  let data = defaults tdenv typ (member "value" json) in
  match Json.Parse.json_to_value tdenv typ data with
  | Ok value -> value
  | Error error -> failwith (Json.Parse.string_of_error error)

let () =
  let filename = Sys.argv.(1) in
  let compiled, bag =
    Spectec.with_diagnostics (fun () ->
        let ( let* ) = Result.bind in
        let* el = Spectec.parse_spec_files [ filename ] in
        let* il = Spectec.elaborate el in
        Ok (il, Spectec.structure il))
  in
  let il, sl =
    match compiled with
    | Ok spec when D.Bag.is_empty bag -> spec
    | _ -> failwith (diagnostics bag)
  in
  let tdenv =
    List.fold_left
      (fun env def ->
        match def.Common.Source.it with
        | Lang.Il.TypD { synid; tparams; deftyp } ->
            Envs.Il.TDEnv.add synid (tparams, deftyp) env
        | _ -> env)
      Envs.Il.TDEnv.empty il
  in
  try
    while true do
      let request = Yojson.Safe.from_string (read_line ()) in
      let open Yojson.Safe.Util in
      let relation = request |> member "relation" |> to_string in
      let typed = member "typed_args" request <> `Null in
      let args =
        if typed then
          request |> member "typed_args" |> to_list
          |> List.map (typed_value tdenv)
        else request |> member "args" |> to_list |> List.map value
      in
      let mode = request |> member "mode" |> to_string in
      let response =
        Interp.with_target_state
          (module Pure_target)
          (fun state ->
            let result =
              match mode with
              | "il" ->
                  Interp.eval_il state il relation args filename
                  |> Result.map snd
              | "sl" ->
                  Interp.eval_sl state sl relation args filename
                  |> Result.map snd
              | _ -> failwith "Expected il or sl"
            in
            match result with
            | Ok values when typed ->
                let json_values =
                  List.map
                    (fun value ->
                      match Json.Print.value_to_json value with
                      | Ok json -> json
                      | Error error ->
                          failwith (Json.Print.string_of_error error))
                    values
                in
                `Assoc
                  [
                    ("status", `String "ok"); ("json_values", `List json_values);
                  ]
            | Ok values ->
                `Assoc
                  [
                    ("status", `String "ok");
                    ( "values",
                      `List (List.map (fun v -> `String (V.to_string v)) values)
                    );
                  ]
            | Error error ->
                `Assoc
                  [
                    ("status", `String "error");
                    ( "diagnostic",
                      `String
                        (error |> Interp.error_to_diagnostic |> D.Bag.singleton
                       |> diagnostics) );
                  ])
      in
      print_endline (Yojson.Safe.to_string response)
    done
  with End_of_file -> ()
