type typ =
  | Uint of int
  | Boolean
  | Vector of typ * int
  | List of typ * int
  | Bitvector of int
  | Bitlist of int
  | Container of (string * typ) list
  | Progressive_list of typ
  | Progressive_bitlist
  | Progressive_container of {
      active_fields : bool list;
      fields : (string * typ) list;
    }
  | Compatible_union of (int * typ) list

type value =
  | Uint of string
  | Bool of bool
  | Bytes of string
  | Seq of value list
  | Bits of bool list
  | Fields of value list
  | Union of int * value

(* Mismatch carries the path from the root value down to the offending part. *)
exception Mismatch of string list * string

let fail fmt = Printf.ksprintf (fun msg -> raise (Mismatch ([], msg))) fmt

let at step f x =
  try f x with Mismatch (path, msg) -> raise (Mismatch (step :: path, msg))

(* Merkleization *)

let hash a b = Digestif.SHA256.(to_raw_string (digestv_string [ a; b ]))
let zero_chunk = String.make 32 '\000'

let zero_hashes =
  let a = Array.make 65 zero_chunk in
  for i = 1 to 64 do
    a.(i) <- hash a.(i - 1) a.(i - 1)
  done;
  a

let zero_hash depth = zero_hashes.(depth)

(* Smallest d with 2^d >= n. *)
let rec ceil_log2 n = if n <= 1 then 0 else 1 + ceil_log2 ((n + 1) / 2)

(* Root over chunks.(off) .. chunks.(off + n - 1), padded with zero subtrees to
   depth [ceil_log2 limit]. *)
let merkleize_sub chunks off n limit =
  let depth = ceil_log2 limit in
  if n = 0 then zero_hashes.(depth)
  else
    let rec up level layer =
      if level = depth then layer.(0)
      else
        let len = Array.length layer in
        let next =
          Array.init
            ((len + 1) / 2)
            (fun i ->
              let r =
                if (2 * i) + 1 < len then layer.((2 * i) + 1)
                else zero_hashes.(level)
              in
              hash layer.(2 * i) r)
        in
        up (level + 1) next
    in
    up 0 (Array.sub chunks off n)

let merkleize_array ?limit chunks =
  let n = Array.length chunks in
  let limit =
    match limit with
    | None -> n
    | Some l when n > l -> fail "%d chunks exceed limit %d" n l
    | Some l -> l
  in
  merkleize_sub chunks 0 n limit

(* EIP-7916: level k holds 4^k chunks; hash(level subtree, rest of the spine). *)
let merkleize_progressive_array chunks =
  let total = Array.length chunks in
  let rec go off num_leaves =
    if off >= total then zero_chunk
    else
      let n = min num_leaves (total - off) in
      hash
        (merkleize_sub chunks off n num_leaves)
        (go (off + n) (num_leaves * 4))
  in
  go 0 1

let word_of_int n =
  let b = Bytes.make 32 '\000' in
  Bytes.set_int64_le b 0 (Int64.of_int n);
  Bytes.to_string b

let mix_in_length root n = hash root (word_of_int n)

(* Packing *)

let chunks_of_string s =
  let n = (String.length s + 31) / 32 in
  Array.init n (fun i ->
      let len = min 32 (String.length s - (i * 32)) in
      if len = 32 then String.sub s (i * 32) 32
      else String.sub s (i * 32) len ^ String.make (32 - len) '\000')

let pack_bits bits =
  let n = List.length bits in
  let b = Bytes.make ((n + 7) / 8) '\000' in
  List.iteri
    (fun i bit ->
      if bit then
        let c = Char.code (Bytes.get b (i / 8)) in
        Bytes.set b (i / 8) (Char.chr (c lor (1 lsl (i mod 8)))))
    bits;
  Bytes.to_string b

let basic_size : typ -> int option = function
  | Uint n -> Some n
  | Boolean -> Some 1
  | _ -> None

let serialize_basic (t : typ) (v : value) =
  match (t, v) with
  | Uint n, Uint s when String.length s = n -> s
  | Uint n, Uint s -> fail "uint%d given %d bytes" (n * 8) (String.length s)
  | Boolean, Bool b -> if b then "\001" else "\000"
  | Uint n, _ -> fail "expected uint%d value" (n * 8)
  | _ -> fail "expected boolean value"

(* Serialized elements of a basic-typed sequence, and their count. *)
let packed elem size (v : value) =
  match v with
  | Bytes s ->
      if String.length s mod size <> 0 then
        fail "%d bytes is not a whole number of %d-byte elements"
          (String.length s) size;
      (s, String.length s / size)
  | Seq vs ->
      let buf = Buffer.create (size * List.length vs) in
      List.iteri
        (fun i e ->
          at (string_of_int i)
            (fun e -> Buffer.add_string buf (serialize_basic elem e))
            e)
        vs;
      (Buffer.contents buf, List.length vs)
  | _ -> fail "expected a sequence of basic values"

let packed_basic elem v =
  let size = Option.get (basic_size elem) in
  let s, count = packed elem size v in
  (size, s, count)

