open Common.Annotated
open Lang.El
open Store
open Value
open Ctx
open Branch

type plan = {
  carried : (string * Value.t) list;
  captures : (string * Value.t) list;
}

type access = Independent | Snapshot of string | Live of string
type iteration = { access : access; iterated : string list }

(* Reading a carried scalar exposes iteration order, so a set loop may only add
   to it. For a promoted accumulator, a read also exposes whether its number
   class has changed. Counting addition sites lets the caller require one
   operand width. *)
let count_accumulator_additions name body =
  let rec reads (node : Syntax.expr) =
    match node.it with
    | Syntax.Name local when local = name ->
        Error.reject ~at:node.at
          ("A carried accumulator is readable only in its own addition: " ^ name)
    | _ -> List.iter reads (Syntax.expr_children node)
  in
  Syntax.fold_statements_preorder
    ~f:(fun count (node : Syntax.statement) ->
      match node.it with
      | Syntax.AugAssign (Syntax.Add, { it = Syntax.Name local; _ }, value)
        when local = name ->
          reads value;
          count + 1
      | Syntax.Assign
          ( { it = Syntax.Name local; _ },
            {
              it =
                Syntax.Binary (Syntax.Add, { it = Syntax.Name left; _ }, value);
              _;
            } )
        when local = name && left = name ->
          reads value;
          count + 1
      | _ ->
          List.iter reads (Syntax.statement_exprs node);
          count)
    ~init:0 body

(* A promoted accumulator starts as a plain integer and becomes unsigned at its
   first addition. The body may only add to it at one site, keeping the operand
   width constant. A while condition runs after the first addition as well, so
   it needs the same restriction. *)
let check_accumulation ~at ~promotions ~guards body =
  List.iter
    (fun (name, _) ->
      List.iter
        (fun guard ->
          ignore
            (count_accumulator_additions name
               [ Syntax.Assert guard $ guard.at ]))
        guards;
      if count_accumulator_additions name body <> 1 then
        Error.reject ~at
          ("An accumulated loop local needs exactly one addition in its body: "
         ^ name))
    promotions

(* A set has no specified iteration order, so a loop must give the same result
   in every order. Distinct elements access distinct sequence entries. Summing
   them gives the same value and unsigned overflow in any order. *)
