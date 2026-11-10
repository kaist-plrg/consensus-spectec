open Common.Annotated
open Lang.El
open Value
open Ctx
open Branch
open Loop

type body_kind =
  | FunctionBody
  | LoopBody of { at : Common.Location.t; returned : string list }
  | ReturningLoopBody

let rec returned_local ~fallthrough name nodes =
  match nodes with
  | [] -> fallthrough name
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
          returned_local ~fallthrough:(fun _ -> false) name body
          || returned_local ~fallthrough name rest
      | _ -> returned_local ~fallthrough name rest)

let falls_through_to_return = function
  | LoopBody { returned; _ } -> fun name -> List.mem name returned
  | FunctionBody | ReturningLoopBody -> fun _ -> false

let loop_body_kind ~at ~body_kind ~carried rest =
  let fallthrough = falls_through_to_return body_kind in
  LoopBody
    {
      at;
      returned =
        List.filter
          (fun name -> returned_local ~fallthrough name rest)
          (List.map fst carried);
    }

(* A returned local's empty list takes its element type from the function's
   sequence return annotation. *)
let empty_list_context ctx body_kind (target : Syntax.expr) rest value =
  let fallthrough = falls_through_to_return body_kind in
  match (value.kind, target.it, (Ctx.source ctx).signature.returns) with
  | Empty, Syntax.Name name, Some result
    when returned_local ~fallthrough name rest -> (
      match
        Typed.descriptor_of_name ~types:(Ctx.types ctx) ~at:target.at result
      with
      | Typed.Sequence { element; _ } ->
          { value with kind = Sequence (Named element, None) }
      | _ -> value)
  | _ -> value

let check_set_result ctx at value =
  let expected =
    Option.bind (Ctx.source ctx).signature.returns (fun name ->
        Value.set_element ~types:(Ctx.types ctx) ~at (Named name))
  in
  Value.check_set_value ~types:(Ctx.types ctx) ~at value.kind ~expected
    ~diagnostic:"Set results require a matching set return annotation"

let check_number_result ctx at value =
  Option.iter
    (fun name ->
      Value.check_number_class ~types:(Ctx.types ctx) ~at value.kind
        ~declared:(Named name)
        ~diagnostic:
          "Return values keep their number class, which must match the return \
           annotation")
    (Ctx.source ctx).signature.returns

let finish_body ctx body_kind branch =
  match body_kind with
  | FunctionBody ->
      if (Ctx.source ctx).signature.effect = Typed.MutatesState then
        ( branch,
          Returned
            (Error.find_or_reject ~at:(Ctx.source ctx).at
               ~name:Names.state_parameter
               (Store.bindings branch.storage)) )
      else
        Error.reject ~at:(Ctx.source ctx).at
          "Implicit None return in a function"
  | LoopBody { at; returned } ->
      List.iter
        (fun name ->
          let value = Expr.read_name ~ctx ~at ~branch name in
          if Value.set_element ~types:(Ctx.types ctx) ~at value.kind <> None
          then check_set_result ctx at value)
        returned;
      (branch, Fallthrough)
  | ReturningLoopBody -> (branch, Fallthrough)

let call_for_effect ~ctx (node : Syntax.expr) ~branch =
  let at = node.at in
  match node.it with
  | Syntax.Call (name, args, keywords) -> (
      match Expr.callee_of_name ~ctx ~branch name with
      | Expr.Local ->
          Error.reject ~at "Mutating calls require an unshadowed name"
      | Expr.LocalHelper _ ->
          if keywords <> [] then
            Error.reject ~at "Local helpers require positional arguments";
          let elements, mutator, operation =
            Call.local_helper_arguments ~ctx ~at args
          in
          Expr.translate ~ctx elements ~branch
          |> List.map (fun (branch, elements) ->
                 Call.local_helper ~ctx ~at ~mutator ~operation ~branch elements)
      | Expr.SetOrAppendList ->
          if keywords <> [] then
            Error.reject ~at "Sequence helpers require positional arguments";
          Write.set_or_append_list ~ctx ~at args ~branch
      | Expr.Constructor | Expr.Builtin _ | Expr.Cast | Expr.Unsupported ->
          Error.reject ~at ("Call effects are not reviewed for " ^ name)
      | Expr.Function signature ->
          let written, order =
            Call.mutator_arguments ~at signature args ~keywords
          in
          Expr.arguments ~ctx written ~branch
          |> Call.mutate ~ctx ~at signature ~order)
  | _ ->
      Error.reject ~at
        "Expression statements must be function calls or list appends"

