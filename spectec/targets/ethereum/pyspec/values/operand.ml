open Common.Source
open Lang.El
open Kind
module S = Source

type t = { exp : exp; kind : Kind.t }

let string_of_exp exp = Lang.El.Unparse.string_of_exp exp
let id ~at name = name $ at
let var ~at name = VarE (id ~at name) $ at
let number ~at value = NumE (`DecOp, `Nat value) $ at
let nat ~at value = number ~at (Bigint.of_int value)
let bool ~at value = BoolE value $ at
let atom ~at name = Lang.Xl.Atom.keyword (String.uppercase_ascii name) $ at

let unarith exp =
  match exp.it with ArithE inner -> ParenE inner $ exp.at | _ -> exp

let arithmetic ~at ~op left right =
  ArithE (BinE (unarith left, op, unarith right) $ at) $ at

let comparison ~at ~op left right =
  match op with
  | `EqOp | `NeOp -> CmpE (left, op, right) $ at
  | _ -> ArithE (CmpE (unarith left, op, unarith right) $ at) $ at

let call ?(types = []) ~at name ~args =
  CallE (id ~at name, types, List.map (fun exp -> ExpA exp $ at) args) $ at

let rec typ ~types ~at kind =
  let tuple_type elements = TupleT (List.map (typ ~types ~at) elements) $ at in
  let list_type element = IterT (typ ~types ~at element, List) $ at in
  match kind with
  | Optional element -> IterT (typ ~types ~at element, Opt) $ at
  | ByteInteger -> NumT `IntT $ at
  | G1Point -> VarT (id ~at "bytes48", []) $ at
  | ByteString _ -> VarT (id ~at "bytes", []) $ at
  | Product elements -> tuple_type elements
  | Empty -> Error.reject ~at "An empty sequence needs an assignment context"
  | Set element
  | PythonList element
  | Sequence (element, _)
  | FrozenSequence (element, _) ->
      list_type element
  | Named name -> (
      let typ = Kind.source_type ~types ~at name in
      match typ.S.descriptor with
      | S.Product elements ->
          tuple_type (List.map (fun element -> Named element) elements)
      | S.Sequence { element; _ } | S.Set element -> list_type (Named element)
      | _ -> (
          match typ.S.target with
          | Some "int" -> NumT `IntT $ at
          | Some "bool" -> BoolT $ at
          | Some name -> VarT (id ~at name, []) $ at
          | None -> Error.reject ~at ("Unmapped source type: " ^ name)))

let rec variable ~at name ~typ =
  match typ.it with
  | IterT (element, iter) -> IterE (variable ~at name ~typ:element, iter) $ at
  | _ -> var ~at name

let function_definitions ?(type_parameters = []) ~at name ~parameters ~result
    ~equations =
  let type_parameters = List.map (id ~at) type_parameters in
  let declaration =
    DecD
      ( id ~at name,
        type_parameters,
        List.map (fun typ -> ExpP typ $ at) parameters,
        result,
        [] )
    $ at
  in
  declaration
  :: List.map
       (fun (args, result, premises) ->
         DefD
           ( id ~at name,
             type_parameters,
             List.map (fun value -> ExpA value $ at) args,
             result,
             premises )
         $ at)
       equations

let conclusion ~at declaration ~values =
  let rec convert pending = function
    | PlainT _ -> (
        match pending with
        | x :: xs -> (xs, x)
        | [] -> Error.reject ~at "Presentation arity")
    | NotationT typ -> (
        match typ.it with
        | AtomT atom -> (pending, AtomE atom $ at)
        | SeqT types ->
            let pending, exps = List.fold_left_map convert pending types in
            (pending, SeqE exps $ at)
        | InfixT (left, atom, right) ->
            let pending, left = convert pending left in
            let pending, right = convert pending right in
            (pending, InfixE (left, atom, right) $ at)
        | BrackT (left, typ, right) ->
            let pending, exp = convert pending typ in
            (pending, BrackE (left, exp, right) $ at))
  in
  match declaration.it with
  | RelD (_, typ, _) -> (
      match convert values (NotationT typ) with
      | [], result -> result
      | _ -> Error.reject ~at "Presentation arity")
  | _ -> Error.reject ~at "Expected relation presentation"
