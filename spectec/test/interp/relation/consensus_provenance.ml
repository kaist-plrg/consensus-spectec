module Il = Lang.Il
module Provenance = Instrumentation.Dependency.Provenance_hooks
module Positive = Instrumentation.Dependency.Positive

let spec = Harness.compile_file "consensus_provenance.spectec"

let tdenv =
  List.fold_left
    (fun env (def : Il.def) ->
      match def.it with
      | TypD { synid; tparams; deftyp } ->
          Envs.Il.TDEnv.add synid (tparams, deftyp) env
      | _ -> env)
    Envs.Il.TDEnv.empty spec.spec_il

let decode source =
  match
    Json.Parse.json_to_value
      ~provenance:(Some (source, []))
      tdenv
      (Il.Typ.list
         Common.Annotated.(Il.Typ.var "point" [] $ Common.Location.Unknown))
      (`List [ `Assoc [ ("x", `Int 0); ("y", `Int 2) ] ])
  with
  | Ok value -> value
  | Error _ -> failwith "provenance fixture JSON decoding failed"

let config () =
  let handler, _ =
    Positive.make_with_data
      {
        level = Positive.Summary;
        output = Instrumentation.Output.quiet;
        target_uids = Some [];
      }
  in
  [
    {
      Instrumentation.Handler.Config.name = "custom-provenance";
      modes = [ `IL ];
      handler = (module (val handler) : Instrumentation.Handler.S);
      output = Instrumentation.Output.quiet;
    };
  ]

let evaluate relation ~config ~sources =
  let input =
    Value_handlers.input relation (fun () -> List.map decode sources)
  in
  match
    Spectec.eval_task_with_instrumentation
      (module Value_handlers.Task)
      ~config ~mode:Il ~spec_il:spec.spec_il input
  with
  | Ok [ value ] -> Provenance.provenance_of value
  | _ -> failwith ("provenance fixture failed: " ^ relation)

(* One batch session runs every input, and vids restart for each input, so the
   last input's values reuse the vids of earlier inputs' values. *)
let evaluate_last_in_batch relation ~config ~sources =
  let inputs =
    List.map
      (fun source ->
        Value_handlers.input relation (fun () -> [ decode source ]))
      sources
  in
  match
    Batch.run_batch_with_outcomes
      (module Value_handlers.Task)
      ~config ~ansi:Spectec.Diagnostic.Ansi.plain ~mode:Il ~spec_il:spec.spec_il
      inputs
    |> List.rev
  with
  | { outcome = Spectec.Task.Pass [ value ]; _ } :: _ ->
      Provenance.provenance_of value
  | _ -> failwith ("provenance batch fixture failed: " ^ relation)

let require_x ~source origins =
  assert (List.mem (source, [ Il.IndexAccess 0; Il.FieldAccess "x" ]) origins);
  assert (
    not (List.mem (source, [ Il.IndexAccess 0; Il.FieldAccess "y" ]) origins));
  assert (not (List.mem (source, [ Il.IndexAccess 0 ]) origins))

let exp typ node : Il.exp =
  Common.Annotated.(
    node $$ (Common.Location.Unknown, { Il.Expression.typ; annot = () }))

let hidden_operand_forms_suggest_nothing () =
  let next_vid = ref 0 in
  let fresh_vid () =
    incr next_vid;
    !next_vid
  in
  Il.Value.GlobalVidProvider.with_provider fresh_vid @@ fun () ->
  let nat = Common.Annotated.(Il.Typ.nat $ Common.Location.Unknown) in
  let element = Il.Value.nat Bigint.one in
  let elements = Il.Value.list nat [ element ] in
  let found = Il.Value.bool true in
  let negative = Il.Value.int Bigint.minus_one in
  let origin = Instrumentation.Origin.make ~label:"state" in
  Provenance.clear ();
  List.iter Provenance.handle_value
    [
      Instrumentation.Value_event.Decoded { value = element; origin };
      Decoded { value = elements; origin };
      Combined { value = found; sources = [ element; elements ] };
      Derived { value = negative; source = element };
    ];
  let var name =
    exp (Il.NumT `NatT) (VarE Common.Annotated.(name $ Common.Location.Unknown))
  in
  let member = exp Il.BoolT (MemE (var "x", var "xs")) in
  let subtype = exp Il.BoolT (SubE (var "x", nat)) in
  let empty = exp Il.BoolT (MatchE (var "xs", ListP `Nil)) in
  let minus = exp (Il.NumT `IntT) (UnE (`MinusOp, `IntT, var "x")) in
  let five = exp (Il.NumT `NatT) (NumE (`Nat (Bigint.of_int 5))) in
  let not_ test = exp Il.BoolT (UnE (`NotOp, `BoolT, test)) in
  let lookup e =
    if e == member || e == subtype || e == empty then Some found
    else if e == minus then Some negative
    else if e == five then Some (Il.Value.nat (Bigint.of_int 5))
    else None
  in
  List.iter
    (fun test -> assert (Positive.extract_symbolic_mutations lookup test = []))
    [
      member;
      subtype;
      not_ empty;
      exp Il.BoolT (CmpE (`LtOp, `IntT, minus, five));
      exp Il.BoolT
        (CallE
           ( Common.Annotated.("opaque" $ Common.Location.Unknown),
             [],
             [
               Common.Annotated.(
                 Il.Expression.ExpA member $ Common.Location.Unknown);
             ] ));
    ]

(* Every interpreter reports a fold's output list as built from the list the
   fold ranges over. *)
let fold_outputs_name_ranged_lists () =
  let ranged = decode Il.JsonState in
  let output =
    Il.Value.list
      Common.Annotated.(Il.Typ.nat $ Common.Location.Unknown)
      [ Il.Value.nat Bigint.zero ]
  in
  List.iter
    (fun mode ->
      let log = ref [] in
      let input =
        Value_handlers.input "Running_x" (fun () ->
            [ decode Il.JsonState; decode Il.JsonBlock ])
      in
      (match
         Spectec.eval_task_with_instrumentation
           (module Value_handlers.Task)
           ~config:[ Value_handlers.recorder ~name:"recorder" ~log ]
           ~mode ~spec_il:spec.spec_il input
       with
      | Ok _ -> ()
      | Error _ -> failwith "fold event fixture failed");
      assert (
        List.exists
          (function
            | _, Instrumentation.Value_event.Combined { value; sources } ->
                Il.Value.eq value output
                && List.exists (Il.Value.eq ranged) sources
            | _ -> false)
          !log))
    [ Spectec.Interp_mode.Il; Sl; Pl spec.henv ]

let run () =
  hidden_operand_forms_suggest_nothing ();
  fold_outputs_name_ranged_lists ();
  let config = config () in
  let first = evaluate "Feedback" ~config ~sources:[ Il.JsonState ] in
  require_x ~source:Il.JsonState first;
  let second = evaluate "Feedback" ~config ~sources:[ Il.JsonBlock ] in
  require_x ~source:Il.JsonBlock second;
  assert (not (List.exists (fun (source, _) -> source = Il.JsonState) second));
  let batched =
    evaluate_last_in_batch "Feedback" ~config
      ~sources:[ Il.JsonState; Il.JsonBlock ]
  in
  require_x ~source:Il.JsonBlock batched;
  assert (not (List.exists (fun (source, _) -> source = Il.JsonState) batched));
  let totals =
    evaluate "Running_x" ~config ~sources:[ Il.JsonState; Il.JsonBlock ]
  in
  assert (List.mem (Il.JsonState, []) totals);
  assert (not (List.exists (fun (source, _) -> source = Il.JsonBlock) totals))
