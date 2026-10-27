open Common.Source
open Lang.El
open Store
open Kind
open Operand
open Ctx
open Branch
module S = Source
module B = Python_builtins
open Loop

type scope = FunctionBody | LoopBody of region * string | ReturningLoopBody

let rec returned_local ~fallthrough name nodes =
  match nodes with
  | [] -> fallthrough = Some name
  | node :: rest -> (
      match node.it with
      | Syntax.Return (Some { it = Syntax.Name result; _ }) -> result = name
      | Syntax.Return _ -> false
      | Syntax.Assign
          ({ it = Syntax.Name alias; _ }, { it = Syntax.Name original; _ })
        when original = name ->
          returned_local ~fallthrough alias rest
          || returned_local ~fallthrough name rest
      | Syntax.Assign ({ it = Syntax.Name target; _ }, _) when target = name ->
          false
      | Syntax.If (_, yes, no) ->
          returned_local ~fallthrough name (yes @ rest)
          || returned_local ~fallthrough name (no @ rest)
      | Syntax.While (_, body) | Syntax.For (_, _, body) ->
          returned_local ~fallthrough:None name body
          || returned_local ~fallthrough name rest
      | _ -> returned_local ~fallthrough name rest)

let empty_list_context ctx scope (target : Syntax.expr) rest value =
  let fallthrough =
    match scope with
    | LoopBody (_, name) -> Some name
    | FunctionBody | ReturningLoopBody -> None
  in
  match (value.kind, target.it, ctx.source.signature.returns) with
  | Empty, Syntax.Name name, Some result
    when returned_local ~fallthrough name rest -> (
      match Kind.descriptor ~types:ctx.source.types ~at:target.at result with
      | S.Sequence { element; _ } ->
          { value with kind = Sequence (Named element, None) }
      | _ -> value)
  | _ -> value

let check_set_result ctx at value =
  let expected =
    Option.bind ctx.source.signature.returns (fun name ->
        Kind.set_element ~types:ctx.source.types ~at (Named name))
  in
  Kind.check_set_value ~types:ctx.source.types ~at value.kind ~expected
    ~diagnostic:"Set results require a matching set return annotation"

let finish_body ctx scope branch =
  match scope with
  | FunctionBody ->
      if ctx.source.signature.effect = S.MutatesState then
        ( branch,
          Returned
            (Error.find_or_reject ~at:ctx.source.at ~name:"state"
               (Store.bindings branch.storage)) )
      else Error.reject ~at:ctx.source.at "Implicit None return in a function"
  | LoopBody (at, name) ->
      let value = Expr.read_name ~ctx ~at ~branch name in
      (* Continuing iterations share the enclosing set-result admission. *)
      check_set_result ctx no_region value;
      (branch, Fallthrough)
  | ReturningLoopBody -> (branch, Fallthrough)

