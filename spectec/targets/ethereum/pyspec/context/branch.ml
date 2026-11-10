open Common.Annotated
open Lang.El
open Value

type t = {
  storage : Store.t;
  premises : Lang.El.prem list;
  options : (string * exp) list;
  promoted : (string * Value.kind) list;
  local_helpers : (string * Syntax.local_helper) list;
}

let make storage =
  { storage; premises = []; options = []; promoted = []; local_helpers = [] }

let map_storage ~f branch = { branch with storage = f branch.storage }

let decide_option ~name ~pattern branch =
  { branch with options = (name, pattern) :: branch.options }

let promote ~promoted branch =
  { branch with promoted = promoted @ branch.promoted }

let add_local_helper (helper : Syntax.local_helper) branch =
  {
    branch with
    local_helpers = (helper.helper, helper) :: branch.local_helpers;
  }

let require ~prem branch =
  if List.exists (fun p -> Lang.El.Eq.eq_prem p prem) branch.premises then
    branch
  else { branch with premises = branch.premises @ [ prem ] }

let guard ~at ~exp branch = require ~prem:(IfPr exp $ at) branch

let guard_boolean_condition ~at ~holds ~exp branch =
  guard ~at
    ~exp:(if holds then exp else UnE (`NotOp, ParenE exp $ at) $ at)
    branch

let has_condition branch ~condition =
  List.exists
    (fun premise ->
      match premise.it with
      | IfPr candidate -> Lang.El.Eq.eq_exp candidate condition
      | _ -> false)
    branch.premises

let bind ?hint ~ctx ~at branch ~term =
  let result = Ctx.fresh ?hint ctx ~at ~kind:term.kind in
  (guard ~at ~exp:(comparison ~at ~op:`EqOp term.exp result.exp) branch, result)

let replace_local ~name ~value branch =
  map_storage ~f:(Store.replace_value ~name ~value) branch

let update_aliases ~identity ~value branch =
  map_storage ~f:(Store.update_aliases ~identity ~value) branch

let origin branch ~value =
  let key = Lang.El.Unparse.string_of_exp value.exp in
  match
    List.assoc_opt Names.state_parameter (Store.bindings branch.storage)
  with
  | Some state when Lang.El.Unparse.string_of_exp state.exp = key -> Some []
  | _ -> Store.origin ~key branch.storage

let remember_origin branch ~base ~step ~value =
  match origin branch ~value:base with
  | None -> (branch, value)
  | Some location ->
      ( map_storage
          ~f:
            (Store.remember_origin
               ~key:(Lang.El.Unparse.string_of_exp value.exp)
               ~location:(location @ [ step ]))
          branch,
        value )

let write_state ?identity ~location ~value branch =
  map_storage
    ~f:
      (Store.write_state ?identity ~state_name:Names.state_parameter ~location
         ~value)
    branch

(* A helper translates its body in a separate branch. That branch lacks the
   restrictions that make a loop accumulator's plain-integer and unsigned cases
   agree, so the helper cannot capture such a result. *)
let check_promoted_capture ~at branch =
  if
    List.exists
      (fun (_, value) ->
        List.mem_assoc (Lang.El.Unparse.string_of_exp value.exp) branch.promoted)
      (Store.bindings branch.storage)
  then
    Error.reject ~at
      "An accumulated loop result cannot be captured by a generated helper"