let rec translate ~ctx ~body_kind nodes ~branch =
  let mutator = (Ctx.source ctx).signature.effect = Typed.MutatesState in
  match nodes with
  | [] -> [ finish_body ctx body_kind branch ]
  | node :: rest -> (
      let at = node.at in
      match node.it with
      | Syntax.Break ->
          (match body_kind with
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
                  (Error.find_or_reject ~at ~name:Names.state_parameter
                     (Store.bindings branch.storage)) );
            ]
          else Error.reject ~at "None return in a function"
      | Syntax.Return (Some { it = Syntax.Tuple elements; _ }) ->
          let expected =
            match (Ctx.source ctx).signature.returns with
            | Some name -> (
                match
                  Typed.descriptor_of_name ~types:(Ctx.types ctx) ~at name
                with
                | Typed.Product elements -> elements
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
                       Value.set_element ~types:(Ctx.types ctx) ~at value.kind
                       <> None
                       || Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at
                            value.kind
                          |> Lang.El.Unparse.string_of_plaintyp
                          <> (Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at
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
                 check_number_result ctx at result;
                 (branch, Returned result))
      | Syntax.If (test, yes, no) ->
          [ (true, yes); (false, no) ]
          |> List.concat_map (fun (truth, body) ->
                 Expr.condition ~ctx test ~holds:truth ~branch
                 |> List.concat_map (fun branch ->
                        translate ~ctx ~body_kind (body @ rest) ~branch))
      | Syntax.For (target, iterable, body) ->
          for_loop ctx body_kind at target iterable body rest branch
          |> resume_loop ctx body_kind rest
      | Syntax.While (test, body) ->
          while_loop ctx body_kind at test body rest branch
          |> resume_loop ctx body_kind rest
      | Syntax.Assert test ->
          Expr.condition ~ctx test ~holds:true ~branch
          |> List.concat_map (fun branch ->
                 translate ~ctx ~body_kind rest ~branch)
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
                       empty_list_context ctx body_kind target rest value
                   (* Python ignores the annotation at run time. It is used only
                      to give an empty literal an element type, which an empty
                      sequence cannot carry on its own. *)
                   | Syntax.AnnotatedAssign (_, annotation, _), Empty ->
                       ignore
                         (Error.find_or_reject ~at ~name:annotation
                            (Ctx.types ctx));
                       { value with kind = Sequence (Named annotation, None) }
                   | _ -> value
                 in
                 translate ~ctx ~body_kind rest
                   ~branch:(Write.store ?copied ~ctx target ~value ~branch))
      | Syntax.AugAssign (op, target, value) ->
          Expr.translate ~ctx target ~branch
          |> List.concat_map (fun (branch, left) ->
                 Expr.translate ~ctx value ~branch
                 |> List.concat_map (fun (branch, right) ->
                        let branch, value =
                          Expr.binary_operator ~ctx ~at ~op ~branch left right
                        in
                        let branch =
                          match (op, left.kind) with
                          | Syntax.Add, (Sequence _ | Empty) ->
                              let name =
                                match Write.owned_list_name ~branch target with
                                | Some name -> name
                                | None ->
                                    Error.reject ~at
                                      "List augmentation requires a valid \
                                       owned local list"
                              in
                              let reference =
                                Error.find_or_reject ~at ~name
                                  (Store.references branch.storage)
                              in
                              Write.apply ~ctx ~at
                                {
                                  container = value;
                                  selection = RootP $ at;
                                  owner = ReferenceWrite reference;
                                }
                                ~replacement:value.exp ~branch
                          | _ -> Write.store ~ctx target ~value ~branch
                        in
                        translate ~ctx ~body_kind rest ~branch))
      | Syntax.Expression
          ({ it = Syntax.Method (receiver, "append", [ value ]); _ } as call) ->
          (* A local list belongs to the function, so extending one is not a
             state effect and a read-only helper may do it. *)
          if (not mutator) && Write.owned_list_name ~branch receiver = None then
            Error.reject ~at "State mutation in a read-only helper";
          Write.append ~ctx ~at:call.at receiver ~value ~branch
          |> List.concat_map (fun branch ->
                 translate ~ctx ~body_kind rest ~branch)
      | Syntax.Expression call ->
          if not mutator then
            Error.reject ~at "State mutation in a read-only helper";
          call_for_effect ~ctx call ~branch
          |> List.concat_map (fun branch ->
                 translate ~ctx ~body_kind rest ~branch)
      | Syntax.LocalHelper helper ->
          if not mutator then
            Error.reject ~at
              "A local mutator helper needs a mutating enclosing body";
          if helper.Syntax.captured <> Names.state_parameter then
            Error.reject ~at
              ("A local helper captures only the root state, not "
             ^ helper.Syntax.captured);
          if List.mem_assoc helper.Syntax.helper branch.local_helpers then
            Error.reject ~at ("Duplicate local helper: " ^ helper.Syntax.helper);
          translate ~ctx ~body_kind rest
            ~branch:(add_local_helper helper branch))

and resume_loop ctx body_kind rest outcomes =
  List.concat_map
    (fun (branch, completion) ->
      match completion with
      | Fallthrough -> translate ~ctx ~body_kind rest ~branch
      | Returned _ -> [ (branch, completion) ]
      | Broken -> assert false)
    outcomes

