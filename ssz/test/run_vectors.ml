(* Checks every case of a JSONL vector file against
   the named-type schema it refers to. *)

let hex s =
  "0x"
  ^ String.concat ""
      (List.init (String.length s) (fun i ->
           Printf.sprintf "%02x" (Char.code s.[i])))

let run schema cases_path =
  let schema =
    match Ssz_schema.load schema with
    | Ok s -> s
    | Error e -> failwith (schema ^ ": " ^ e)
  in
  let ic = open_in cases_path in
  let passed = ref 0 and failed = ref 0 in
  (try
     while true do
       let case = Yojson.Safe.from_string (input_line ic) in
       let field k = Yojson.Safe.Util.member k case in
       let id = Yojson.Safe.Util.to_string (field "id") in
       let result =
         Result.bind
           (Ssz_schema.typ_of_json schema (field "type"))
           (fun t ->
             Result.bind
               (Ssz_schema.value_of_json t (field "value"))
               (Ssz.hash_tree_root t))
       in
       let want = Yojson.Safe.Util.to_string (field "root") in
       match result with
       | Ok root when hex root = want -> incr passed
       | Ok root ->
           incr failed;
           if !failed <= 20 then
             Printf.printf "FAIL %s: got %s want %s\n" id (hex root) want
       | Error e ->
           incr failed;
           if !failed <= 20 then Printf.printf "FAIL %s: %s\n" id e
     done
   with End_of_file -> close_in ic);
  Printf.printf "%s: %d passed, %d failed\n"
    (Filename.basename cases_path)
    !passed !failed;
  !failed = 0

let () =
  let dir =
    match (Sys.getenv_opt "SSZ_VECTORS", Sys.getenv_opt "DUNE_SOURCEROOT") with
    | Some d, _ -> d
    | None, Some root ->
        List.find_opt Sys.file_exists
          [
            Filename.concat root "_vectors"; Filename.concat root "ssz/_vectors";
          ]
        |> Option.value ~default:(Filename.concat root "_vectors")
    | None, None -> "_vectors"
  in
  let cases = Filename.concat dir "ssz_specs.jsonl" in
  if not (Sys.file_exists cases) then (
    Printf.printf "SKIP: no vectors in %s (run scripts/fetch-vectors.sh)\n" dir;
    if Sys.getenv_opt "SSZ_REQUIRE_VECTORS" = Some "1" then exit 1)
  else if not (run (Filename.concat dir "ssz_specs.json") cases) then exit 1
