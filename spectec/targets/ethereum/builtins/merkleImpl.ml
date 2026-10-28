open Lang.Il
open Lang.Xl
open Builtins
open Error

let ( let* ) = Result.bind

module Bytes = Stdlib.Bytes

(* Helpers *)
let pow2_8 (n : int) = Bigint.pow (Bigint.of_int 2) (Bigint.of_int (8 * n))

let ensure_fits_bytes ~at (n : Bigint.t) ~(len : int) : unit result =
  if Bigint.(n >= zero && n < pow2_8 len) then Ok ()
  else Error (runtime at (Printf.sprintf "value does not fit in %d bytes" len))

let be_of_bigint_fixed (n : Bigint.t) ~(len : int) : Bytes.t =
  if Bigint.(n < zero) then invalid_arg "negative";
  let out = Bytes.create len in
  let rec fill i v =
    if i < 0 then ()
    else
      let byte = Bigint.to_int_exn Bigint.(v % of_int 256) in
      Bytes.set out i (Stdlib.Char.chr byte);
      fill (i - 1) Bigint.(v / of_int 256)
  in
  fill (len - 1) n;
  out

let bigint_of_be_bytes (b : Bytes.t) : Bigint.t =
  let acc = ref Bigint.zero in
  for i = 0 to Bytes.length b - 1 do
    let v = Stdlib.Char.code (Bytes.get b i) in
    acc := Bigint.((!acc * of_int 256) + of_int v)
  done;
  !acc

let sha256_bytes32 (x : Bytes.t) : Bigint.t =
  let open Digestif.SHA256 in
  digest_bytes x |> to_raw_string |> Bytes.of_string |> bigint_of_be_bytes

(* dec $is_valid_merkle_branch(bytes32, bytes32*, uint64, uint64, root) : boolean *)
let is_valid_merkle_branch ~at (leaf : Num.t) (branch : Num.t list)
    (depth : Num.t) (index : Num.t) (root : Num.t) : Value.t result =
  let leaf = Num.to_int leaf in
  let branch = List.map Num.to_int branch in
  let depth = Num.to_int depth in
  let index = Num.to_int index in
  let root = Num.to_int root in
  (* Validate inputs *)
  let* () = ensure_fits_bytes ~at leaf ~len:32 in
  let* () = ensure_fits_bytes ~at root ~len:32 in
  let* () = ensure_fits_bytes ~at depth ~len:8 in
  let* () = ensure_fits_bytes ~at index ~len:8 in
  let* () =
    let rec check_all = function
      | [] -> Ok ()
      | x :: xs ->
          let* () = ensure_fits_bytes ~at x ~len:32 in
          check_all xs
    in
    check_all branch
  in
  (* Convert depth to int for loop bounds *)
  let depth_int = try Bigint.to_int_exn depth with _ -> -1 in
  if depth_int < 0 then Error (runtime at "depth too large")
  else if List.length branch < depth_int then
    Error (runtime at "branch shorter than depth")
  else
    (* Loop *)
    let rec iter i (value : Bigint.t) : Bigint.t =
      if i >= depth_int then value
      else
        let sibling = List.nth branch i in
        (* parity = (index >> i) & 1 *)
        let bit_i = Bigint.(bit_and (shift_right index i) (of_int 1)) in
        let left, right =
          if Bigint.(bit_i = zero) then (* value || sibling *) (value, sibling)
          else (sibling, value)
        in
        let b_left = be_of_bigint_fixed left ~len:32 in
        let b_right = be_of_bigint_fixed right ~len:32 in
        let cat = Bytes.create 64 in
        Bytes.blit b_left 0 cat 0 32;
        Bytes.blit b_right 0 cat 32 32;
        let value' = sha256_bytes32 cat in
        iter (i + 1) value'
    in
    let computed = iter 0 leaf in
    Ok (Value.bool Bigint.(computed = root))

let builtins : (string * Define.t) list =
  [
    ( "is_valid_merkle_branch",
      Define.T0.a5 Arg.num (Arg.list_of Arg.num) Arg.num Arg.num Arg.num
        is_valid_merkle_branch );
  ]
