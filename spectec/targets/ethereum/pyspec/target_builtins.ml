open Common.Source
open Lang.El
open Kind
open Operand
module S = Source

let declare ~ctx ~at name =
  if not (Registry.declared_function ~builtin:true ~name ctx.Ctx.registry) then
    let signature =
      match name with
      | "hash_" -> "<X>(X): bytes32"
      | "ssz_hash_tree_root" -> "<X>(X): root"
      | "ee_verify_and_notify_new_payload" -> "(executionPayload): bool"
      | "hash_tree_root_tx" -> "(bytes*): root"
      | "hash_tree_root_withdrawals" -> "(withdrawal*): root"
      | "bls_g1_canonicalize" | "bls_g1_neg" -> "(bytes48): bytes48"
      | "bls_g1_add" -> "(bytes48, bytes48): bytes48"
      | "concat_bytes" -> "(bytes, bytes): bytes"
      | "uint8_to_bytes_le" -> "(uint8): bytes"
      | "uint32_to_bytes_le" -> "(uint32): bytes"
      | "uint64_to_bytes_le" -> "(uint64): bytes"
      | "bytes4_to_bytes" -> "(bytes4): bytes"
      | "bytes32_to_bytes" -> "(bytes32): bytes"
      | "fixed_bytes" -> "(int, nat): bytes"
      | "bytes_valid" -> "(bytes): bool"
      | "bytes_length" -> "(bytes): nat"
      | "bytes_slice" -> "(bytes, nat, nat): bytes"
      | "bytes_get" -> "(bytes, nat): int"
      | "hash_tree_root_beaconState" -> "(beaconState): root"
      | "hash_tree_root_beaconBlockHeader" -> "(beaconBlockHeader): root"
      | "hash_tree_root_beaconBlockBody" -> "(beaconBlockBody): root"
      | "hash_tree_root_roots" -> "(root*): root"
      | "hash_tree_root_forkdata" -> "(forkdata): root"
      | "hash_tree_root_depositData" -> "(depositData): root"
      | "bls_key_validate" -> "(blsPubkey): boolean"
      | "bls_verify" -> "(blsPubkey, root, blsSignature): boolean"
      | "bls_fast_aggregate_verify" ->
          "(blsPubkey*, root, blsSignature): boolean"
      | "bls_aggregate_pubkeys" -> "(blsPubkey*): blsPubkey"
      | _ -> Error.reject ~at "Unreviewed crypto primitive"
    in
    let contents = "builtin dec $" ^ name ^ signature in
    match
      Spectec.parse_spec_source { filename = "<crypto-contract>"; contents }
    with
    | Ok [ declaration ] ->
        Registry.emit ~registry:ctx.Ctx.registry ~ownership:Shared
          [ declaration ]
    | _ -> Error.reject ~at "Invalid crypto contract declaration"

let builtin ?types ctx at name args =
  declare ~ctx ~at name;
  call ?types ~at name ~args

let bytes_get ~ctx ~at bytes ~index =
  builtin ctx at "bytes_get" [ bytes; index ]

let bytes_valid ~ctx ~at bytes = builtin ctx at "bytes_valid" [ bytes ]
let bytes_length ~ctx ~at bytes = builtin ctx at "bytes_length" [ bytes ]

let bytes_slice ~ctx ~at bytes ~start ~count =
  builtin ctx at "bytes_slice" [ bytes; start; count ]

let fixed_bytes ~ctx ~at value ~width =
  builtin ctx at "fixed_bytes" [ value; width ]

let concat_bytes ~ctx ~at left ~right =
  builtin ctx at "concat_bytes" [ left; right ]

let hash ~ctx ~at bytes =
  builtin ~types:[ VarT (id ~at "bytes", []) $ at ] ctx at "hash_" [ bytes ]

let uint_to_bytes ~ctx ~at ~width value =
  builtin ctx at (Printf.sprintf "uint%d_to_bytes_le" width) [ value ]

