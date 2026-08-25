let key = (Common.Source.no_region, "if x")

let node_coverage : Instrumentation.Node_coverage_il.result =
  {
    prems_attempted = [ (key, 1) ];
    prems_succeeded = [ (key, 1) ];
    prem_to_uid = [ (key, 7) ];
    uid_to_prem = [ (7, key) ];
    prem_to_test = [ (key, [ "case/pre.json" ]) ];
    total_prems = 1;
  }

let positive : Instrumentation.Dependency.Positive.result =
  { per_test_sym_mutations = [] }

let with_temp_checkpoint f =
  let file = Filename.temp_file "spectec-testgen-checkpoint" ".bin" in
  Fun.protect ~finally:(fun () -> Sys.remove file) (fun () -> f file)

let check_loaded expected_coverage expected_dependency file =
  let checkpoint, coverage, dependency = Runner.Testgen.load_checkpoint file in
  assert (checkpoint.completed_inputs = [ "case/pre.json" ]);
  assert (coverage = Some expected_coverage);
  assert (dependency = Some expected_dependency)

let save_batch file =
  let coverage =
    [
      ("premise-coverage", Marshal.to_bytes node_coverage []);
      ("dep-pos", Marshal.to_bytes positive []);
    ]
  in
  let checkpoint =
    Batch.Checkpoint.create ~spec_files:[] ~completed_inputs:[ "case/pre.json" ]
      ~coverage
  in
  Batch.Checkpoint.save_to_file ~file checkpoint

let check_batch () =
  with_temp_checkpoint @@ fun file ->
  save_batch file;
  check_loaded node_coverage positive file;
  print_endline "batch checkpoint: ok"

let check_legacy () =
  with_temp_checkpoint @@ fun file ->
  let coverage : Runner.Checkpoint.coverage =
    {
      branch = None;
      node_il = Some node_coverage;
      node_sl = None;
      dependency = Some positive;
      testgen = None;
    }
  in
  let checkpoint : Runner.Checkpoint.t =
    {
      spec_hash = "";
      completed_inputs = [ "case/pre.json" ];
      coverage;
      timestamp = 0.;
    }
  in
  Runner.Checkpoint.save_to_file ~file checkpoint;
  check_loaded node_coverage positive file;
  print_endline "legacy checkpoint: ok"

let () =
  match Array.to_list Sys.argv with
  | [ _; file ] -> save_batch file
  | _ ->
      check_batch ();
      check_legacy ()
