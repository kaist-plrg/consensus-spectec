module Il = Lang.Il
open Static

let inline_bodies : (string, string list * Il.exp) Hashtbl.t = Hashtbl.create 64
let enabled = ref false

let reset () =
  enabled := false;
  Hashtbl.clear inline_bodies

let init_il (spec : Il.spec) =
  reset ();
  enabled := true;
  List.iter
    (fun (def : Il.def) ->
      match def.it with
      | Il.DecD (id, _, _, _, [ { it = params, body, []; _ } ]) ->
          let param_ids =
            List.filter_map
              (fun (param : Il.arg) ->
                match param.it with
                | Il.ExpA { it = Il.VarE pid; _ } -> Some pid.it
                | _ -> None)
              params
          in
          if List.length param_ids = List.length params then
            Hashtbl.replace inline_bodies id.it (param_ids, body)
      | _ -> ())
    spec

let rec subst (env : (string * Il.exp) list) (exp : Il.exp) : Il.exp =
  match exp.it with
  | Il.VarE id -> (
      match List.assoc_opt id.it env with Some e -> e | None -> exp)
  | _ -> Il.Traverse.map_children_exp (subst env) exp

let expand (id : Il.id) (args : Il.arg list) : Il.exp option =
  match Hashtbl.find_opt inline_bodies id.it with
  | None -> None
  | Some (param_ids, body) ->
      let arg_exps =
        List.filter_map
          (fun (arg : Il.arg) ->
            match arg.it with Il.ExpA exp -> Some exp | Il.DefA _ -> None)
          args
      in
      if List.length arg_exps = List.length param_ids then
        Some (subst (List.combine param_ids arg_exps) body)
      else None

let rec subexpressions (exp : Il.exp) : Il.exp list =
  exp :: Il.Traverse.fold_children_exp ( @ ) [] subexpressions exp

let expressions_of_exp (exp : Il.exp) : Il.exp list =
  let syntactic = subexpressions exp in
  let inlined =
    List.concat_map
      (fun (subexp : Il.exp) ->
        match subexp.it with
        | Il.CallE (id, _, args) -> (
            match expand id args with
            | Some body -> subexpressions body
            | None -> [])
        | _ -> [])
      syntactic
  in
  List.fold_left
    (fun unique exp ->
      if List.exists (fun existing -> existing = exp) unique then unique
      else exp :: unique)
    [] (syntactic @ inlined)
  |> List.rev

let expressions_of_prem (prem : Il.prem) : Il.exp list =
  if not !enabled then []
  else
    match prem.it with
    | Il.IfPr exp -> expressions_of_exp exp
    | Il.IterPr ({ it = Il.IfPr exp; _ }, _) -> expressions_of_exp exp
    | _ -> []

let lookup values exp = List.assoc_opt exp values
let init = function IlSpec spec -> init_il spec | SlSpec _ -> reset ()
let export () = None
let restore () = ()

module Premise_values : Static.S = struct
  type export_data = unit

  let name = "premise_values"
  let init = init
  let reset = reset
  let export = export
  let restore = restore
end
