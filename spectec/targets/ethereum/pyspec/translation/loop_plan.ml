open Common.Source
open Store

type 'value t = {
  carried : (string * 'value) list;
  captures : (string * 'value) list;
}

type access = Independent | Snapshot of string | Live of string
type iteration = { access : access; iterated : string list }

(* A carried scalar may only be added to. Reading it would expose how many
   elements came before, and for a value Python widens it would also expose
   whether the widening has happened yet. The site count lets a caller demand
   a single operand width. *)
let addition_only_reads name body =
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

(* A plain integer the body turns into an unsigned value has no settled Python
   class until the first addition runs, so the body may only add to it, and
   one site keeps every iteration's operand width the same. A while test runs
   again after that first addition, so it is held to the same rule as the
   body rather than to the initial plain kind. *)
let check_accumulation ~at ~promotions ~guards body =
  List.iter
    (fun (name, _) ->
      List.iter
        (fun guard ->
          ignore (addition_only_reads name [ Syntax.Assert guard $ guard.at ]))
        guards;
      if addition_only_reads name body <> 1 then
        Error.reject ~at
          ("An accumulated loop local needs exactly one addition in its body: "
         ^ name))
    promotions

(* A reviewed set enumerates in an order the source does not fix, so a
   statement loop over one may only build results every enumeration gives.
   Distinct elements reach distinct sequence entries, and an accumulated total
   reaches the same value and the same unsigned overflow in any order. *)
let check_set_loop ~types ~kind ~at ~target ~carried ~references ~state_reads
    body =
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
          | Syntax.Attribute ({ it = Syntax.Name "state"; _ }, _) ->
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
  let written = ref [] in
  let add_field field =
    let field = String.uppercase_ascii field in
    if not (List.mem field !written) then written := field :: !written
  in
  Syntax.iter_statements_preorder
    ~f:(fun (node : Syntax.statement) ->
      match node.it with
      | Syntax.Assign ({ it = Syntax.Index (receiver, _); _ }, _)
      | Syntax.AugAssign (_, { it = Syntax.Index (receiver, _); _ }, _) -> (
          match receiver.it with
          | Syntax.Attribute ({ it = Syntax.Name "state"; _ }, field) ->
              add_field field
          | Syntax.Name local -> (
              match List.assoc_opt local references with
              | Some { location = Some (Field field :: _); _ } ->
                  add_field field
              | _ -> ())
          | _ -> ())
      | _ -> ())
    body;
  let rec state_at_target (node : Syntax.expr) =
    match node.it with
    | Syntax.Index
        ( { it = Syntax.Attribute ({ it = Syntax.Name "state"; _ }, _); _ },
          index ) -> (
        match index.it with
        | Syntax.Name element when element = target -> state_at_target index
        | _ ->
            Error.reject ~at:node.at
              "A set loop reads a state sequence only at the loop element")
    | Syntax.Attribute ({ it = Syntax.Name "state"; _ }, field)
      when List.mem (String.uppercase_ascii field) !written ->
        Error.reject ~at:node.at
          "A set loop reads a field it writes only at the loop element"
    | _ -> List.iter state_at_target (Syntax.expr_children node)
  in
  List.iter state_at_target expressions;
  (* A call that reads the state needs a reviewed read footprint, and that
     footprint has to avoid every field the loop writes. Without one the call
     could observe the elements already processed. *)
  (* Only the state object itself hands a callee the fields the loop writes.
     A field read is already constrained to the loop element above, so passing
     one on needs no footprint. *)
  let rec passes_state (node : Syntax.expr) =
    match node.it with
    | Syntax.Name "state" -> true
    | Syntax.Attribute ({ it = Syntax.Name "state"; _ }, _) -> false
    | _ -> List.exists passes_state (Syntax.expr_children node)
  in
  let footprint name node arguments =
    if List.exists passes_state arguments then
      match List.assoc_opt name state_reads with
      | None ->
          Error.reject ~at:node.at
            ("A set loop needs a reviewed state read footprint for " ^ name)
      | Some reads ->
          List.iter
            (fun field ->
              if List.mem (String.uppercase_ascii field) !written then
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
      if name <> "state" then
        if Kind.is_named_container_or_set ~types ~at (kind value) then
          List.iter (alias_at_target name) expressions
        else ignore (addition_only_reads name body))
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

let select_carried ?(returning = false) ~types ~kind ~at body ~storage =
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
        name = "state" || List.mem name names
        ||
        match List.assoc_opt name (Store.references storage) with
        | Some { location = None; _ } -> true
        | _ -> false)
      (Store.bindings storage)
  in
  let carried =
    match carried with
    | [] when not returning -> [ List.hd (Store.bindings storage) ]
    | carried -> carried
  in
  List.iter
    (fun (name, value) ->
      if
        name <> "state"
        && Kind.is_named_container_or_set ~types ~at (kind value)
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

let capture ~carried storage = { carried; captures = Store.bindings storage }

let returns_inside nodes =
  Syntax.exists_statement
    ~f:(fun (node : Syntax.statement) ->
      match node.it with Syntax.Return _ -> true | _ -> false)
    nodes

let iteration ~types ~at ~target ~enumerated ~iterable ~element ~storage
    ~same_value ~state_backed ~set_iterated body =
  let targets = Syntax.target_names target in
  let local = List.hd (List.rev targets) in
  let state_field =
    match iterable.it with
    | Syntax.Attribute ({ it = Syntax.Name "state"; _ }, field)
      when enumerated && Kind.is_named_container_or_set ~types ~at element ->
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
      Kind.is_named_container_or_set ~types ~at element
      && (not (Kind.is_flat_record ~types ~at element))
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
  let iterated_identities =
    List.filter_map
      (fun (name, reference) ->
        if
          reference.location = None
          && (same_value (List.assoc name (Store.bindings storage))
             || iterates_name name iterable)
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
