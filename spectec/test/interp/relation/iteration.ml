open Core
module H = Harness
module V = Lang.Il.Value
module Typ = Lang.Il.Typ

let ( $ ) = Common.Source.( $ )
let no_region = Common.Source.no_region
let nat n = V.nat (Bigint.of_int n)
let nats ns = V.list (Typ.nat $ no_region) (List.map ns ~f:nat)
let spec = H.compile_file "iteration.spectec"

let check_identity_hooks () =
  let module Hooks = Instrumentation.Value_hooks in
  let derived = ref 0 in
  let combined = ref 0 in
  let hooks =
    {
      Hooks.noop with
      on_derived =
        (fun ~source value ->
          Int.incr derived;
          assert (V.eq source value);
          assert (source.note.vid <> value.note.vid);
          value);
      on_combined =
        (fun ~sources value ->
          Int.incr combined;
          match sources with
          | [ source ] ->
              assert (V.eq source value);
              assert (source.note.vid <> value.note.vid);
              value
          | _ -> failwith "identity iteration lost its provenance source");
    }
  in
  Hooks.set hooks;
  Exn.protect
    ~f:(fun () ->
      H.check spec ~modes:[ H.Il ] ~name:"identity preserves value hooks"
        ~relation:"Identity"
        ~args:(fun () -> [ nats [ 1; 2; 3 ] ])
        (H.returns (fun () -> [ nats [ 1; 2; 3 ] ])))
    ~finally:Hooks.reset;
  assert (!derived = 1 && !combined = 1)

let run () =
  H.check spec ~name:"iterated relation binds each output" ~relation:"Add_each"
    ~args:(fun () -> [ nats [ 1; 2; 3 ]; nats [ 10; 20; 30 ] ])
    (H.returns (fun () -> [ nats [ 11; 22; 33 ] ]));
  H.check spec ~name:"iterated relation accepts empty inputs"
    ~relation:"Add_each"
    ~args:(fun () -> [ nats []; nats [] ])
    (H.returns (fun () -> [ nats [] ]));
  H.check spec ~name:"iterated relation rejects different input lengths"
    ~relation:"Add_each"
    ~args:(fun () -> [ nats [ 1; 2 ]; nats [ 10 ] ])
    (H.fails_with "cannot transpose a matrix of value batches");
  List.iter
    [ []; [ 1; 2; 3 ] ]
    ~f:(fun ns ->
      H.check spec ~name:"identity preserves list contents" ~relation:"Identity"
        ~args:(fun () -> [ nats ns ])
        (H.returns (fun () -> [ nats ns ])));
  let nested () =
    V.list
      (Typ.list (Typ.nat $ no_region) $ no_region)
      [ nats []; nats [ 1; 2 ]; nats [] ]
  in
  H.check spec ~name:"identity preserves nested lists"
    ~relation:"Identity_nested"
    ~args:(fun () -> [ nested () ])
    (H.returns (fun () -> [ nested () ]));
  check_identity_hooks ()