let to_bytes ~ctx ~at ~width value =
  if Bigint.equal width (Bigint.of_int 4) then
    builtin ctx at "bytes4_to_bytes" [ value ]
  else if Bigint.equal width (Bigint.of_int 32) then
    builtin ctx at "bytes32_to_bytes" [ value ]
  else fixed_bytes ~ctx ~at value ~width:(number ~at width)

let bytes32_to_bytes ~ctx ~at value =
  builtin ctx at "bytes32_to_bytes" [ value ]

let notify_new_payload ~ctx ~at payload =
  builtin ctx at "ee_verify_and_notify_new_payload" [ payload ]

let aggregate_pubkeys ~ctx ~at keys =
  builtin ctx at "bls_aggregate_pubkeys" [ keys ]

type root = Generic | Specific of string

let hash_tree_root_builtin ~ctx ~at kind =
  let generic =
    match kind with
    | Named name ->
        name = Spec_names.signing_data
        || Kind.descriptor ~types:(Ctx.types ctx) ~at name = S.SszParameter
    | _ -> false
  in
  let root =
    if generic then Generic
    else
      match kind with
      | Named "BeaconState" -> Specific "hash_tree_root_beaconState"
      | Named "BeaconBlockHeader" -> Specific "hash_tree_root_beaconBlockHeader"
      | Named "BeaconBlockBody" -> Specific "hash_tree_root_beaconBlockBody"
      | Named "ForkData" -> Specific "hash_tree_root_forkdata"
      | Named "DepositData" -> Specific "hash_tree_root_depositData"
      | Named name -> (
          match Kind.descriptor ~types:(Ctx.types ctx) ~at name with
          | S.Sequence
              {
                element = "Withdrawal";
                length = None;
                limit = Some limit;
                bitvector = false;
              }
            when Bigint.equal limit (Bigint.of_int 16) ->
              Specific "hash_tree_root_withdrawals"
          | S.Sequence
              { element; length = None; limit = Some limit; bitvector = false }
            when Bigint.equal limit (Bigint.of_int 1048576)
                 &&
                 match Kind.descriptor ~types:(Ctx.types ctx) ~at element with
                 | S.Bytes { length = None; limit = Some limit } ->
                     Bigint.equal limit (Bigint.of_int 1073741824)
                 | _ -> false ->
              Specific "hash_tree_root_tx"
          | S.Sequence
              {
                element = "Root";
                length = Some length;
                limit = None;
                bitvector = false;
              }
            when Bigint.compare length Bigint.zero > 0 ->
              Specific "hash_tree_root_roots"
          | _ -> Error.reject ~at "Unreviewed SSZ hash input")
      | _ -> Error.reject ~at "SSZ hashing requires concrete type metadata"
  in
  declare ~ctx ~at
    (match root with Generic -> "ssz_hash_tree_root" | Specific name -> name);
  root

let hash_tree_root ~at ~root ~type_argument value =
  match root with
  | Generic ->
      call ~types:[ type_argument () ] ~at "ssz_hash_tree_root" ~args:[ value ]
  | Specific name -> call ~at name ~args:[ value ]

let accepts_polymorphic_hash_input name =
  List.mem name
    [
      "Epoch";
      "Slot";
      "Gwei";
      "uint64";
      "Root";
      "Bytes32";
      "VoluntaryExit";
      "BLSToExecutionChange";
      "BeaconBlockHeader";
      "AttestationData";
      "DepositMessage";
      "BeaconBlock";
      "SigningData";
    ]

let declare_execution_engine ~ctx ~at =
  match
    Spectec.parse_spec_source
      {
        filename = "<external-engine>";
        contents = "syntax executionEngine = ()";
      }
  with
  | Ok [ definition ] ->
      Registry.emit ~registry:ctx.Ctx.registry ~ownership:Shared [ definition ]
  | _ -> Error.reject ~at "Invalid external engine declaration"
