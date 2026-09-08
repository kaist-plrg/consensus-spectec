let () =
  let file = Sys.argv.(1) in
  let result, bag =
    Spectec.with_diagnostics (fun () ->
        match Spectec.parse_spec_files [ file ] with
        | Error e -> Error e
        | Ok spec_el -> Spectec.elaborate spec_el)
  in
  (match result with
  | Ok spec_il -> Format.printf "%s\n" (Lang.Il.Print.string_of_spec spec_il)
  | Error _ -> ());
  prerr_string
    (Spectec.Diagnostic.Render.render_bag ~ansi:Spectec.Diagnostic.Ansi.plain
       bag)
