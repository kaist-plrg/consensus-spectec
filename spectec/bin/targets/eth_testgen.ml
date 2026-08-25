open Targets_eth.Eth

let render_error error =
  Spectec.Diagnostic.Render.render_bag ~ansi:Spectec.Diagnostic.Ansi.plain
    (Spectec.Error.to_diagnostics error)

let load_spec spec_dir =
  let files = Spectec.collect_spec_files spec_dir in
  match Result.bind (Spectec.parse_spec_files files) Spectec.elaborate with
  | Ok spec -> spec
  | Error error -> failwith (render_error error)

let print_uncovered coverage =
  let uncovered = Runner.Testgen.get_uncovered_premises coverage in
  Format.printf "Uncovered Premises (%d total):\n\n" (List.length uncovered);
  List.iter
    (fun (premise : Runner.Testgen.premise_info) ->
      let test_cases =
        Runner.Testgen.get_test_cases_for_premise premise.uid coverage
      in
      Format.printf "  UID %d: %s/%s\n" premise.uid premise.relation
        premise.rule;
      Format.printf "    Content: %s\n" premise.content;
      if test_cases = [] then Format.printf "    Test cases: (none)\n"
      else (
        Format.printf "    Test cases that succeeded this premise (%d):\n"
          (List.length test_cases);
        List.iter
          (fun test_id -> Format.printf "      - %s\n" test_id)
          test_cases);
      Format.printf "\n")
    uncovered;
  uncovered

let initialize_static spec =
  List.iter
    (fun (module M : Instrumentation.Static.S) ->
      Instrumentation.Static.register (module M))
    (Instrumentation.Dependency.Positive.static_dependencies ());
  Instrumentation.Static.reset_all ();
  Instrumentation.Static.init_all (Instrumentation.Static.IlSpec spec)

let analyze_test_case ~spec ~test_dir test_id target_uids =
  let pre_file = Runner.Testgen.resolve_pre_path ~test_dir test_id in
  let block_file = Filename.concat (Filename.dirname pre_file) "block.json" in
  if not (Sys.file_exists pre_file) then (
    Format.printf "  Skipped: file not found: %s\n%!" pre_file;
    None)
  else if not (Sys.file_exists block_file) then (
    Format.printf "  Skipped: file not found: %s\n%!" block_file;
    None)
  else
    let input =
      StateTransition.make ~validate_result:true ~pre_file ~block_file ()
    in
    let handler, get_result =
      Instrumentation.Dependency.Positive.make_with_data
        {
          level = Instrumentation.Dependency.Positive.Summary;
          output = Instrumentation.Output.quiet;
          target_uids = Some target_uids;
        }
    in
    let handlers = [ (module (val handler) : Instrumentation.Handler.S) ] in
    Instrumentation.Dependency.Provenance_hooks.clear ();
    Instrumentation.Value_hooks.set
      Instrumentation.Dependency.Provenance_hooks.hooks;
    Instrumentation.Dispatcher.init ~spec:(Instrumentation.Handler.IlSpec spec)
      ~handlers;
    let result =
      Fun.protect
        ~finally:(fun () ->
          Instrumentation.Dispatcher.finish ();
          Instrumentation.Value_hooks.reset ())
        (fun () ->
          Instrumentation.Dispatcher.emit
            (Instrumentation.Event.Test_start { test_case_id = test_id });
          Fun.protect
            ~finally:(fun () ->
              Instrumentation.Dispatcher.emit
                (Instrumentation.Event.Test_end { test_case_id = test_id }))
            (fun () ->
              Spectec.eval_task
                (module StateTransition)
                ~mode:Spectec.Interp_mode.Il ~spec_il:spec input))
    in
    match result with
    | Ok _ | Error (Spectec.Error.InterpError _) -> Some (get_result ())
    | Error error ->
        Format.printf "  Skipped: %s\n%!" (render_error error);
        None

let command =
  Core.Command.basic
    ~summary:"Generate tests targeting uncovered Ethereum premises"
  @@
  let open Core.Command.Let_syntax in
  let open Core.Command.Param in
  let%map coverage_file =
    flag "--coverage" (required string) ~doc:"FILE coverage checkpoint"
  and test_dir =
    flag "--test-dir"
      (optional_with_default test_dir string)
      ~doc:"DIR original test cases"
  and output_dir =
    flag "--output"
      (optional_with_default "./testgen_output" string)
      ~doc:"DIR generated test cases"
  and premise_uids =
    flag "--premises" (listed int) ~doc:"UID premise UIDs to target"
  and premises_file =
    flag "--premises-file" (optional string)
      ~doc:"FILE premise UIDs, one per line"
  and list_only =
    flag "--list" no_arg ~doc:" list uncovered premises without generating"
  and verify = flag "--verify" no_arg ~doc:" verify generated tests"
  and checkpoint_file =
    flag "--checkpoint" (optional string) ~doc:"FILE save generation progress"
  and resume_file =
    flag "--resume" (optional string) ~doc:"FILE resume generation progress"
  and save_interval =
    flag "--save-interval"
      (optional_with_default 100 int)
      ~doc:"N save progress every N tests"
  and filter_seeds =
    flag "--filter-seeds" (optional string)
      ~doc:"TYPE select sanity, finality, or random seeds"
  and coverage_level =
    flag "--coverage-level"
      (optional_with_default 0 int)
      ~doc:"N select seeds with greedy K-cover"
  and max_slot_gap =
    flag "--max-slot-gap"
      (optional_with_default 32 int)
      ~doc:"N maximum block and state slot gap"
  and spec_dir =
    flag "--spec-dir"
      (optional_with_default Target.spec_dir string)
      ~doc:"DIR Ethereum specification files"
  in
  fun () ->
    try
      let _checkpoint, coverage, _dependency =
        Runner.Testgen.load_checkpoint coverage_file
      in
      (match coverage with
      | Some result ->
          Instrumentation.Premise_uid.restore
            (result.prem_to_uid, result.uid_to_prem)
      | None ->
          Format.eprintf "Warning: checkpoint has no premise coverage data\n%!");
      if list_only then ignore (print_uncovered coverage)
      else
        let file_uids =
          match premises_file with
          | Some file -> Runner.Uid_parser.parse_uid_file file
          | None -> []
        in
        let target_uids = premise_uids @ file_uids in
        if target_uids = [] then (
          Format.printf
            "No premise UIDs specified. Use --premises or --premises-file.\n%!";
          ignore (print_uncovered coverage))
        else (
          if not (Sys.file_exists output_dir) then Unix.mkdir output_dir 0o755;
          let spec = load_spec spec_dir in
          initialize_static spec;
          let results =
            Runner.Testgen.generate_tests_with_checkpoint ~test_dir ~output_dir
              ~checkpoint_file ~resume_file ~save_interval ~filter_seeds
              ~coverage_level ~max_slot_gap target_uids coverage
              (analyze_test_case ~spec ~test_dir)
          in
          ignore results;
          if verify then
            Format.printf
              "Verification is not implemented for test-case-centric mode\n%!")
    with exn ->
      Format.eprintf "Error: %s\n%!" (Printexc.to_string exn);
      exit 1
