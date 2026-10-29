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

let doubled_key =
  Bls12_381.G1.(
    let point = of_compressed_bytes_exn (Stdlib.Bytes.of_string key) in
    add point point |> to_compressed_bytes)
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

let g1_points () =
  check ~name:"G1 canonicalization returns a canonical point"
    ~relation:"G1_canonicalize"
    ~args:(fun () -> [ bytes key ])
    (H.returns (fun () -> [ bytes key ]));
  check ~name:"G1 canonicalization rejects an uncompressed encoding"
    ~relation:"G1_canonicalize"
    ~args:(fun () -> [ nat 0 ])
    (H.fails_with "invalid compressed G1 point");
  check ~name:"G1 addition doubles a point" ~relation:"G1_double"
    ~args:(fun () -> [ bytes key ])
    (H.returns (fun () -> [ bytes doubled_key ]));
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
    (H.fails_with "invalid byte value or slice bounds")

let ssz_roots () =
  check ~name:"ssz_hash_tree_root hashes a uint64 alias" ~relation:"Hash_epoch"
    ~args:(fun () -> [ nat 1 ])
    (H.returns (fun () -> [ bytes ("\001" ^ String.make 31 '\000') ]));
  check ~name:"ssz_hash_tree_root rejects an unsupported type"
    ~relation:"Hash_other"
    ~args:(fun () -> [ nat 0 ])
    (H.fails_with "Unsupported SSZ hash type: other")

let enumeration () =
  List.iter
    [ []; [ 4; 9 ] ]
    ~f:(fun values ->
      check ~name:"enumeration retains pair element types" ~relation:"Enumerate"
        ~args:(fun () -> [ V.list (Typ.nat $ at) (List.map values ~f:nat) ])
        (H.satisfies (function
          | [ value ] ->
              let pair_type = Typ.tuple [ Typ.nat $ at; Typ.nat $ at ] $ at in
              let expected =
                V.list pair_type
                  (List.mapi values ~f:(fun index item ->
                       V.tuple [ nat index; nat item ]))
              in
              assert (V.eq value expected);
              assert (
                Lang.Il.Eq.eq_typ (value.note.typ $ at) (expected.note.typ $ at))
          | _ -> assert false)))

let run () =
  enumeration ();
  aggregation ();
  fast_verification ();
  withdrawal_limit ();
  key_validation ();
  g1_points ();
  byte_strings ();
  ssz_roots ()