let check_set_loop ~types ~at ~target ~carried ~references ~state_reads body =
  let names = List.map fst carried in
  let rec alias_at_target alias (node : Syntax.expr) =
    match node.it with
    | Syntax.Index ({ it = Syntax.Name local; _ }, index) when local = alias ->
        (match index.it with
        | Syntax.Name element when element = target -> ()
        | _ ->
            Error.reject ~at:node.at
              "A set loop reads its carried sequence only at the loop element");
        alias_at_target alias index
    | Syntax.Name local when local = alias ->
        Error.reject ~at:node.at
          "A set loop uses its carried sequence only through the loop element"
    | _ -> List.iter (alias_at_target alias) (Syntax.expr_children node)
  in
  let at_target (index : Syntax.expr) node =
    match index.it with
    | Syntax.Name element when element = target -> ()
    | _ ->
        Error.reject ~at:node.at
          "A set loop writes a sequence only at the loop element"
  in
  Syntax.iter_statements_preorder
    ~f:(fun (node : Syntax.statement) ->
      match node.it with
      | Syntax.Break ->
          Error.reject ~at:node.at
            "A set loop cannot break, since the element it stops at depends on \
             enumeration order"
      | Syntax.Assert _ ->
          Error.reject ~at:node.at
            "A set loop cannot assert, since the element that fails depends on \
             enumeration order"
      | Syntax.Expression _ ->
          Error.reject ~at:node.at "A set loop cannot call a state mutator"
      | Syntax.While _ ->
          Error.reject ~at:node.at "A set loop cannot contain a while loop"
      | Syntax.AugAssign (op, { it = Syntax.Name local; _ }, _)
        when List.mem local names ->
          if op <> Syntax.Add then
            Error.reject ~at:node.at
              "A set loop accumulates a carried local only by addition"
      | Syntax.Assign ({ it = Syntax.Index (receiver, index); _ }, _)
      | Syntax.AugAssign (_, { it = Syntax.Index (receiver, index); _ }, _) -> (
          match receiver.it with
          | Syntax.Name local when List.mem local names -> at_target index node
          | Syntax.Attribute ({ it = Syntax.Name root; _ }, _)
            when root = Names.state_parameter ->
              at_target index node
          | _ ->
              Error.reject ~at:node.at
                "A set loop writes only a carried sequence or a state field")
      | Syntax.Assign ({ it = Syntax.Name local; _ }, _)
      | Syntax.AnnotatedAssign ({ it = Syntax.Name local; _ }, _, _) ->
          if List.mem local names then
            Error.reject ~at:node.at
              "A set loop replaces a carried local only by accumulation"
      | Syntax.If _ | Syntax.For _ | Syntax.Return _ -> ()
      | _ ->
          Error.reject ~at:node.at
            "A set loop admits only element-indexed writes and accumulation")
    body;
  let expressions = Syntax.statement_exprs_preorder body in
  (* The state fields this loop writes, named by their target atom. A read of
     one of them during the loop would see how many elements came before. *)
  let add_field written field =
    let field = String.uppercase_ascii field in
    if List.mem field written then written else field :: written
  in
  let written =
    Syntax.fold_statements_preorder
      ~f:(fun written (node : Syntax.statement) ->
        match node.it with
        | Syntax.Assign ({ it = Syntax.Index (receiver, _); _ }, _)
        | Syntax.AugAssign (_, { it = Syntax.Index (receiver, _); _ }, _) -> (
            match receiver.it with
            | Syntax.Attribute ({ it = Syntax.Name root; _ }, field)
              when root = Names.state_parameter ->
                add_field written field
            | Syntax.Name local -> (
                match List.assoc_opt local references with
                | Some { location = Some (Field field :: _); _ } ->
                    add_field written field
                | _ -> written)
            | _ -> written)
        | _ -> written)
      ~init:[] body
  in
  let rec state_at_target (node : Syntax.expr) =
    match node.it with
    | Syntax.Index
        ({ it = Syntax.Attribute ({ it = Syntax.Name root; _ }, _); _ }, index)
      when root = Names.state_parameter -> (
        match index.it with
        | Syntax.Name element when element = target -> state_at_target index
        | _ ->
            Error.reject ~at:node.at
              "A set loop reads a state sequence only at the loop element")
    | Syntax.Attribute ({ it = Syntax.Name root; _ }, field)
      when root = Names.state_parameter
           && List.mem (String.uppercase_ascii field) written ->
        Error.reject ~at:node.at
          "A set loop reads a field it writes only at the loop element"
    | _ -> List.iter state_at_target (Syntax.expr_children node)
  in
  List.iter state_at_target expressions;
  (* Only the state object itself hands a callee the fields the loop writes.
     A field read is already constrained to the loop element above, so passing
     one on needs no footprint. *)
  let rec passes_state (node : Syntax.expr) =
    match node.it with
    | Syntax.Name name -> name = Names.state_parameter
    | Syntax.Attribute ({ it = Syntax.Name root; _ }, _)
      when root = Names.state_parameter ->
        false
    | _ -> List.exists passes_state (Syntax.expr_children node)
  in
  (* A helper that reads state must appear in the state-read table. Its listed
     fields must exclude every field the loop writes, since the call could
     otherwise observe elements already processed. *)
  let footprint name node arguments =
    if List.exists passes_state arguments then
      match List.assoc_opt name state_reads with
      | None ->
          Error.reject ~at:node.at
            ("A set loop needs a reviewed state read footprint for " ^ name)
      | Some reads ->
          List.iter
            (fun field ->
              if List.mem (String.uppercase_ascii field) written then
                Error.reject ~at:node.at
                  ("A set loop calls " ^ name
                 ^ ", which reads a field the loop writes"))
            reads
  in
  let rec state_calls (node : Syntax.expr) =
    (match node.it with
    | Syntax.Call (name, args, keywords) ->
        footprint name node (args @ List.map snd keywords)
    | Syntax.Method (receiver, name, args) ->
        if List.exists passes_state (receiver :: args) then
          Error.reject ~at:node.at
            ("A set loop cannot reach the state through the method " ^ name)
    | _ -> ());
    List.iter state_calls (Syntax.expr_children node)
  in
  List.iter state_calls expressions;
  List.iter
    (fun (name, value) ->
      if name <> Names.state_parameter then
        if Value.is_named_container_or_set ~types ~at value.Value.kind then
          List.iter (alias_at_target name) expressions
        else ignore (count_accumulator_additions name body))
    carried