let chunk_limit count size = ((count * size) + 31) / 32

let rec root (t : typ) (v : value) : string =
  match (t, v) with
  | (Uint _ | Boolean), _ -> (chunks_of_string (serialize_basic t v)).(0)
  | Vector (elem, n), _ when basic_size elem <> None ->
      let size, s, count = packed_basic elem v in
      if count <> n then fail "vector of length %d given %d elements" n count;
      merkleize_array ~limit:(chunk_limit n size) (chunks_of_string s)
  | List (elem, n), _ when basic_size elem <> None ->
      let size, s, count = packed_basic elem v in
      if count > n then fail "list limit %d exceeded by %d elements" n count;
      mix_in_length
        (merkleize_array ~limit:(chunk_limit n size) (chunks_of_string s))
        count
  | Progressive_list elem, _ when basic_size elem <> None ->
      let _, s, count = packed_basic elem v in
      mix_in_length (merkleize_progressive_array (chunks_of_string s)) count
  | Vector (elem, n), Seq vs ->
      if List.length vs <> n then
        fail "vector of length %d given %d elements" n (List.length vs);
      merkleize_array ~limit:n (roots elem vs)
  | List (elem, n), Seq vs ->
      let count = List.length vs in
      if count > n then fail "list limit %d exceeded by %d elements" n count;
      mix_in_length (merkleize_array ~limit:n (roots elem vs)) count
  | Progressive_list elem, Seq vs ->
      mix_in_length
        (merkleize_progressive_array (roots elem vs))
        (List.length vs)
  | Bitvector n, Bits bs ->
      if List.length bs <> n then
        fail "bitvector of length %d given %d bits" n (List.length bs);
      merkleize_array ~limit:((n + 255) / 256) (chunks_of_string (pack_bits bs))
  | Bitlist n, Bits bs ->
      let count = List.length bs in
      if count > n then fail "bitlist limit %d exceeded by %d bits" n count;
      mix_in_length
        (merkleize_array
           ~limit:((n + 255) / 256)
           (chunks_of_string (pack_bits bs)))
        count
  | Progressive_bitlist, Bits bs ->
      mix_in_length
        (merkleize_progressive_array (chunks_of_string (pack_bits bs)))
        (List.length bs)
  | Container fields, Fields vs ->
      merkleize_array (Array.of_list (field_roots fields vs))
  | Progressive_container { active_fields; fields }, Fields vs ->
      (* One leaf per layout position; an inactive position is a zero leaf. *)
      let rec leaves active rs =
        match (active, rs) with
        | [], _ -> []
        | true :: active, r :: rs -> r :: leaves active rs
        | false :: active, rs -> zero_chunk :: leaves active rs
        | true :: _, [] -> fail "active_fields has more set bits than fields"
      in
      let layout = pack_bits active_fields ^ String.make 32 '\000' in
      hash
        (merkleize_progressive_array
           (Array.of_list (leaves active_fields (field_roots fields vs))))
        (String.sub layout 0 32)
  | Compatible_union options, Union (selector, data) -> (
      match List.assoc_opt selector options with
      | None -> fail "selector %d is not an option" selector
      | Some opt ->
          hash
            (at (Printf.sprintf "<%d>" selector) (root opt) data)
            (word_of_int selector))
  | _ -> fail "value does not match type"

and roots elem vs =
  Array.of_list (List.mapi (fun i e -> at (string_of_int i) (root elem) e) vs)

and field_roots fields vs =
  if List.length fields <> List.length vs then
    fail "container of %d fields given %d values" (List.length fields)
      (List.length vs);
  List.map2 (fun (name, t) v -> at name (root t) v) fields vs

let hash_tree_root t v =
  try Ok (root t v)
  with Mismatch (path, msg) ->
    Error (if path = [] then msg else String.concat "." path ^ ": " ^ msg)

let hash_tree_root_exn t v =
  match hash_tree_root t v with
  | Ok r -> r
  | Error msg -> invalid_arg ("Ssz.hash_tree_root: " ^ msg)

let uint64 n =
  let b = Bytes.create 8 in
  Bytes.set_int64_le b 0 n;
  Uint (Bytes.to_string b)

let uint_of_int ~size n =
  if n < 0 then invalid_arg "Ssz.uint_of_int: negative";
  let b = Bytes.make size '\000' in
  let rec fill i n =
    if n <> 0 then
      if i >= size then invalid_arg "Ssz.uint_of_int: too large"
      else (
        Bytes.set b i (Char.chr (n land 0xff));
        fill (i + 1) (n lsr 8))
  in
  fill 0 n;
  Uint (Bytes.to_string b)

let wrap f = try f () with Mismatch (_, msg) -> invalid_arg ("Ssz: " ^ msg)

let merkleize ?limit chunks =
  wrap (fun () -> merkleize_array ?limit (Array.of_list chunks))

let merkleize_progressive chunks =
  merkleize_progressive_array (Array.of_list chunks)
