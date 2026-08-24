open Common.Source
module Il = Lang.Il
module Premise_values = Instrumentation_static.Premise_values

let bool_exp it : Il.exp = it $$ (no_region, Il.BoolT)
let var name = bool_exp (Il.VarE (name $ no_region))
let bool value = bool_exp (Il.BoolE value)
let not_ exp = bool_exp (Il.UnE (`NotOp, `BoolT, exp))
let and_ lhs rhs = bool_exp (Il.BinE (`AndOp, `BoolT, lhs, rhs))
let or_ lhs rhs = bool_exp (Il.BinE (`OrOp, `BoolT, lhs, rhs))
let arg exp = Il.ExpA exp $ no_region

let call name args =
  bool_exp (Il.CallE (name $ no_region, [], List.map arg args))

let clause param body : Il.clause = ([ arg param ], body, []) $ no_region

let def name clause : Il.def =
  Il.DecD (name $ no_region, [], [], Il.BoolT $ no_region, [ clause ])
  $ no_region

let assert_mem exp exps = assert (List.mem exp exps)

let () =
  let x = var "x" in
  let y = var "y" in
  let leaf = def "leaf" (clause y (not_ y)) in
  let predicate_body = and_ x (call "leaf" [ x ]) in
  let predicate = def "predicate" (clause x predicate_body) in
  let input = var "input" in
  let condition = or_ (call "predicate" [ input ]) (bool false) in
  let prem = Il.IfPr condition $ no_region in

  Premise_values.reset ();
  assert (Premise_values.expressions_of_prem prem = []);
  Premise_values.init_il [ leaf; predicate ];

  let expressions = Premise_values.expressions_of_prem prem in
  List.iter
    (fun exp -> assert_mem exp expressions)
    (Premise_values.subexpressions condition);

  let predicate_expanded =
    Premise_values.expand ("predicate" $ no_region) [ arg input ] |> Option.get
  in
  List.iter
    (fun exp -> assert_mem exp expressions)
    (Premise_values.subexpressions predicate_expanded);

  let leaf_call =
    Premise_values.subexpressions predicate_expanded
    |> List.find (fun (exp : Il.exp) ->
           match exp.it with
           | Il.CallE (id, _, _) -> id.it = "leaf"
           | _ -> false)
  in
  let leaf_expanded =
    match leaf_call.it with
    | Il.CallE (id, _, args) -> Premise_values.expand id args |> Option.get
    | _ -> assert false
  in
  assert (not (List.mem leaf_expanded expressions));

  let value = Il.Value.bool true in
  assert (
    Premise_values.lookup [ (predicate_expanded, value) ] predicate_expanded
    = Some value);
  print_endline "OK"
