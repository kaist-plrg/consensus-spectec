open Common.Attempt

let at = Common.Source.no_region
let check condition message = if not condition then failwith message

let () =
  let forced = ref 0 in
  let message () =
    incr forced;
    "outer failure"
  in
  let success = nest at message (Ok 42) in
  check (success = Ok 42 && !forced = 0) "success forced its failure message";
  let failure () = fail at "inner failure" |> nest at message in
  let chosen = choice [ failure; (fun () -> Ok 42) ] in
  check (chosen = Ok 42 && !forced = 0) "discarded failure forced its message";
  let guard_failure = fail_guard at "guard" |> nest at message in
  let pruned =
    match guard_failure with
    | Ok _ -> assert false
    | Error traces -> prune_failtraces traces
  in
  check (pruned = [] && !forced = 0) "pruned guard forced its message";
  let traces =
    match failure () with Ok _ -> assert false | Error traces -> traces
  in
  check (!forced = 0) "retained failure forced its message before diagnostics";
  let diagnostic =
    Diag.of_failtraces ~source:"test" ~fallback:"fallback" traces
  in
  check (!forced = 1) "diagnostic conversion did not force its message once";
  check
    (diagnostic.message = "outer failure")
    "diagnostic lost its outer message";
  match diagnostic.trace with
  | [ { message = "inner failure"; children = []; _ } ] -> ()
  | _ -> failwith "diagnostic lost its nested failure"
