open Core
module H = Harness
module V = Lang.Il.Value
module Typ = Lang.Il.Typ

let ( $ ) = Common.Source.( $ )
let at = Common.Source.no_region
let nat n = V.nat (Bigint.of_int n)
let bytes n = V.make_bytes ~num:(Bigint.of_int n) ~len:48
let pair_type = Typ.tuple [ Typ.nat $ at; Typ.var "key" [] $ at ] $ at
let spec = H.compile_file "bytes_matching.spectec"

let run () =
  List.iter
    [ (1, 0); (2, 1) ]
    ~f:(fun (key, index) ->
      H.check spec
        ~name:(sprintf "byte-key lookup at index %d" index)
        ~relation:"Find_key"
        ~args:(fun () ->
          [
            V.list pair_type
              [ V.tuple [ nat 0; bytes 1 ]; V.tuple [ nat 1; bytes 2 ] ];
            bytes key;
          ])
        (H.returns (fun () -> [ nat index ])));
  H.check spec ~name:"byte value downcasts to nat" ~relation:"As_nat"
    ~args:(fun () -> [ bytes 1 ])
    (H.returns (fun () -> [ bytes 1 ]));
  H.check spec ~name:"byte value upcasts to int" ~relation:"As_int"
    ~args:(fun () -> [ bytes 1 ])
    (H.returns (fun () -> [ bytes 1 ]))
