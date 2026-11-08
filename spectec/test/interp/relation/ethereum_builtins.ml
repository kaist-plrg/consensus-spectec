open Core
module H = Harness
module V = Lang.Il.Value
module Typ = Lang.Il.Typ
module Signature = Bls12_381_signature.MinPk

module Target : Interp.Target.S = struct
  include H.Pure_target

  let builtins = Builtin_eth.builtins
end

let ( $ ) = Common.Annotated.( $ )
let at = Common.Location.Unknown
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

let bytes_of_hex hex =
  V.make_bytes ~num:(Bigint.of_string ("0x" ^ hex)) ~len:(String.length hex / 2)

let checkpoint = V.tuple [ nat 0; nat 0 ]
let attestation_data = V.tuple [ nat 0; nat 0; nat 0; checkpoint; checkpoint ]

let attestation bit_count =
  V.tuple
    [
      V.list (Typ.bool $ at) (List.init bit_count ~f:(fun _ -> V.bool true));
      attestation_data;
      nat 0;
    ]

let indexed_attestation index_count =
  V.tuple
    [
      V.list (Typ.nat $ at) (List.init index_count ~f:nat);
      attestation_data;
      nat 0;
    ]

let execution_payload ~extra_data ~transactions =
  V.tuple
    (List.init 10 ~f:(fun _ -> nat 0)
    @ [
        bytes extra_data;
        nat 0;
        nat 0;
        V.list (Typ.nat $ at) (List.map transactions ~f:bytes);
        withdrawals 0;
      ])

let execution_payload_header ~extra_data =
  V.tuple
    (List.init 10 ~f:(fun _ -> nat 0)
    @ [ bytes extra_data; nat 0; nat 0; nat 0; nat 0 ])

(* Each expected root comes from remerkleable 0.1.28 with the same value and
   Capella SSZ type. *)
let check_python_root ~name ~relation ~args root =
  check ~name ~relation ~args (H.returns (fun () -> [ bytes_of_hex root ]))

let list_limits () =
  check_python_root ~name:"an empty withdrawal list hashes to the Python root"
    ~relation:"Withdrawals_root"
    ~args:(fun () -> [ withdrawals 0 ])
    "792930bbd5baac43bcc798ee49aa8185ef76bb3b44ba62b91d86ae569e4bb535";
  check_python_root
    ~name:"a withdrawal list below its limit hashes to the Python root"
    ~relation:"Withdrawals_root"
    ~args:(fun () -> [ withdrawals 3 ])
    "83b911c0a2ed9a030925e7608077a7a9eef6cab0f602efadbe1b5fb193ae2190";
  check_python_root
    ~name:"a withdrawal list at its limit hashes to the Python root"
    ~relation:"Withdrawals_root"
    ~args:(fun () -> [ withdrawals 16 ])
    "4bd03f9352b359c8b887928d2d33a71d6327c243f5269432a72d93b1b22b7bd0";
  check_python_root
    ~name:"aggregation bits within their limit hash to the Python root"
    ~relation:"Attestation_root"
    ~args:(fun () -> [ attestation 3 ])
    "a7360c69525704a1c3c061b33c2084b5682c1b38a30980488a8e737a605b05e5";
  check_python_root
    ~name:"attesting indices within their limit hash to the Python root"
    ~relation:"Indexed_attestation_root"
    ~args:(fun () -> [ indexed_attestation 3 ])
    "f64a59d98e2f559ff00ece14da13bb5730ea9106cc95b396fb23d91becfa4cfa";
  check_python_root
    ~name:
      "a payload with extra data and two transactions hashes to the Python root"
    ~relation:"Execution_payload_root"
    ~args:(fun () ->
      [
        execution_payload ~extra_data:"\001\002\003\004\005"
          ~transactions:[ "\001\002\003"; String.make 40 '\255' ];
      ])
    "5db6254365f0c17f8651c65c953fcc41ed2cb85c7cf61172689100a99b200c00";
  check_python_root
    ~name:"a payload header with extra data hashes to the Python root"
    ~relation:"Execution_payload_header_root"
    ~args:(fun () ->
      [ execution_payload_header ~extra_data:"\001\002\003\004\005" ])
    "d9e569fab2c8365bc7a0af470fb4b6a0093c6d3a45d3f3ddca89dff583a93f35"

let run () =
  aggregation ();
  fast_verification ();
  list_limits ()
