open Common.Annotated
open Lang.El
open Value

let invoke_primitive ~ctx ~at (primitive : Library.primitive_contract) ~branch
    ~values =
  let accepts operand value =
    match operand with
    | Library.Exact kind -> value.kind = kind
    | Library.Bytes width ->
        Value.byte_width ~types:(Ctx.types ctx) ~at value.kind
        = Some (Bigint.of_int width)
    | Library.Sequence expected ->
        let { Value.element; _ } =
          Value.sequence ~types:(Ctx.types ctx) ~at value.kind
        in
        element = expected
  in
  if not (List.for_all2 accepts primitive.operands values) then
    Error.reject ~at primitive.operand_error;
  let result =
    {
      exp =
        call ~at primitive.name ~args:(List.map (fun value -> value.exp) values);
      kind = primitive.result;
    }
  in
  if primitive.bind_result then Branch.bind ~ctx ~at branch ~term:result
  else (branch, result)

let notify_new_payload ~ctx ~at ~branch payload =
  if payload.kind <> Named Names.execution_payload then
    Error.reject ~at "Expected an execution payload";
  Branch.bind ~ctx ~at branch
    ~term:
      {
        exp = call ~at Names.new_payload_builtin ~args:[ payload.exp ];
        kind = Value.boolean;
      }

let bytes_get ~at bytes ~index = call ~at "bytes_get" ~args:[ bytes; index ]
let bytes_valid ~at bytes = call ~at "bytes_valid" ~args:[ bytes ]
let bytes_length ~at bytes = call ~at "bytes_length" ~args:[ bytes ]

let bytes_slice ~at bytes ~start ~count =
  call ~at "bytes_slice" ~args:[ bytes; start; count ]

let fixed_bytes ~at value ~width = call ~at "fixed_bytes" ~args:[ value; width ]
let concat_bytes ~at left ~right = call ~at "concat_bytes" ~args:[ left; right ]

let hash ~at bytes =
  call ~types:[ VarT (id ~at "bytes", []) $ at ] ~at "hash_" ~args:[ bytes ]

let uint_to_bytes ~at ~width value =
  call ~at (Printf.sprintf "uint%d_to_bytes_le" width) ~args:[ value ]

let bytes32_to_bytes ~at value = call ~at "bytes32_to_bytes" ~args:[ value ]

let bytes_of_fixed ~at ~width value =
  if Bigint.equal width (Bigint.of_int 4) then
    call ~at "bytes4_to_bytes" ~args:[ value ]
  else if Bigint.equal width (Bigint.of_int 32) then bytes32_to_bytes ~at value
  else fixed_bytes ~at value ~width:(number ~at width)

let aggregate_pubkeys ~at keys = call ~at "bls_aggregate_pubkeys" ~args:[ keys ]

type hasher = Generic | Specific of string

let hasher_of_kind ~ctx ~at kind =
  let generic =
    match kind with
    | Named name ->
        name = Names.signing_data
        || Typed.descriptor_of_name ~types:(Ctx.types ctx) ~at name
           = Typed.SszParameter
    | _ -> false
  in
  let hasher =
    if generic then Generic
    else
      match kind with
      | Named name when name = Names.state_type ->
          Specific "hash_tree_root_beaconState"
      | Named "BeaconBlockHeader" -> Specific "hash_tree_root_beaconBlockHeader"
      | Named "BeaconBlockBody" -> Specific "hash_tree_root_beaconBlockBody"
      | Named "ForkData" -> Specific "hash_tree_root_forkdata"
      | Named "DepositData" -> Specific "hash_tree_root_depositData"
      | Named name -> (
          match Typed.descriptor_of_name ~types:(Ctx.types ctx) ~at name with
          | Typed.Sequence
              {
                element = "Withdrawal";
                length = None;
                limit = Some limit;
                bitvector = false;
              }
          (* The handwritten withdrawal hasher assumes
             MAX_WITHDRAWALS_PER_PAYLOAD = 16. *)
            when Bigint.equal limit (Bigint.of_int 16) ->
              Specific "hash_tree_root_withdrawals"
          | Typed.Sequence
              { element; length = None; limit = Some limit; bitvector = false }
          (* The handwritten transaction hasher assumes
             MAX_TRANSACTIONS_PER_PAYLOAD = 1048576 and
             MAX_BYTES_PER_TRANSACTION = 1073741824. *)
            when Bigint.equal limit (Bigint.of_int 1048576)
                 &&
                 match
                   Typed.descriptor_of_name ~types:(Ctx.types ctx) ~at element
                 with
                 | Typed.Bytes { length = None; limit = Some limit } ->
                     Bigint.equal limit (Bigint.of_int 1073741824)
                 | _ -> false ->
              Specific "hash_tree_root_tx"
          | Typed.Sequence
              { element; length = Some length; limit = None; bitvector = false }
            when element = Names.root && Bigint.compare length Bigint.zero > 0
            ->
              Specific "hash_tree_root_roots"
          | _ -> Error.reject ~at "Unreviewed SSZ hash input")
      | _ -> Error.reject ~at "SSZ hashing requires concrete type metadata"
  in
  hasher

let hash_tree_root ~at ~hasher ~type_argument value =
  match hasher with
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
      Names.root;
      "VoluntaryExit";
      "BLSToExecutionChange";
      "BeaconBlockHeader";
      "AttestationData";
      "DepositMessage";
      "BeaconBlock";
      Names.signing_data;
    ]