let rec translate ~ctx ~scope nodes ~branch =
  let mutator = ctx.source.signature.effect = S.MutatesState in
  match nodes with
  | [] -> [ finish_body ctx scope branch ]
  | node :: rest -> (
      let at = node.at in
      match node.it with
      | Syntax.Break ->
          (match scope with
          | LoopBody _ -> ()
          | FunctionBody | ReturningLoopBody ->
              Error.reject ~at
                "Break requires a loop with a reviewed continuation");
          [ (branch, Broken) ]
      | Syntax.Return None ->
          if mutator then
            [
              ( branch,
                Returned
                  (Error.find_or_reject ~at ~name:"state"
                     (Store.bindings branch.storage)) );
            ]
          else Error.reject ~at "None return in a function"
      | Syntax.Return (Some { it = Syntax.Tuple elements; _ }) ->
          let expected =
            match ctx.source.signature.returns with
            | Some name -> (
                match Kind.descriptor ~types:ctx.source.types ~at name with
                | S.Product elements -> elements
                | _ ->
                    Error.reject ~at "Tuple return requires a tuple annotation")
            | None -> Error.reject ~at "Tuple return in a state mutator"
          in
          Expr.arguments ~ctx elements ~branch
          |> List.map (fun (branch, values) ->
                 if List.length expected <> List.length values then
                   Error.reject ~at "Tuple return arity";
                 List.iter2
                   (fun expected value ->
                     if
                       Kind.set_element ~types:ctx.source.types ~at value.kind
                       <> None
                       || Operand.typ ~types:ctx.source.types ~at value.kind
                          |> Lang.El.Unparse.string_of_plaintyp
                          <> (Operand.typ ~types:ctx.source.types ~at
                                (Named expected)
                             |> Lang.El.Unparse.string_of_plaintyp)
                     then Error.reject ~at "Tuple return element type")
                   expected values;
                 ( branch,
                   Returned
                     {
                       exp =
                         TupleE (List.map (fun value -> value.exp) values) $ at;
                       kind =
                         Product (List.map (fun value -> value.kind) values);
                     } ))
      | Syntax.Return (Some value) ->
          Expr.translate ~ctx value ~branch
          |> List.map (fun (branch, result) ->
                 check_set_result ctx at result;
                 (branch, Returned result))
      | Syntax.If (test, yes, no) ->
          [ (true, yes); (false, no) ]
          |> List.concat_map (fun (truth, body) ->
                 Expr.condition ~ctx test ~holds:truth ~branch
                 |> List.concat_map (fun branch ->
                        translate ~ctx ~scope (body @ rest) ~branch))
      | Syntax.For (target, iterable, body) ->
          for_loop ctx at target iterable body rest branch
          |> resume_loop ctx scope rest
      | Syntax.While (test, body) ->
          while_loop ctx at test body rest branch |> resume_loop ctx scope rest
      | Syntax.Assert test ->
          Expr.condition ~ctx test ~holds:true ~branch
          |> List.concat_map (fun branch -> translate ~ctx ~scope rest ~branch)
      | Syntax.Assign (target, source)
      | Syntax.AnnotatedAssign (target, _, source) ->
          let copied =
            match source.it with Syntax.Name name -> Some name | _ -> None
          in
          Expr.translate ~ctx source ~branch
          |> List.concat_map (fun (branch, value) ->
                 let value =
                   match (node.it, value.kind) with
                   | Syntax.Assign _, _ ->
                       empty_list_context ctx scope target rest value
                   (* Python ignores the annotation at run time. It is used only
                      to give an empty literal an element type, which an empty
                      sequence cannot carry on its own. *)
                   | Syntax.AnnotatedAssign (_, annotation, _), Empty ->
                       ignore
                         (Error.find_or_reject ~at ~name:annotation
                            ctx.source.types);
                       { value with kind = Sequence (Named annotation, None) }
                   | _ -> value
                 in
                 translate ~ctx ~scope rest
                   ~branch:(Write.store ?copied ~ctx target ~value ~branch))
      | Syntax.AugAssign (op, target, value) ->
          Expr.translate ~ctx target ~branch
          |> List.concat_map (fun (branch, left) ->
                 Expr.translate ~ctx value ~branch
                 |> List.concat_map (fun (branch, right) ->
                        let branch, value =
                          Operators.binary ~ctx ~at ~op ~branch left right
                        in
                        translate ~ctx ~scope rest
                          ~branch:(Write.store ~ctx target ~value ~branch)))
      | Syntax.Expression
          ({ it = Syntax.Method (receiver, "append", [ _ ]); _ } as call) ->
          (* A local list belongs to the function, so extending one is not a
             state effect and a read-only helper may do it. *)
          if (not mutator) && not (Effect.is_owned_list ~branch receiver) then
            Error.reject ~at "State mutation in a read-only helper";
          Effect.call ~ctx call ~branch
          |> List.concat_map (fun branch -> translate ~ctx ~scope rest ~branch)
      | Syntax.Expression call ->
          if not mutator then
            Error.reject ~at "State mutation in a read-only helper";
          Effect.call ~ctx call ~branch
          |> List.concat_map (fun branch -> translate ~ctx ~scope rest ~branch)
      | Syntax.LocalHelper helper ->
          if not mutator then
            Error.reject ~at
              "A local mutator helper needs a mutating enclosing body";
          if helper.Syntax.captured <> "state" then
            Error.reject ~at
              ("A local helper captures only the root state, not "
             ^ helper.Syntax.captured);
          if List.mem_assoc helper.Syntax.helper branch.local_helpers then
            Error.reject ~at ("Duplicate local helper: " ^ helper.Syntax.helper);
          translate ~ctx ~scope rest
            ~branch:
              {
                branch with
                local_helpers =
                  (helper.Syntax.helper, helper) :: branch.local_helpers;
              })

