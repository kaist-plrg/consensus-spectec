let ( let* ) = Result.bind

let translate ~sources ~context =
  let generated =
    Pyspec.Translate.bundle
      (Pyspec.Bundle.make (Pyspec.Source_json.load_many sources))
  in
  let* () =
    match context with
    | [] -> Ok ()
    | files ->
        let* context = Spectec.parse_spec_files files in
        let* _ = Pyspec.Assembly.compile ~context generated in
        Ok ()
  in
  Ok (Pyspec.Assembly.definitions generated)

let command =
  Core.Command.basic
    ~summary:"Translate pyspec source documents into SpecTec definitions"
    ~readme:(fun () ->
      "Exits with status 1 when a source is outside the supported subset or \
       the context check fails, and with status 2 on an internal fault.")
  @@
  let open Core.Command.Let_syntax in
  let open Core.Command.Param in
  let%map sources = anon ("SOURCES" %: string)
  and context =
    flag "--context" (listed string)
      ~doc:
        "FILE spec file whose declarations the generated definitions replace, \
         after which the result is elaborated and structured as a check"
  and color = Cli.Cli_args.Output.color_flag in
  fun () ->
    try
      Cli.Error_handling.guard ~color
        ~on_ok:(fun definitions ->
          print_string (Lang.El.Unparse.string_of_spec definitions))
        (fun () -> translate ~sources ~context)
    with
    | Pyspec.Error.Rejected (at, message) ->
        prerr_endline (Pyspec.Error.to_string ~at message);
        exit 1
    | fault ->
        prerr_endline (Printexc.to_string fault);
        exit 2
