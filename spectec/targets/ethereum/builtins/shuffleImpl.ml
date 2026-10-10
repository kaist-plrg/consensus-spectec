(* compute_shuffled_index as a builtin. NEEDS USER DECISION: the spec defines
   it with 90 interpreted rounds; this replaces the rounds with native code.

   dec $compute_shuffled_index_rounds(uint64, uint64, bytes32, uint64) : uint64
   index, index_count, seed, SHUFFLE_ROUND_COUNT (passed in, so the preset
   stays in the spec). The algorithm is phase0 compute_shuffled_index. *)

open Lang.Il
open Lang.Xl
open Builtins
open Error
module Bytes = Stdlib.Bytes

let sha256 s = Digestif.SHA256.(to_raw_string (digest_string s))

(* A bytes32 value as its 32 big-endian bytes. *)
let seed_bytes (v : Value.t) =
  let num =
    match v.it with
    | BytesV { num; _ } -> num
    | NumV n -> Num.to_int n
    | _ -> raise Exit
  in
  let b = Bytes.make 32 '\000' in
  let rec put i n =
    if i >= 0 then (
      Bytes.set b i (Char.chr Bigint.(to_int_exn (bit_and n (of_int 0xff))));
      put (i - 1) (Bigint.shift_right n 8))
  in
  put 31 num;
  Bytes.to_string b

let shuffled_index ~index ~count ~seed ~rounds =
  let index = ref index in
  for round = 0 to rounds - 1 do
    let r = String.make 1 (Char.chr (round land 0xff)) in
    let h = sha256 (seed ^ r) in
    let pivot =
      Int64.(to_int (unsigned_rem (String.get_int64_le h 0) (of_int count)))
    in
    let flip = (pivot + count - !index) mod count in
    let position = max !index flip in
    let b = Bytes.create 4 in
    Bytes.set_int32_le b 0 (Int32.of_int (position / 256));
    let source = sha256 (seed ^ r ^ Bytes.to_string b) in
    let byte = Char.code source.[position mod 256 / 8] in
    if (byte lsr (position mod 8)) land 1 = 1 then index := flip
  done;
  !index

(* The numbers come as Num.t: arithmetic in the spec can give an `Int. *)
let compute_shuffled_index_rounds ~at (index : Num.t) (count : Num.t)
    (seed : Value.t) (rounds : Num.t) : Value.t result =
  match
    ( Bigint.to_int (Num.to_int index),
      Bigint.to_int (Num.to_int count),
      (try Some (seed_bytes seed) with Exit -> None),
      Bigint.to_int (Num.to_int rounds) )
  with
  | Some index, Some count, Some seed, Some rounds
    when 0 <= index && index < count && rounds >= 0 ->
      Ok
        (Value.nat
           (Bigint.of_int (shuffled_index ~index ~count ~seed ~rounds)))
  | _ -> Error (runtime at "compute_shuffled_index: index must be < count")

let builtins : (string * Define.t) list =
  [
    ( "compute_shuffled_index_rounds",
      Define.T0.a4 Arg.num Arg.num Arg.value Arg.num
        compute_shuffled_index_rounds );
  ]