and resume_loop ctx scope rest outcomes =
  List.concat_map
    (fun (branch, completion) ->
      match completion with
      | Fallthrough -> translate ~ctx ~scope rest ~branch
      | Returned _ -> [ (branch, completion) ]
      | Broken -> assert false)
    outcomes

and for_loop ctx at target iterable body rest branch =
  let targets = Syntax.target_names target in
  if
    List.exists
      (fun local -> List.mem_assoc local (Store.bindings branch.storage))
      targets
    || List.length (List.sort_uniq String.compare targets)
       <> List.length targets
  then Error.reject ~at "Loop targets must be distinct fresh locals";
  let enumerated, iterable =
    match (iterable.it, target) with
    | Syntax.Call ("enumerate", [ value ], []), Syntax.Unpacked [ _; _ ]
      when List.mem "enumerate" ctx.source.builtins
           && not (List.mem "enumerate" ctx.source.locals) ->
        (true, value)
    | _, (Syntax.Single _ | Syntax.Unpacked (_ :: _)) -> (false, iterable)
    | _, Syntax.Unpacked [] ->
        Error.reject ~at "For enumeration requires two names and one sequence"
  in
  let local = List.hd (List.rev targets) in
  let carried =
    Loop_plan.select_carried ~types:ctx.source.types
      ~kind:(fun value -> value.kind)
      ~at body ~storage:branch.storage
  in
  Expr.iterable ~ctx iterable ~branch
  |> List.map (fun (branch, value) ->
         let set_iterated =
           Kind.set_element ~types:ctx.source.types ~at value.kind <> None
         in
         let value =
           match Kind.set_element ~types:ctx.source.types ~at value.kind with
           | Some element -> { value with kind = Sequence (element, None) }
           | None -> value
         in
         if set_iterated then (
           (match target with
           | Syntax.Unpacked _ ->
               Error.reject ~at
                 "A set loop takes one element name per iteration"
           | Syntax.Single _ -> ());
           Loop_plan.check_set_loop ~types:ctx.source.types
             ~kind:(fun value -> value.kind)
             ~at ~target:(List.hd targets) ~carried
             ~references:(Store.references branch.storage)
             ~state_reads:ctx.source.state_reads body);
         let element, _, _ =
           Kind.sequence ~types:ctx.source.types ~at value.kind
         in
         let iterator =
           Loop_plan.iteration ~types:ctx.source.types ~at ~target ~enumerated
             ~iterable ~element ~storage:branch.storage
             ~same_value:(fun term ->
               string_of_exp term.exp = string_of_exp value.exp)
             ~state_backed:(fun () ->
               origin branch ~value <> None
               ||
               match iterable.it with
               | Syntax.Name name -> (
                   match
                     List.assoc_opt name (Store.references branch.storage)
                   with
                   | Some { location = Some _; _ } -> true
                   | _ -> false)
               | _ -> false)
             ~set_iterated body
         in
         let parent_field =
           match iterator.access with Live field -> Some field | _ -> None
         in
         let iterated_identities = iterator.iterated in
         let branch, value = bind ~ctx ~at branch ~term:value in
         let index = fresh ~hint:"nat" ctx ~at ~kind:Kind.integer in
         let name = fresh_helper_name ctx ~operation:"for" in
         let parent_name = "@" ^ name in
         Branch.check_promoted_capture ~at branch;
         let plan = Loop_plan.capture ~carried branch.storage in
         let initial =
           Branch.make
             (Store.enter_for ~carried:(List.map fst carried)
                ~iterated:iterated_identities branch.storage)
           |> guard ~at ~exp:(comparison ~at ~op:`LeOp (nat ~at 0) index.exp)
         in
         let initial =
           if parent_field = None then initial
           else replace_local ~name:parent_name ~value initial
         in
         let active, item =
           Sequence_ops.read_index ~ctx ~at ~branch:initial value ~index
         in
         let active =
           if Expr.is_nonnegative_range ~ctx iterable then
             guard ~at
               ~exp:(comparison ~at ~op:`LeOp (nat ~at 0) item.exp)
               active
           else active
         in
         let active =
           if enumerated then
             replace_local ~name:(List.hd targets) ~value:index active
           else active
         in
         let active =
           if
             (match target with Syntax.Unpacked _ -> true | _ -> false)
             && not enumerated
           then
             Expr.bind_tuple_targets ~ctx ~at
               ~arity_error:"Tuple iteration target arity does not match"
               ~branch:active ~targets item
           else
             match parent_field with
             | Some field ->
                 let reference =
                   Store.iterator_view (string_of_exp item.exp) ~field ~index
                     ~parent:parent_name
                 in
                 {
                   active with
                   storage =
                     Store.bind_local ~name:local ~value:item
                       ~reference:(Some reference) active.storage;
                 }
             | None -> replace_local ~name:local ~value:item active
         in
         let scope = LoopBody (at, fst (List.hd carried)) in
         let iterations = translate ~ctx ~scope body ~branch:active in
         let body =
           Loop.carried_body ~ctx ~at ~carried ~tests:[] ~body ~rest iterations
         in
         Loop.build ~ctx ~at ~name ~plan
           (Indexed
              {
                sequence = value;
                index;
                access = iterator.access;
                parent = parent_name;
                initial;
                body;
              })
           ~branch)

