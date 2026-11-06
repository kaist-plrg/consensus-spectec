module H = Harness
module V = Lang.Il.Value

let builtins =
  [
    ( "type_name",
      Builtins.Define.T1.a1 Builtins.Arg.value (fun ~at:_ typ _ ->
          Ok (V.text (Lang.Il.Print.string_of_typ typ))) );
  ]

let run () =
  let spec = H.compile_file "builtin_type_arguments.spectec" in
  H.check spec ~builtins
    ~name:"builtins receive instantiated nominal and composite type arguments"
    ~relation:"Probe"
    ~args:(fun () -> [ V.nat Bigint.zero ])
    (H.returns (fun () -> List.map V.text [ "small"; "wide"; "small*" ]))