(* An accumulated loop result holds Python's plain initial value only when the
   body never ran, so every later read has to reach an operation that coerces
   it the way the unsigned class would. *)
let check_promoted_use ~promotions rest =
  let rec operands name (node : Syntax.expr) =
    match node.it with
    | Syntax.Binary (_, left, right) ->
        List.iter
          (fun side ->
            match side.it with
            | Syntax.Name local when local = name -> ()
            | _ -> operands name side)
          [ left; right ]
    | Syntax.Name local when local = name ->
        Error.reject ~at:node.at
          "An accumulated loop result is readable only as an arithmetic operand"
    | _ -> List.iter (operands name) (Syntax.expr_children node)
  in
  List.iter
    (fun (name, _) ->
      List.iter (operands name) (Syntax.statement_exprs_preorder rest))
    promotions

let select_carried ?(returning = false) ~types ~at body ~storage =
  let rec assigned nodes =
    List.concat_map
      (fun (node : Syntax.statement) ->
        match node.it with
        | Syntax.Return _ when not returning ->
            Error.reject ~at:node.at "Returns inside loops are unsupported"
        | Syntax.Return _ -> []
        | Syntax.Assign ({ it = Syntax.Name name; _ }, _)
        | Syntax.AnnotatedAssign ({ it = Syntax.Name name; _ }, _, _)
        | Syntax.AugAssign (_, { it = Syntax.Name name; _ }, _) -> (
            match List.assoc_opt name (Store.references storage) with
            | Some { location = None; _ } ->
                Error.reject ~at:node.at
                  "Rebinding a local list inside a loop is unsupported"
            | _ -> [ name ])
        | Syntax.Assign
            ({ it = Syntax.Index ({ it = Syntax.Name name; _ }, _); _ }, _)
        | Syntax.AugAssign
            (_, { it = Syntax.Index ({ it = Syntax.Name name; _ }, _); _ }, _)
          ->
            [ name ]
        | Syntax.If (_, yes, no) -> assigned yes @ assigned no
        | Syntax.While (_, body) | Syntax.For (_, _, body) -> assigned body
        | _ -> [])
      nodes
  in
  let names = assigned body in
  let carried =
    List.filter
      (fun (name, _) ->
        name = Names.state_parameter
        || List.mem name names
        ||
        match List.assoc_opt name (Store.references storage) with
        | Some { location = None; _ } -> true
        | _ -> false)
      (Store.bindings storage)
  in
  let carried =
    match carried with
    (* A loop helper needs a result type. When the loop assigns no values,
       carrying the most recent binding supplies that type. *)
    | [] when not returning -> [ List.hd (Store.bindings storage) ]
    | carried -> carried
  in
  List.iter
    (fun (name, value) ->
      if
        name <> Names.state_parameter
        && Value.is_named_container_or_set ~types ~at value.Value.kind
        && not
             (match List.assoc_opt name (Store.references storage) with
             (* An owned list is carried by value. A valid state location is
                carried alongside the state it points into, so both views of
                the same object stay in step. *)
             | Some { location = None; _ } -> true
             | Some
                 { location = Some _; valid = true; iterator_parent = None; _ }
               ->
                 true
             | _ -> false)
      then
        Error.reject ~at
          "Mutable loop-carried locals require a reference contract")
    carried;
  carried