and for_loop ctx body_kind at target iterable body rest branch =
  let targets = Syntax.target_names target in
  if
    List.exists
      (fun local -> List.mem_assoc local (Store.bindings branch.storage))
      targets
    || List.length (List.sort_uniq String.compare targets)
       <> List.length targets
  then Error.reject ~at "Loop targets must be distinct fresh locals";
  let enumerated, iterable =
    Expr.enumeration ~ctx ~at ~branch
      ~target_error:"For enumeration requires two names and one sequence"
      iterable target
  in
  let local = List.hd (List.rev targets) in
  let carried =
    Loop.select_carried ~types:(Ctx.types ctx) ~at body ~storage:branch.storage
  in
  Expr.iterable ~ctx iterable ~branch
  |> List.map (fun (branch, value) ->
         let set_iterated =
           Value.set_element ~types:(Ctx.types ctx) ~at value.kind <> None
         in
         let value =
           match Value.set_element ~types:(Ctx.types ctx) ~at value.kind with
           | Some element -> { value with kind = Sequence (element, None) }
           | None -> value
         in
         if set_iterated then (
           (match target with
           | Syntax.Unpacked _ ->
               Error.reject ~at
                 "A set loop takes one element name per iteration"
           | Syntax.Single _ -> ());
           Loop.check_set_loop ~types:(Ctx.types ctx) ~at
             ~target:(List.hd targets) ~carried
             ~references:(Store.references branch.storage)
             ~state_reads:(Ctx.source ctx).state_reads body);
         let { Value.element; _ } =
           Value.sequence ~types:(Ctx.types ctx) ~at value.kind
         in
         let iterator =
           Loop.iteration ~types:(Ctx.types ctx) ~at ~target ~enumerated
             ~iterable ~element ~storage:branch.storage ~sequence:value
             ~state_backed:(fun () -> Expr.state_backed ~branch iterable value)
             ~set_iterated body
         in
         let parent_field =
           match iterator.access with Live field -> Some field | _ -> None
         in
         let iterated_identities = iterator.iterated in
         let branch, value = bind ~ctx ~at branch ~term:value in
         let index = fresh ~hint:"nat" ctx ~at ~kind:Value.integer in
         let name = fresh_helper_name ctx ~operation:"for" in
         let parent_name = "@" ^ name in
         Branch.check_promoted_capture ~at branch;
         let plan = Loop.capture ~at ~carried ~body branch.storage in
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
           Expr.bind_loop_targets ~ctx ~at
             ~arity_error:"Tuple iteration target arity does not match"
             ~iterated:iterable ~enumerated ~target ~index ~branch:active item
         in
         let element_named =
           match target with
           | Syntax.Single _ -> true
           | Syntax.Unpacked _ -> enumerated
         in
         let active =
           match parent_field with
           | Some field when element_named ->
               let reference =
                 Store.iterator_view
                   (Lang.El.Unparse.string_of_exp item.exp)
                   ~field ~index ~parent:parent_name
               in
               map_storage
                 ~f:
                   (Store.bind_local ~name:local ~value:item
                      ~reference:(Some reference))
                 active
           | _ -> active
         in
         let iterations =
           translate ~ctx
             ~body_kind:(loop_body_kind ~at ~body_kind ~carried rest)
             body ~branch:active
         in
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

and while_loop ctx body_kind at test body rest branch =
  let result_kind =
    if Loop.returns_inside body then (
      if rest <> [] then
        Error.reject ~at
          "A loop that returns must end the function body, since Python cannot \
           reach the statements after it";
      if (Ctx.source ctx).signature.effect = Typed.MutatesState then
        Error.reject ~at "A loop that returns is unsupported in a state mutator";
      (match test.it with
      | Syntax.Bool true -> ()
      | _ ->
          Error.reject ~at
            "A loop that returns requires a literal True test, since leaving \
             the loop has no reviewed continuation");
      match (Ctx.source ctx).signature.returns with
      | Some name -> Some (Named name)
      | None ->
          Error.reject ~at "A loop that returns requires a return annotation")
    else None
  in
  let carried =
    Loop.select_carried
      ~returning:(Option.is_some result_kind)
      ~types:(Ctx.types ctx) ~at body ~storage:branch.storage
  in
  let name = fresh_helper_name ctx ~operation:"while" in
  let initial = Branch.make (Store.enter_while branch.storage) in
  Branch.check_promoted_capture ~at branch;
  let plan = Loop.capture ~at ~carried ~body branch.storage in
  let loop =
    match result_kind with
    | Some kind ->
        let continuing, returned =
          translate ~ctx ~body_kind:ReturningLoopBody body ~branch:initial
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
                   ~body_kind:(loop_body_kind ~at ~body_kind ~carried rest)
                   body ~branch)
        in
        let body =
          Loop.carried_body ~ctx ~at ~carried ~tests:[ test ] ~body ~rest
            iterations
        in
        Conditional { finished; body }
  in
  [ Loop.build ~ctx ~at ~name ~plan loop ~branch ]
