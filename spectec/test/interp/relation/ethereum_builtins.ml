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
  check ~name:"translated aggregation has its own builtin entry point"
    ~relation:"Aggregate_translated"
    ~args:(fun () -> [ keys [ key ] ])
    (H.returns (fun () -> [ bytes key ]));
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
  check ~name:"a withdrawal list over its limit is rejected"
    ~relation:"Withdrawals_root"
    ~args:(fun () -> [ withdrawals 17 ])
    (H.fails_with "withdrawals: a list of 17 elements exceeds its limit of 16");
  check_python_root
    ~name:"aggregation bits within their limit hash to the Python root"
    ~relation:"Attestation_root"
    ~args:(fun () -> [ attestation 3 ])
    "a7360c69525704a1c3c061b33c2084b5682c1b38a30980488a8e737a605b05e5";
  check ~name:"aggregation bits over their limit are rejected"
    ~relation:"Attestation_root"
    ~args:(fun () -> [ attestation 2049 ])
    (H.fails_with
       "aggregation_bits: a list of 2049 elements exceeds its limit of 2048");
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
    "d9e569fab2c8365bc7a0af470fb4b6a0093c6d3a45d3f3ddca89dff583a93f35";
  check ~name:"attesting indices over their limit are rejected"
    ~relation:"Indexed_attestation_root"
    ~args:(fun () -> [ indexed_attestation 2049 ])
    (H.fails_with
       "attesting_indices: a list of 2049 elements exceeds its limit of 2048");
  check ~name:"extra data over 32 bytes is rejected"
    ~relation:"Execution_payload_root"
    ~args:(fun () ->
      [ execution_payload ~extra_data:(String.make 33 '\001') ~transactions:[] ])
    (H.fails_with "extra_data: a list of 33 elements exceeds its limit of 32");
  check ~name:"header extra data over 32 bytes is rejected"
    ~relation:"Execution_payload_header_root"
    ~args:(fun () ->
      [ execution_payload_header ~extra_data:(String.make 33 '\001') ])
    (H.fails_with "extra_data: a list of 33 elements exceeds its limit of 32")

let doubled_key =
  Bls12_381.G1.(
    let point = of_compressed_bytes_exn (Stdlib.Bytes.of_string key) in
    add point point |> to_compressed_bytes)
  |> Stdlib.Bytes.to_string

let other_key =
  Signature.(
    derive_pk (Bls12_381_signature.generate_sk (Stdlib.Bytes.make 32 '\002'))
    |> pk_to_bytes)
  |> Stdlib.Bytes.to_string

let key_sum =
  Bls12_381.G1.(
    let point text = of_compressed_bytes_exn (Stdlib.Bytes.of_string text) in
    add (point key) (point other_key) |> to_compressed_bytes)
  |> Stdlib.Bytes.to_string

let key_validation () =
  check ~name:"a valid public key passes key validation"
    ~relation:"Key_validate"
    ~args:(fun () -> [ bytes key ])
    (H.returns (fun () -> [ V.bool true ]));
  check ~name:"the point at infinity fails key validation"
    ~relation:"Key_validate"
    ~args:(fun () -> [ bytes infinity ])
    (H.returns (fun () -> [ V.bool false ]))

(* x = 4 lies on the curve, and its point is outside the prime-order subgroup. *)
let outside_subgroup = "\x80" ^ String.make 46 '\000' ^ "\x04"

(* x = 1 is not the x-coordinate of any curve point. *)
let off_curve = "\x80" ^ String.make 46 '\000' ^ "\x01"