(* Helper clauses carry no decisions about optional arguments. Reading an
   optional local would therefore admit both outcomes of its None test. *)
let capture ~at ~carried ~body storage =
  let read = Syntax.names body in
  let captures = Store.bindings storage in
  List.iter
    (fun (name, (value : Value.t)) ->
      match value.kind with
      | Optional _ when List.mem name read ->
          Error.reject ~at "Loop bodies cannot read an optional local"
      | _ -> ())
    captures;
  { carried; captures }

let returns_inside nodes =
  Syntax.exists_statement
    ~f:(fun (node : Syntax.statement) ->
      match node.it with Syntax.Return _ -> true | _ -> false)
    nodes

let iteration ~types ~at ~target ~enumerated ~iterable ~element ~storage
    ~sequence ~state_backed ~set_iterated body =
  let targets = Syntax.target_names target in
  let local = List.hd (List.rev targets) in
  let state_field =
    match iterable.it with
    | Syntax.Attribute ({ it = Syntax.Name root; _ }, field)
      when root = Names.state_parameter
           && enumerated
           && Value.is_named_container_or_set ~types ~at element ->
        Some field
    | _ -> None
  in
  let writes_current nodes =
    Syntax.exists_statement
      ~f:(fun (node : Syntax.statement) ->
        match node.it with
        | Syntax.Assign
            ({ it = Syntax.Attribute ({ it = Syntax.Name name; _ }, _); _ }, _)
        | Syntax.AugAssign
            ( _,
              { it = Syntax.Attribute ({ it = Syntax.Name name; _ }, _); _ },
              _ ) ->
            name = local
        | _ -> false)
      nodes
  in
  let snapshot_field = if writes_current body then None else state_field in
  let unpacked =
    match target with Syntax.Unpacked _ -> true | Syntax.Single _ -> false
  in
  if snapshot_field <> None || unpacked || set_iterated then
    Syntax.iter_statements_preorder
      ~f:(fun (node : Syntax.statement) ->
        match node.it with
        | Syntax.Assign ({ it = Syntax.Name name; _ }, _)
        | Syntax.AugAssign (_, { it = Syntax.Name name; _ }, _)
          when List.mem name targets ->
            Error.reject ~at:node.at "Iteration targets cannot be rebound"
        | _ -> ())
      body;
  let parent_field = if snapshot_field = None then state_field else None in
  if parent_field = None && snapshot_field = None then (
    if
      Value.is_named_container_or_set ~types ~at element
      && (not (Value.is_flat_record ~types ~at element))
      && match iterable.it with Syntax.Tuple _ -> false | _ -> true
    then
      Error.reject ~at
        "For iteration over mutable elements requires a reference contract";
    if state_backed () then
      Error.reject ~at
        "For iteration over a state-backed sequence requires a live-iterator \
         contract");
  let rec iterates_name name (node : Syntax.expr) =
    match node.it with
    | Syntax.Name local -> local = name
    | Syntax.Call ("zip", values, []) -> List.exists (iterates_name name) values
    | _ -> false
  in
  let holds_sequence name =
    let value = List.assoc name (Store.bindings storage) in
    Lang.El.Unparse.string_of_exp value.Value.exp
    = Lang.El.Unparse.string_of_exp sequence.Value.exp
  in
  let iterated_identities =
    List.filter_map
      (fun (name, reference) ->
        if
          reference.location = None
          && (holds_sequence name || iterates_name name iterable)
        then Some reference.identity
        else None)
      (Store.references storage)
  in
  let owned_iterable = iterated_identities <> [] in
  let has_index_write nodes =
    Syntax.exists_statement
      ~f:(fun (node : Syntax.statement) ->
        match node.it with
        | Syntax.Assign
            ({ it = Syntax.Index ({ it = Syntax.Name _; _ }, _); _ }, _)
        | Syntax.AugAssign
            (_, { it = Syntax.Index ({ it = Syntax.Name _; _ }, _); _ }, _) ->
            true
        | _ -> false)
      nodes
  in
  if owned_iterable && has_index_write body then
    Error.reject ~at
      "Local-list iteration with indexed local writes requires a live-iterator \
       contract";
  let access =
    match (parent_field, snapshot_field) with
    | Some field, _ -> Live field
    | None, Some field -> Snapshot field
    | None, None -> Independent
  in
  { access; iterated = iterated_identities }