and while_loop ctx at test body rest branch =
  let result_kind =
    if Loop_plan.returns_inside body then (
      if rest <> [] then
        Error.reject ~at
          "A loop that returns must end the function body, since Python cannot \
           reach the statements after it";
      if ctx.source.signature.effect = S.MutatesState then
        Error.reject ~at "A loop that returns is unsupported in a state mutator";
      (match test.it with
      | Syntax.Bool true -> ()
      | _ ->
          Error.reject ~at
            "A loop that returns requires a literal True test, since leaving \
             the loop has no reviewed continuation");
      match ctx.source.signature.returns with
      | Some name -> Some (Named name)
      | None ->
          Error.reject ~at "A loop that returns requires a return annotation")
    else None
  in
  let carried =
    Loop_plan.select_carried
      ~returning:(Option.is_some result_kind)
      ~types:ctx.source.types
      ~kind:(fun value -> value.kind)
      ~at body ~storage:branch.storage
  in
  let name = fresh_helper_name ctx ~operation:"while" in
  let initial = Branch.make (Store.enter_while branch.storage) in
  Branch.check_promoted_capture ~at branch;
  let plan = Loop_plan.capture ~carried branch.storage in
  let loop =
    match result_kind with
    | Some kind ->
        let continuing, returned =
          translate ~ctx ~scope:ReturningLoopBody body ~branch:initial
          |> List.partition_map (fun (branch, completion) ->
                 match completion with
                 | Fallthrough -> Either.Left branch
                 | Returned value -> Either.Right (branch, value)
                 | Broken ->
                     Error.reject ~at
                       "Break requires a loop with a reviewed continuation")
        in
        Returning { kind; continuing; returned }
    | None ->
        let finished = Expr.condition ~ctx test ~holds:false ~branch:initial in
        let iterations =
          Expr.condition ~ctx test ~holds:true ~branch:initial
          |> List.concat_map (fun branch ->
                 translate ~ctx
                   ~scope:(LoopBody (at, fst (List.hd carried)))
                   body ~branch)
        in
        let body =
          Loop.carried_body ~ctx ~at ~carried ~tests:[ test ] ~body ~rest
            iterations
        in
        Conditional { finished; body }
  in
  [ Loop.build ~ctx ~at ~name ~plan loop ~branch ]
