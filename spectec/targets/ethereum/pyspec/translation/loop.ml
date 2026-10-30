open Common.Source
open Lang.El
open Operand
open Ctx
open Branch
module S = Source
module B = Python_builtins

type completion = Returned of Operand.t | Broken | Fallthrough

type body = {
  promotions : (string * Kind.t) list;
  iterations : (Branch.t * [ `Continue | `Break ]) list;
}

type t =
  | Indexed of {
      sequence : Operand.t;
      index : Operand.t;
      access : Loop_plan.access;
      parent : string;
      initial : Branch.t;
      body : body;
    }
  | Conditional of { finished : Branch.t list; body : body }
  | Returning of {
      kind : Kind.t;
      continuing : Branch.t list;
      returned : (Branch.t * Operand.t) list;
    }

let parameter_types ctx at values =
  List.map
    (fun value -> Operand.typ ~types:ctx.source.types ~at value.kind)
    values

let carried_type ctx at carried =
  match
    List.map
      (fun (_, value) -> Operand.typ ~types:ctx.source.types ~at value.kind)
      carried
  with
  | [ typ ] -> typ
  | types -> TupleT types $ at

let carried_tuple at values =
  match values with [ value ] -> value | values -> TupleE values $ at

(* Python widens a plain integer accumulator to the unsigned class of the
   values added to it, so an iteration may end on that unsigned kind while an
   empty loop keeps the plain initial value. Both hold the same number, and
   the addition already carries the unsigned coercion and overflow premises,
   so the carried target type stays the plain integer. *)
let accumulated_width ctx at initial value =
  Kind.is_integer ~types:ctx.source.types ~at initial.kind
  && Kind.bits ~types:ctx.source.types ~at value.kind <> None

let carried_value ?(accumulates = false) ctx at carried branch =
  List.map
    (fun (name, initial) ->
      let value =
        Error.find_or_reject ~at ~name (Store.bindings branch.storage)
      in
      if
        value.kind <> initial.kind
        && not (accumulates && accumulated_width ctx at initial value)
      then Error.reject ~at "Loop-carried local type changes are unsupported";
      value.exp)
    carried
  |> carried_tuple at

(* The unsigned kind every iteration settles on for a plain integer that the
   body accumulates. A loop whose iterations disagree about the width has no
   single Python class and rejects. *)
let promotions ctx at carried iterations =
  List.filter_map
    (fun (name, initial) ->
      if not (Kind.is_integer ~types:ctx.source.types ~at initial.kind) then
        None
      else
        let kinds =
          List.filter_map
            (fun (iteration, _) ->
              let value =
                Error.find_or_reject ~at ~name
                  (Store.bindings iteration.storage)
              in
              if Kind.bits ~types:ctx.source.types ~at value.kind = None then
                None
              else Some value.kind)
            iterations
        in
        match List.sort_uniq Stdlib.compare kinds with
        | [] -> None
        | [ kind ] -> Some (name, kind)
        | _ ->
            Error.reject ~at
              "A loop-carried integer must accumulate one unsigned width")
    carried

let recursive_arguments at plan iteration =
  List.map
    (fun (name, value) ->
      if List.mem_assoc name plan.Loop_plan.carried then
        (Error.find_or_reject ~at ~name (Store.bindings iteration.storage)).exp
      else value.exp)
    plan.captures

let carried_body ~ctx ~at ~carried ~tests ~body ~rest iterations =
  let promotions = promotions ctx at carried iterations in
  Loop_plan.check_accumulation ~at ~promotions ~guards:tests body;
  Loop_plan.check_promoted_use ~promotions rest;
  let iterations =
    List.map
      (fun (branch, completion) ->
        let completion =
          match completion with
          | Fallthrough -> `Continue
          | Broken -> `Break
          | Returned _ ->
              Error.reject ~at "Returns inside loops are unsupported"
        in
        (branch, completion))
      iterations
  in
  { promotions; iterations }

