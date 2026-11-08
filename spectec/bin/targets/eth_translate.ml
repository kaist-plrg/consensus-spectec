let command =
  Core.Command.basic
    ~summary:"Translate pyspec source documents into SpecTec definitions"
    ~readme:(fun () ->
      "Exits with status 1 if FILE cannot be read, is not JSON, or contains \
       unsupported source. Exits with status 2 on an internal fault.")
  @@
  let open Core.Command.Let_syntax in
  let open Core.Command.Param in
  let%map file = anon ("FILE" %: string)
  and color = Cli.Cli_args.Output.color_flag in
  fun () ->
    match Pyspec.translate (Pyspec.load file) with
    | definitions -> print_string (Lang.El.Unparse.string_of_spec definitions)
    | exception Pyspec.Rejected (at, message) ->
        let ansi = Cli.Error_handling.resolve_ansi ~out:Unix.stderr color in
        Printf.eprintf "%s\n%!"
          (Spectec.Diagnostic.Render.render_bag ~ansi
             (Spectec.Diagnostic.Bag.singleton
                (Spectec.Diagnostic.error ~source:"translate" at message)));
        exit 1
    | exception fault ->
        prerr_endline (Printexc.to_string fault);
        exit 2