type completion = Returned of Value.t | Broken | Fallthrough

type body = {
  promotions : (string * Value.kind) list;
  iterations : (Branch.t * [ `Continue | `Break ]) list;
}

type t =
  | Indexed of {
      sequence : Value.t;
      index : Value.t;
      access : access;
      parent : string;
      initial : Branch.t;
      body : body;
    }
  | Conditional of { finished : Branch.t list; body : body }
  | Returning of {
      kind : Value.kind;
      continuing : Branch.t list;
      returned : (Branch.t * Value.t) list;
    }

let plaintyps_of_values ~ctx ~at values =
  List.map
    (fun value -> Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at value.kind)
    values

let plaintyp_of_carried ctx at carried =
  match
    List.map
      (fun (_, value) ->
        Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at value.kind)
      carried
  with
  | [ typ ] -> typ
  | types -> TupleT types $ at

let carried_tuple at values =
  match values with [ value ] -> value | values -> TupleE values $ at

(* Python converts a plain-integer accumulator to the added value's unsigned
   class. An empty loop keeps the initial plain integer. The addition already
   checks coercion and overflow, so both cases can share the plain-integer
   target type. *)
let accumulated_width ctx at initial value =
  Value.is_integer ~types:(Ctx.types ctx) ~at initial.kind
  && Value.bits ~types:(Ctx.types ctx) ~at value.kind <> None

let carried_value ?(accumulates = false) ~ctx ~at ~carried branch =
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

(* The unsigned source kind shared by all iterations of a promoted accumulator. *)
(* Every iteration must leave the same unsigned source type, including its
   nominal name. *)
let promotions ~ctx ~at ~carried iterations =
  List.filter_map
    (fun (name, initial) ->
      if not (Value.is_integer ~types:(Ctx.types ctx) ~at initial.kind) then
        None
      else
        let kinds =
          List.filter_map
            (fun (iteration, _) ->
              let value =
                Error.find_or_reject ~at ~name
                  (Store.bindings iteration.storage)
              in
              if Value.bits ~types:(Ctx.types ctx) ~at value.kind = None then
                None
              else Some value.kind)
            iterations
        in
        match List.sort_uniq Stdlib.compare kinds with
        | [] -> None
        | [ kind ] -> Some (name, kind)
        | _ ->
            Error.reject ~at
              "A loop-carried integer must accumulate one unsigned class")
    carried

let recursive_arguments at plan iteration =
  List.map
    (fun (name, value) ->
      if List.mem_assoc name plan.carried then
        (Error.find_or_reject ~at ~name (Store.bindings iteration.storage)).exp
      else value.exp)
    plan.captures

let carried_body ~ctx ~at ~carried ~tests ~body ~rest iterations =
  let promotions = promotions ~ctx ~at ~carried iterations in
  check_accumulation ~at ~promotions ~guards:tests body;
  check_promoted_use ~promotions rest;
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

let iteration_result ~ctx ~at ~carried (iteration, completion) ~continue =
  let carried_value =
    carried_value ~accumulates:true ~ctx ~at ~carried iteration
  in
  match completion with `Continue -> continue () | `Break -> carried_value

let bind_result ?(promotions = []) ~ctx ~at ~carried result ~branch =
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
          (fun value -> (Lang.El.Unparse.string_of_exp value.exp, kind))
          (List.assoc_opt name outputs))
      promotions
  in
  branch |> promote ~promoted
  |> map_storage
       ~f:(Store.loop_results ~state_name:Names.state_parameter ~values:outputs)

