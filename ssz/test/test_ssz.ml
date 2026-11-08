(* Hand-checkable roots; the spec vectors in run_vectors.ml are the real oracle. *)

let hex s =
  String.concat ""
    (List.init (String.length s) (fun i ->
         Printf.sprintf "%02x" (Char.code s.[i])))

let sha a b = Digestif.SHA256.(to_raw_string (digest_string (a ^ b)))
let z = String.make 32 '\000'

let check name got want =
  if got <> want then
    failwith (Printf.sprintf "%s: got %s want %s" name (hex got) (hex want))

let () =
  let open Ssz in
  check "zero_hash 1" (zero_hash 1) (sha z z);
  check "uint64 0" (hash_tree_root_exn (Uint 8) (uint64 0L)) z;
  let one = uint64 1L in
  let c1 = "\001" ^ String.make 31 '\000' in
  let le1 = "\001\000\000\000\000\000\000\000" in
  check "vector[uint64,5]"
    (hash_tree_root_exn (Vector (Uint 8, 5)) (Seq [ one; one; one; one; one ]))
    (sha (le1 ^ le1 ^ le1 ^ le1) c1);
  check "bytes = seq"
    (hash_tree_root_exn (List (Uint 1, 64)) (Bytes "ab"))
    (hash_tree_root_exn (List (Uint 1, 64)) (Seq [ Uint "a"; Uint "b" ]));
  check "empty list" (hash_tree_root_exn (List (Uint 8, 4)) (Seq [])) (sha z z);
  check "empty progressive list"
    (hash_tree_root_exn (Progressive_list (Uint 8)) (Seq []))
    (sha z z);
  (match
     hash_tree_root (Container [ ("a", Uint 8) ]) (Fields [ Bool true ])
   with
  | Error "a: expected uint64 value" -> ()
  | Error e -> failwith ("unexpected error: " ^ e)
  | Ok _ -> failwith "mismatch accepted");
  match hash_tree_root (List (Uint 8, 1)) (Seq [ one; one ]) with
  | Error _ -> ()
  | Ok _ -> failwith "over-limit list accepted"