(* The coordinate is the base field's modulus, with the compression flag set. *)
let outside_field =
  "9a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab"

let g1_points () =
  check ~name:"G1 canonicalization accepts a curve point outside the subgroup"
    ~relation:"G1_canonicalize"
    ~args:(fun () -> [ bytes outside_subgroup ])
    (H.returns (fun () -> [ bytes outside_subgroup ]));
  check ~name:"G1 canonicalization rejects a coordinate outside the base field"
    ~relation:"G1_canonicalize"
    ~args:(fun () -> [ bytes_of_hex outside_field ])
    (H.fails_with "G1 coordinate outside the base field");
  check ~name:"G1 canonicalization rejects a point off the curve"
    ~relation:"G1_canonicalize"
    ~args:(fun () -> [ bytes off_curve ])
    (H.fails_with "G1 point is not on the curve");
  check ~name:"G1 canonicalization returns a canonical point"
    ~relation:"G1_canonicalize"
    ~args:(fun () -> [ bytes key ])
    (H.returns (fun () -> [ bytes key ]));
  check ~name:"G1 canonicalization rejects an uncompressed encoding"
    ~relation:"G1_canonicalize"
    ~args:(fun () -> [ nat 0 ])
    (H.fails_with "invalid compressed G1 point");
  check
    ~name:"G1 canonicalization clears the other bits of an infinity encoding"
    ~relation:"G1_canonicalize"
    ~args:(fun () -> [ bytes ("\xe0" ^ String.make 47 '\000') ])
    (H.returns (fun () -> [ bytes infinity ]));
  check ~name:"G1 addition doubles a point" ~relation:"G1_double"
    ~args:(fun () -> [ bytes key ])
    (H.returns (fun () -> [ bytes doubled_key ]));
  check ~name:"G1 addition adds two different points" ~relation:"G1_add"
    ~args:(fun () -> [ bytes key; bytes other_key ])
    (H.returns (fun () -> [ bytes key_sum ]));
  check ~name:"G1 addition of a point and its negation is infinity"
    ~relation:"G1_cancel"
    ~args:(fun () -> [ bytes key ])
    (H.returns (fun () -> [ bytes infinity ]))

let byte_strings () =
  check ~name:"fixed_bytes encodes a number at its width"
    ~relation:"Fixed_bytes"
    ~args:(fun () -> [ nat 255; nat 1 ])
    (H.returns (fun () -> [ bytes "\xff" ]));
  check ~name:"fixed_bytes rejects a number wider than its width"
    ~relation:"Fixed_bytes"
    ~args:(fun () -> [ nat 256; nat 1 ])
    (H.fails_with "value does not fit its width");
  check ~name:"fixed_bytes keeps a byte value of its width"
    ~relation:"Fixed_bytes"
    ~args:(fun () -> [ bytes "\001\002"; nat 2 ])
    (H.returns (fun () -> [ bytes "\001\002" ]));
  check ~name:"fixed_bytes rejects bytes of another width"
    ~relation:"Fixed_bytes"
    ~args:(fun () -> [ bytes "\001\002"; nat 1 ])
    (H.fails_with "value has an incompatible width");
  check ~name:"bytes_valid accepts a byte string" ~relation:"Bytes_valid"
    ~args:(fun () -> [ bytes "\001" ])
    (H.returns (fun () -> [ V.bool true ]));
  check ~name:"bytes_valid refuses a number" ~relation:"Bytes_valid"
    ~args:(fun () -> [ nat 5 ])
    (H.returns (fun () -> [ V.bool false ]));
  check ~name:"bytes_length measures a byte string" ~relation:"Bytes_length"
    ~args:(fun () -> [ bytes "\001\002\003" ])
    (H.returns (fun () -> [ nat 3 ]));
  check ~name:"bytes_length measures an empty byte string"
    ~relation:"Bytes_length"
    ~args:(fun () -> [ bytes "" ])
    (H.returns (fun () -> [ nat 0 ]));
  check ~name:"bytes_length rejects a number" ~relation:"Bytes_length"
    ~args:(fun () -> [ nat 5 ])
    (H.fails_with "not a well-formed byte string");
  check ~name:"bytes_slice reads a range" ~relation:"Bytes_slice"
    ~args:(fun () -> [ bytes "\001\002\003"; nat 1; nat 2 ])
    (H.returns (fun () -> [ bytes "\002\003" ]));
  check ~name:"bytes_slice rejects a range past the end" ~relation:"Bytes_slice"
    ~args:(fun () -> [ bytes "\001\002\003"; nat 2; nat 2 ])
    (H.fails_with "invalid byte value or slice bounds");
  check ~name:"bytes_get reads one byte" ~relation:"Bytes_get"
    ~args:(fun () -> [ bytes "\001\002\003"; nat 1 ])
    (H.returns (fun () -> [ nat 2 ]));
  check ~name:"bytes_get rejects an index past the end" ~relation:"Bytes_get"
    ~args:(fun () -> [ bytes "\001\002\003"; nat 3 ])
    (H.fails_with "invalid byte value or slice bounds")

let enumeration () =
  List.iter
    [ []; [ 4; 9 ] ]
    ~f:(fun values ->
      check
        ~name:
          (sprintf "enumeration of %d values annotates its pair type"
             (List.length values))
        ~relation:"Enumerate"
        ~args:(fun () -> [ V.list (Typ.nat $ at) (List.map values ~f:nat) ])
        (H.returns_typed (fun () ->
             [
               V.list
                 (Typ.tuple [ Typ.nat $ at; Typ.nat $ at ] $ at)
                 (List.mapi values ~f:(fun index item ->
                      V.tuple [ nat index; nat item ]));
             ])))

let range_annotation () =
  check ~name:"range annotates its result as a nat list" ~relation:"Range"
    ~args:(fun () -> [ nat 3 ])
    (H.returns_typed (fun () ->
         [ V.list (Typ.nat $ at) [ nat 0; nat 1; nat 2 ] ]))

let run () =
  aggregation ();
  fast_verification ();
  list_limits ();
  enumeration ();
  range_annotation ();
  key_validation ();
  g1_points ();
  byte_strings ()
