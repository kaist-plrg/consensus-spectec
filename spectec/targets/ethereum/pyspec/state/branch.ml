open Common.Source
open Lang.El
open Operand

type t = {
  storage : Operand.t Store.t;
  premises : Lang.El.prem list;
  options : (string * exp) list;
  promoted : (string * Kind.t) list;
  local_helpers : (string * Syntax.local_helper) list;
}

let make storage =
  { storage; premises = []; options = []; promoted = []; local_helpers = [] }

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
  { branch with storage = Store.replace_value ~name ~value branch.storage }

let update_aliases ~identity ~value branch =
  { branch with storage = Store.update_aliases ~identity ~value branch.storage }

let origin branch ~value =
  match List.assoc_opt "state" (Store.bindings branch.storage) with
  | Some state when string_of_exp state.exp = string_of_exp value.exp -> Some []
  | _ -> Store.origin ~key:(string_of_exp value.exp) branch.storage

let remember_origin branch ~base ~step ~value =
  match origin branch ~value:base with
  | None -> (branch, value)
  | Some location ->
      ( {
          branch with
          storage =
            Store.remember_origin ~key:(string_of_exp value.exp)
              ~location:(location @ [ step ]) branch.storage;
        },
        value )

let write_state ?identity ~location ~value branch =
  {
    branch with
    storage = Store.write_state ?identity ~location ~value branch.storage;
  }

(* A generated helper translates its body in a separate branch, which loses
   the restriction that keeps an accumulator's plain-integer and unsigned
   values equal. A helper therefore cannot capture an accumulator whose Python
   type is still undecided. *)
let check_promoted_capture ~at branch =
  if
    List.exists
      (fun (_, value) ->
        List.mem_assoc (string_of_exp value.exp) branch.promoted)
      (Store.bindings branch.storage)
  then
    Error.reject ~at
      "An accumulated loop result cannot be captured by a generated helper"
