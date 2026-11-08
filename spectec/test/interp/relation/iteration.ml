module Location = Common.Location
open Core
module H = Harness
module V = Lang.Il.Value
module Typ = Lang.Il.Typ

let ( $ ) = Common.Annotated.( $ )
let nat_type = Typ.nat $ Location.Unknown
let nat n = V.nat (Bigint.of_int n)
let nats ns = V.list nat_type (List.map ns ~f:nat)

let nat_lists nss =
  V.list (Typ.list nat_type $ Location.Unknown) (List.map nss ~f:nats)

let spec = H.compile_file "iteration.spectec"

let check_identity_observer () =
  let derived = ref 0 in
  let combined = ref 0 in
  let module Observer : Instrumentation.Handler.S = struct
    let static_dependencies = []
    let init ~spec:_ = ()
    let handle _ = ()

    let handle_value =
      Some
        (function
        | Instrumentation.Value_event.Derived { source; value } ->
            Int.incr derived;
            assert (V.eq source value);
            assert (source.note.vid <> value.note.vid)
        | Combined { sources = source :: _; value } ->
            Int.incr combined;
            assert (V.eq source value);
            assert (source.note.vid <> value.note.vid)
        | _ -> ())

    let finish () = ()
  end in
  Instrumentation.Dispatcher.init
    ~spec:(Instrumentation.Static.IlSpec spec.spec_il)
    ~handlers:[ (module Observer) ];
  Exn.protect
    ~f:(fun () ->
      H.check spec ~modes:[ H.Il ] ~name:"identity preserves value handlers"
        ~relation:"Identity"
        ~args:(fun () -> [ nats [ 1; 2; 3 ] ])
        (H.returns (fun () -> [ nats [ 1; 2; 3 ] ])))
    ~finally:Instrumentation.Dispatcher.finish;
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
  H.check spec ~name:"nested relation keeps empty inner lists"
    ~relation:"Add_nested"
    ~args:(fun () ->
      [
        nat_lists [ [ 1; 2 ]; []; [ 3 ] ]; nat_lists [ [ 10; 20 ]; []; [ 30 ] ];
      ])
    (H.returns (fun () -> [ nat_lists [ [ 11; 22 ]; []; [ 33 ] ] ]));
  H.check spec ~name:"nested relation rejects different inner lengths"
    ~relation:"Add_nested"
    ~args:(fun () -> [ nat_lists [ [ 1; 2 ] ]; nat_lists [ [ 10 ] ] ])
    (H.fails_with "cannot transpose a matrix of value batches");
  H.check spec ~name:"iterated binding binds each output"
    ~relation:"Increment_each"
    ~args:(fun () -> [ nats [ 1; 2 ] ])
    (H.returns (fun () -> [ nats [ 2; 3 ] ]));
  H.check spec ~name:"iterated binding accepts empty input"
    ~relation:"Increment_each"
    ~args:(fun () -> [ nats [] ])
    (H.returns (fun () -> [ nats [] ]));
  H.check spec ~name:"iterated condition accepts all true"
    ~relation:"Require_positive_each"
    ~args:(fun () -> [ nats [ 1; 2 ] ])
    (H.returns (fun () -> [ nats [ 1; 2 ] ]));
  H.check spec ~name:"iterated condition rejects one false"
    ~relation:"Require_positive_each"
    ~args:(fun () -> [ nats [ 1; 0; 2 ] ])
    H.fails;
  H.check spec ~name:"nested condition accepts empty inner lists"
    ~relation:"Require_positive_nested"
    ~args:(fun () -> [ nat_lists [ [ 1 ]; []; [ 2 ] ] ])
    (H.returns (fun () -> [ nat_lists [ [ 1 ]; []; [ 2 ] ] ]));
  H.check spec ~name:"nested condition rejects one false"
    ~relation:"Require_positive_nested"
    ~args:(fun () -> [ nat_lists [ [ 1 ]; [ 2; 0 ] ] ])
    H.fails;
  H.check spec ~name:"iterated assertion accepts all successes"
    ~relation:"Assert_positive_each"
    ~args:(fun () -> [ nats [ 1; 2 ] ])
    (H.returns (fun () -> [ nats [ 1; 2 ] ]));
  H.check spec ~name:"iterated assertion rejects one failure"
    ~relation:"Assert_positive_each"
    ~args:(fun () -> [ nats [ 1; 0 ] ])
    H.fails;
  List.iter
    [ []; [ 1; 2; 3 ] ]
    ~f:(fun ns ->
      H.check spec ~name:"identity preserves list contents" ~relation:"Identity"
        ~args:(fun () -> [ nats ns ])
        (H.returns (fun () -> [ nats ns ])));
  let nested () =
    V.list
      (Typ.list (Typ.nat $ Location.Unknown) $ Location.Unknown)
      [ nats []; nats [ 1; 2 ]; nats [] ]
  in
  H.check spec ~name:"identity preserves nested lists"
    ~relation:"Identity_nested"
    ~args:(fun () -> [ nested () ])
    (H.returns (fun () -> [ nested () ]));
  check_identity_observer ()