let build ~ctx ~at ~name ~plan loop ~branch =
  let captures = List.map snd plan.captures in
  let values, parameters, entry, advance =
    match loop with
    | Conditional _ | Returning _ ->
        (captures, plaintyps_of_values ~ctx ~at captures, [], fun _ -> [])
    | Indexed { sequence; index; access; parent; _ } ->
        ( captures @ [ sequence; index ],
          plaintyps_of_values ~ctx ~at (captures @ [ sequence ])
          @ [ NumT `NatT $ at ],
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
    | Indexed _ | Conditional _ -> plaintyp_of_carried ctx at plan.carried
    | Returning { kind; _ } ->
        Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at kind
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
              (iteration_result ~ctx ~at ~carried:plan.carried completion
                 ~continue:(fun () -> recursive_result iteration))
              iteration)
          body.iterations
    | Returning { continuing; returned; _ } ->
        List.map (fun branch -> def (recursive_result branch) branch) continuing
        @ List.map (fun (branch, value) -> def value.exp branch) returned
  in
  let definitions =
    Value.function_definitions ~at name ~parameters ~result:return_type
      ~equations:
        (List.map
           (fun branch ->
             def
               (carried_value ~accumulates:true ~ctx ~at ~carried:plan.carried
                  branch)
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
      ( bind_result ~promotions:body.promotions ~ctx ~at ~carried:plan.carried
          call ~branch,
        Fallthrough )
  | Returning { kind; _ } ->
      let branch, value = bind ~ctx ~at branch ~term:{ exp = call; kind } in
      (branch, Returned value)

let map ~ctx ~at ~captures ~element ~branch value =
  ignore (Value.sequence ~types:(Ctx.types ctx) ~at value.kind);
  let branch, value = Branch.bind ~ctx ~at branch ~term:value in
  let index = Ctx.fresh ~hint:"nat" ctx ~at ~kind:Value.integer in
  let name = Ctx.fresh_helper_name ctx ~operation:"comprehension" in
  let captured_values = List.map snd captures in
  let arguments = captured_values @ [ value; index ] in
  let initial =
    Branch.make (Store.make captures)
    |> Branch.guard ~at ~exp:(comparison ~at ~op:`LeOp (nat ~at 0) index.exp)
  in
  let initial, item =
    Sequence_ops.read_index ~ctx ~at ~branch:initial value ~index
  in
  let values, skipped = element initial index item in
  let kind =
    match values with
    | (_, value) :: _
      when List.for_all (fun (_, v) -> v.kind = value.kind) values ->
        Sequence (value.kind, None)
    | _ -> Error.reject ~at "Comprehension requires a uniform result type"
  in
  let parameters =
    List.map
      (fun value ->
        Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at value.kind)
      (captured_values @ [ value ])
    @ [ NumT `NatT $ at ]
  in
  let actuals = List.map (fun t -> t.exp) (captured_values @ [ value ]) in
  let tail =
    call ~at name
      ~args:(actuals @ [ arithmetic ~at ~op:`AddOp index.exp (nat ~at 1) ])
  in
  let def result prems = (List.map (fun t -> t.exp) arguments, result, prems) in
  let end_prems =
    [
      IfPr (comparison ~at ~op:`LeOp (nat ~at 0) index.exp) $ at;
      IfPr (comparison ~at ~op:`GeOp index.exp (LenE value.exp $ at)) $ at;
    ]
  in
  let definitions =
    Value.function_definitions ~at name ~parameters
      ~result:(Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at kind)
      ~equations:
        ([ def (EpsE $ at) end_prems ]
        @ List.map
            (fun (branch, value) ->
              def
                (CatE (ListE [ value.exp ] $ at, tail) $ at)
                branch.Branch.premises)
            values
        @ List.map (fun branch -> def tail branch.Branch.premises) skipped)
  in
  Ctx.emit_helper ctx ~definitions;
  (branch, { exp = call ~at name ~args:(actuals @ [ nat ~at 0 ]); kind })
