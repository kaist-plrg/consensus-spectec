open Core
module H = Harness
module V = Lang.Il.Value
module Typ = Lang.Il.Typ
module Signature = Bls12_381_signature.MinPk

module Target : Interp.Target.S = struct
  include H.Pure_target

  let builtins = Builtin_eth.builtins
end

let ( $ ) = Common.Source.( $ )
let at = Common.Source.no_region
let spec = H.compile_file "ethereum_builtins.spectec"
let nat n = V.nat (Bigint.of_int n)

let bytes contents =
  let num =
    String.fold contents ~init:Bigint.zero ~f:(fun acc c ->
        Bigint.((acc * of_int 256) + of_int (Char.to_int c)))
  in
  V.make_bytes ~num ~len:(String.length contents)

let keys values = V.list (Typ.nat $ at) (List.map values ~f:bytes)
let secret = Bls12_381_signature.generate_sk (Stdlib.Bytes.make 32 '\001')
let key = Signature.(derive_pk secret |> pk_to_bytes) |> Stdlib.Bytes.to_string

let negated_key =
  Bls12_381.G1.(
    of_compressed_bytes_exn (Stdlib.Bytes.of_string key)
    |> negate |> to_compressed_bytes)
  |> Stdlib.Bytes.to_string

let infinity = "\xc0" ^ String.make 47 '\000'

let check ~name ~relation ~args expectation =
  H.check spec ~target:(module Target) ~name ~relation ~args expectation

let aggregation () =
  check ~name:"aggregation rejects an empty key list" ~relation:"Aggregate"
    ~args:(fun () -> [ keys [] ])
    (H.fails_with "empty public key list");
  check ~name:"aggregation rejects the point at infinity" ~relation:"Aggregate"
    ~args:(fun () -> [ keys [ key; infinity ] ])
    (H.fails_with "invalid BLS public key");
  check ~name:"aggregation returns an aggregate at infinity"
    ~relation:"Aggregate"
    ~args:(fun () -> [ keys [ key; negated_key ] ])
    (H.returns (fun () -> [ bytes infinity ]))

let message = String.make 32 '\002'

let signature =
  Signature.(
    Pop.sign secret (Stdlib.Bytes.of_string message) |> signature_to_bytes)
  |> Stdlib.Bytes.to_string

let fast_verification () =
  check ~name:"fast aggregate verification accepts a valid signature"
    ~relation:"Fast_aggregate_verify"
    ~args:(fun () -> [ keys [ key ]; bytes message; bytes signature ])
    (H.returns (fun () -> [ V.bool true ]));
  check ~name:"fast aggregate verification rejects a key at infinity"
    ~relation:"Fast_aggregate_verify"
    ~args:(fun () -> [ keys [ key; infinity ]; bytes message; bytes signature ])
    (H.returns (fun () -> [ V.bool false ]))

let withdrawals count =
  V.list
    (Typ.var "withdrawal" [] $ at)
    (List.init count ~f:(fun index ->
         V.tuple [ nat index; nat 0; nat 0; nat 0 ]))

let withdrawal_limit () =
  check ~name:"a full withdrawal list is hashed" ~relation:"Withdrawals_root"
    ~args:(fun () -> [ withdrawals 16 ])
    (H.satisfies (fun _ -> ()));
  match
    H.check spec ~modes:[ H.Il ]
      ~target:(module Target)
      ~name:"an over-limit withdrawal list is not hashed"
      ~relation:"Withdrawals_root"
      ~args:(fun () -> [ withdrawals 17 ])
      H.fails
  with
  | () -> failwith "an over-limit withdrawal list was hashed"
  | exception Invalid_argument message
    when String.is_substring message ~substring:"exceed the limit" ->
      ()

let run () =
  aggregation ();
  fast_verification ();
  withdrawal_limit ()
