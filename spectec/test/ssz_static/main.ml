(* Roots of ssz_static cases, computed the way the executor computes them.

     main.exe FORK PRESET CASES.jsonl

   CASES comes from spec/ssz/build_static.py. Each case whose type SpecTec defines
   carries the Converter's JSON for it; that JSON is parsed as the SpecTec type,
   exactly as test inputs are, then merkleized by the hash_tree_root builtins. *)

open Lang

let hex s =
  "0x"
  ^ String.concat ""
      (List.init (String.length s) (fun i ->
           Printf.sprintf "%02x" (Char.code s.[i])))

let fail fmt = Printf.ksprintf failwith fmt

let () =
  let fork, preset, cases =
    match Sys.argv with
    | [| _; fork; preset; cases |] -> (fork, preset, cases)
    | _ -> fail "usage: main.exe FORK PRESET CASES.jsonl"
  in
  let root = Sys.getenv_opt "DUNE_SOURCEROOT" |> Option.value ~default:"." in
  let spec_il =
    let dir = Filename.concat root ("spec/spec_" ^ fork) in
    let files =
      Sys.readdir dir |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".spectec")
      |> List.sort compare
      |> List.map (Filename.concat dir)
    in
    match Result.bind (Spectec.parse_spec_files files) Spectec.elaborate with
    | Ok il -> il
    | Error _ -> fail "cannot elaborate %s" dir
  in
  let tdenv = Targets_eth.Eth_common.build_tdenv spec_il in
  (* SSZ container name -> SpecTec struct name *)
  let spectec_name =
    let schema =
      Yojson.Safe.from_file
        (Filename.concat root
           (Printf.sprintf "spec/ssz/%s-%s.json" fork preset))
    in
    Yojson.Safe.Util.(
      schema |> member "x-spectec" |> member "types" |> to_assoc)
    |> List.map (fun (st, ssz) -> (Yojson.Safe.Util.to_string ssz, st))
  in
  (match Builtin_eth.SszImpl.configure ~fork ~preset with
  | Ok () -> ()
  | Error e -> failwith e);
  let at = Common.Source.no_region in
  let passed = ref 0 and failed = ref 0 and skipped = ref 0 in
  let report id msg =
    incr failed;
    if !failed <= 20 then Printf.printf "FAIL %s: %s\n" id msg
  in
  In_channel.with_open_text cases (fun ic ->
      Seq.iter
        (fun line ->
          let case = Yojson.Safe.from_string line in
          let field k = Yojson.Safe.Util.member k case in
          let id = Yojson.Safe.Util.to_string (field "id") in
          let ssz_name = Yojson.Safe.Util.to_string (field "type") in
          match (field "spectec", List.assoc_opt ssz_name spectec_name) with
          | `Null, _ | _, None -> incr skipped
          | json, Some st -> (
              let want = Yojson.Safe.Util.to_string (field "root") in
              match
                Interface.JSON.Parse.json_to_value tdenv (Il.Typ.var st []) json
              with
              | Error e -> report id (Interface.JSON.Parse.string_of_error e)
              | Ok v -> (
                  match
                    Result.bind (Builtin_eth.SszImpl.lookup ~at ssz_name)
                      (fun t -> Builtin_eth.SszImpl.root ~at t v)
                  with
                  | Ok r when hex r = want -> incr passed
                  | Ok r ->
                      report id (Printf.sprintf "got %s want %s" (hex r) want)
                  | Error _ -> report id "hash_tree_root failed")))
        (Seq.of_dispenser (fun () -> In_channel.input_line ic)));
  Printf.printf "%s-%s: %d passed, %d failed, %d without a SpecTec type\n" fork
    preset !passed !failed !skipped;
  if !failed > 0 then exit 1
