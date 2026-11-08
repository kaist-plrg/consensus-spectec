module Location = Common.Location
open Common.Annotated
module Il = Lang.Il
module Premise_values = Instrumentation_static.Premise_values

let bool_exp it : Il.exp =
  it $$ (Location.Unknown, { Il.Expression.typ = Il.BoolT; annot = () })

let var name = bool_exp (Il.Expression.VarE (name $ Location.Unknown))
let bool value = bool_exp (Il.Expression.BoolE value)
let not_ exp = bool_exp (Il.Expression.UnE (`NotOp, `BoolT, exp))
let and_ lhs rhs = bool_exp (Il.Expression.BinE (`AndOp, `BoolT, lhs, rhs))
let or_ lhs rhs = bool_exp (Il.Expression.BinE (`OrOp, `BoolT, lhs, rhs))
let arg exp = Il.Expression.ExpA exp $ Location.Unknown

let call name args =
  bool_exp
    (Il.Expression.CallE (name $ Location.Unknown, [], List.map arg args))

let clause param body : Il.clause =
  { Il.args = [ arg param ]; body; prems = [] } $ Location.Unknown

let def name clause : Il.def =
  Il.DecD
    {
      defid = name $ Location.Unknown;
      tparams = [];
      params = [];
      typ = Il.BoolT $ Location.Unknown;
      clauses = [ clause ];
    }
  $ Location.Unknown

let assert_mem exp exps = assert (List.mem exp exps)

let () =
  let x = var "x" in
  let y = var "y" in
  let leaf = def "leaf" (clause y (not_ y)) in
  let predicate_body = and_ x (call "leaf" [ x ]) in
  let predicate = def "predicate" (clause x predicate_body) in
  let input = var "input" in
  let condition = or_ (call "predicate" [ input ]) (bool false) in
  let prem =
    Il.IfPr { cond = condition; role = Il.Condition } $$ (Location.Unknown, None)
  in

  Premise_values.reset ();
  assert (Premise_values.expressions_of_prem prem = []);
  Premise_values.init_il [ leaf; predicate ];

  let expressions = Premise_values.expressions_of_prem prem in
  List.iter
    (fun exp -> assert_mem exp expressions)
    (Premise_values.subexpressions condition);

  let predicate_expanded =
    Premise_values.expand ("predicate" $ Location.Unknown) [ arg input ]
    |> Option.get
  in
  List.iter
    (fun exp -> assert_mem exp expressions)
    (Premise_values.subexpressions predicate_expanded);

  let leaf_call =
    Premise_values.subexpressions predicate_expanded
    |> List.find (fun (exp : Il.exp) ->
           match exp.it with
           | Il.Expression.CallE (id, _, _) -> id.it = "leaf"
           | _ -> false)
  in
  let leaf_expanded =
    match leaf_call.it with
    | Il.Expression.CallE (id, _, args) ->
        Premise_values.expand id args |> Option.get
    | _ -> assert false
  in
  assert (not (List.mem leaf_expanded expressions));

  let value = Il.Value.bool true in
  assert (
    Premise_values.lookup [ (predicate_expanded, value) ] predicate_expanded
    = Some value);
  print_endline "OK"