let iteration_result ctx at carried (iteration, completion) continue =
  let carried_value =
    carried_value ~accumulates:true ctx at carried iteration
  in
  match completion with `Continue -> continue () | `Break -> carried_value

let bind_result ?(promotions = []) ctx at carried result branch =
  let outputs =
    List.map
      (fun (name, value) -> (name, fresh ctx ~at ~kind:value.kind))
      carried
  in
  let branch =
    guard ~at
      ~exp:
        (comparison ~at ~op:`EqOp result
           (carried_tuple at (List.map (fun (_, v) -> v.exp) outputs)))
      branch
  in
  let promoted =
    List.filter_map
      (fun (name, kind) ->
        Option.map
          (fun value -> (string_of_exp value.exp, kind))
          (List.assoc_opt name outputs))
      promotions
  in
  let branch = { branch with promoted = promoted @ branch.promoted } in
  { branch with storage = Store.loop_results ~values:outputs branch.storage }

let build ~ctx ~at ~name ~plan loop ~branch =
  let captures = List.map snd plan.Loop_plan.captures in
  let values, parameters, entry, advance =
    match loop with
    | Conditional _ | Returning _ ->
        (captures, parameter_types ctx at captures, [], fun _ -> [])
    | Indexed { sequence; index; access; parent; _ } ->
        ( captures @ [ sequence; index ],
          parameter_types ctx at (captures @ [ sequence ]) @ [ NumT `NatT $ at ],
          [ sequence.exp; nat ~at 0 ],
          fun iteration ->
            [
              (match access with
              | Independent | Snapshot _ -> sequence.exp
              | Live _ ->
                  (Error.find_or_reject ~at ~name:parent
                     (Store.bindings iteration.storage))
                    .exp);
              arithmetic ~at ~op:`AddOp index.exp (nat ~at 1);
            ] )
  in
  let finished =
    match loop with
    | Conditional { finished; _ } -> finished
    | Returning _ -> []
    | Indexed { sequence; index; initial; _ } ->
        [
          guard ~at
            ~exp:(comparison ~at ~op:`GeOp index.exp (LenE sequence.exp $ at))
            initial;
        ]
  in
  let return_type =
    match loop with
    | Indexed _ | Conditional _ -> carried_type ctx at plan.carried
    | Returning { kind; _ } -> Operand.typ ~types:ctx.source.types ~at kind
  in
  let def value branch =
    (List.map (fun value -> value.exp) values, value, branch.premises)
  in
  let recursive_result iteration =
    call ~at name
      ~args:(recursive_arguments at plan iteration @ advance iteration)
  in
  let clauses =
    match loop with
    | Indexed { body; _ } | Conditional { body; _ } ->
        List.map
          (fun ((iteration, _) as completion) ->
            def
              (iteration_result ctx at plan.carried completion (fun () ->
                   recursive_result iteration))
              iteration)
          body.iterations
    | Returning { continuing; returned; _ } ->
        List.map (fun branch -> def (recursive_result branch) branch) continuing
        @ List.map (fun (branch, value) -> def value.exp branch) returned
  in
  let definitions =
    Operand.function_definitions ~at name ~parameters ~result:return_type
      ~equations:
        (List.map
           (fun branch ->
             def
               (carried_value ~accumulates:true ctx at plan.carried branch)
               branch)
           finished
        @ clauses)
  in
  emit_helper ctx ~definitions;
  let call =
    call ~at name ~args:(List.map (fun value -> value.exp) captures @ entry)
  in
  match loop with
  | Indexed { body; _ } | Conditional { body; _ } ->
      ( bind_result ~promotions:body.promotions ctx at plan.carried call branch,
        Fallthrough )
  | Returning { kind; _ } ->
      let branch, value = bind ~ctx ~at branch ~term:{ exp = call; kind } in
      (branch, Returned value)
