open Common.Source
module S = Source

let update_list_binding env name established =
  let remaining = List.filter (( <> ) name) env in
  if established then name :: remaining else remaining

let establishes_list known (source : S.t) =
  let rec list_value env (node : Syntax.expr) =
    match node.it with
    | Syntax.Empty | Syntax.ListLiteral _ | Syntax.Comprehension _ -> true
    | Syntax.Name name -> List.mem name env
    | Syntax.Conditional (_, yes, no) -> list_value env yes && list_value env no
    | Syntax.Call (name, _, _) ->
        (not (List.mem name source.locals))
        && (List.mem name known
           || (name = "sorted" && List.mem name source.builtins))
    | _ -> false
  in
  let join left right =
    match (left, right) with
    | None, other | other, None -> other
    | Some left, Some right ->
        Some (List.filter (fun name -> List.mem name right) left)
  in
  let rec walk env = function
    | [] -> (Some env, [])
    | (node : Syntax.statement) :: rest -> (
        let continue env results =
          match env with
          | None -> (None, results)
          | Some env ->
              let ending, later = walk env rest in
              (ending, results @ later)
        in
        match node.it with
        | Syntax.Return value ->
            (None, [ Option.fold ~none:false ~some:(list_value env) value ])
        | Syntax.Break -> (None, [])
        | Syntax.Assign ({ it = Syntax.Name name; _ }, value)
        | Syntax.AnnotatedAssign ({ it = Syntax.Name name; _ }, _, value) ->
            let env = update_list_binding env name (list_value env value) in
            walk env rest
        | Syntax.AugAssign (_, { it = Syntax.Name name; _ }, _) ->
            walk (update_list_binding env name false) rest
        | Syntax.If (_, yes, no) ->
            let left, left_results = walk env yes in
            let right, right_results = walk env no in
            continue (join left right) (left_results @ right_results)
        | Syntax.For (target, _, body) ->
            walk_loop_body env
              (Syntax.target_names target @ Syntax.assigned_names body)
              body rest
        | Syntax.While (_, body) ->
            walk_loop_body env (Syntax.assigned_names body) body rest
        | _ -> walk env rest)
  and walk_loop_body env writes body rest =
    let env = List.filter (fun name -> not (List.mem name writes)) env in
    let _, results = walk env body in
    let ending, later = walk env rest in
    (ending, results @ later)
  in
  let generic_sequence =
    match source.signature.returns with
    | None -> false
    | Some name -> (
        match (List.assoc name source.types).S.descriptor with
        | S.Sequence { length = None; limit = None; bitvector = false; _ } ->
            true
        | _ -> false)
  in
  if source.signature.effect = S.MutatesState || not generic_sequence then false
  else
    let ending, results = walk [] source.body in
    ending = None && results <> [] && List.for_all Fun.id results

let infer sources =
  let rec fixpoint known =
    let added =
      List.filter_map
        (fun (source : S.t) ->
          let name = source.signature.name in
          if List.mem name known || not (establishes_list known source) then
            None
          else Some name)
        sources
    in
    if added = [] then known else fixpoint (added @ known)
  in
  fixpoint []
