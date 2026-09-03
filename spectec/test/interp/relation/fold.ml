open Core
module H = Harness
module V = Lang.Il.Value
module Typ = Lang.Il.Typ

let ( $ ) = Common.Source.( $ )
let no_region = Common.Source.no_region
let nat_type = Typ.nat $ no_region
let nat_list_type = Typ.list nat_type $ no_region
let nat n = V.nat (Bigint.of_int n)
let nats ns = V.list nat_type (List.map ns ~f:nat)
let natss nss = V.list nat_list_type (List.map nss ~f:nats)
let spec = H.compile_file "fold.spectec"

let run () =
  H.check spec ~name:"fold passes each result to the next iteration"
    ~relation:"SumList"
    ~args:(fun () -> [ nat 0; nats [ 1; 2; 3 ] ])
    (H.returns (fun () -> [ nat 6 ]));
  H.check spec ~name:"empty fold returns its initial value" ~relation:"SumList"
    ~args:(fun () -> [ nat 6; nats [] ])
    (H.returns (fun () -> [ nat 6 ]));
  H.check spec ~name:"fold body can compute its next accumulator"
    ~relation:"ProductList"
    ~args:(fun () -> [ nat 1; nats [ 2; 3; 4 ] ])
    (H.returns (fun () -> [ nat 24 ]));
  H.check spec ~name:"fold preserves iteration order" ~relation:"ReverseList"
    ~args:(fun () -> [ nats [ 1; 2; 3 ] ])
    (H.returns (fun () -> [ nats [ 3; 2; 1 ] ]));
  H.check spec ~name:"fold carries a list-valued accumulator"
    ~relation:"AddDeltas"
    ~args:(fun () -> [ nats [ 1; 2 ]; nats [ 10; 20 ] ])
    (H.returns (fun () -> [ nats [ 31; 32 ] ]));
  H.check spec ~name:"fold carries multiple accumulators" ~relation:"SumPair"
    ~args:(fun () -> [ nat 0; nat 10; nats [ 1; 2; 3 ] ])
    (H.returns (fun () -> [ nat 6; nat 16 ]));
  H.check spec ~name:"fold captures a list without consuming its dimension"
    ~relation:"SumListWithContext"
    ~args:(fun () -> [ nat 0; nats [ 10; 20 ]; nats [ 1; 2; 3 ] ])
    (H.returns (fun () -> [ nat 6 ]));
  H.check spec ~name:"nested folds carry one accumulator across a matrix"
    ~relation:"SumMatrix"
    ~args:(fun () -> [ nat 0; natss [ [ 1; 2 ]; [ 3; 4 ] ] ])
    (H.returns (fun () -> [ nat 10 ]));
  H.check spec ~name:"iteration collects one fold result for each row"
    ~relation:"SumRows"
    ~args:(fun () -> [ nat 0; natss [ [ 1; 2 ]; [ 3; 4 ] ] ])
    (H.returns (fun () -> [ nats [ 3; 7 ] ]));
  H.check spec ~name:"iteration over folds can be empty" ~relation:"SumRows"
    ~args:(fun () -> [ nat 0; natss [] ])
    (H.returns (fun () -> [ nats [] ]));
  H.check spec ~name:"fold propagates a failing body premise"
    ~relation:"SumStrictlyPositiveList"
    ~args:(fun () -> [ nat 0; nats [ 1; 0; 2 ] ])
    H.fails
