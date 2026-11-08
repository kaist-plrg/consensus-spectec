open Common.Annotated
open Lang.El

type kind =
  | Named of string
  | Optional of kind
  | ByteString of Bigint.t
  | ByteInteger (* A plain Python int in [0, 256) read from bytes. *)
  | G1Point
  | Sequence of kind * Bigint.t option
  | PythonList of kind
  | Set of kind
  | Empty
  | FrozenSequence of kind * Bigint.t
  | Product of kind list

type metadata = (string * Typed.python_type) list
type t = { exp : exp; kind : kind }

let boolean = Named "bool"
let integer = Named "int"

let descriptor_of_kind types at = function
  | Named name -> Some (Typed.descriptor_of_name ~types ~at name)
  | _ -> None

(* Two SSZ byte types with the same width or limit and the same target name
   hold the same representation, even when the source builds them from
   distinct class objects. *)
let bits ~types ~at kind =
  match descriptor_of_kind types at kind with
  | Some (Typed.Uint width) -> Some width
  | _ -> None

let is_integer ~types ~at kind =
  kind = ByteInteger || descriptor_of_kind types at kind = Some Typed.Integer

let is_boolean ~types ~at kind =
  descriptor_of_kind types at kind = Some Typed.Boolean

let is_copyable_scalar ~types ~at kind =
  is_integer ~types ~at kind
  || bits ~types ~at kind = Some 64
  || is_boolean ~types ~at kind

let set_element ~types ~at = function
  | Set element -> Some element
  | kind -> (
      match descriptor_of_kind types at kind with
      | Some (Typed.Set element) -> Some (Named element)
      | _ -> None)

let check_set_value ~types ~at kind ~expected ~diagnostic =
  if set_element ~types ~at kind <> expected then Error.reject ~at diagnostic

let is_number ~types ~at kind =
  is_integer ~types ~at kind || bits ~types ~at kind <> None

let is_same_number_class ~types ~at kind other =
  (is_integer ~types ~at kind && is_integer ~types ~at other)
  ||
  match bits ~types ~at kind with
  | Some width -> bits ~types ~at other = Some width
  | None -> false

let check_number_class ~types ~at kind ~declared ~diagnostic =
  if
    is_number ~types ~at kind
    && is_number ~types ~at declared
    && not (is_same_number_class ~types ~at kind declared)
  then Error.reject ~at diagnostic

type sequence = { element : kind; length : Bigint.t option; bitvector : bool }

let sequence ~types ~at = function
  | FrozenSequence (element, length) ->
      { element; length = Some length; bitvector = false }
  | Sequence (element, length) -> { element; length; bitvector = false }
  | PythonList element -> { element; length = None; bitvector = false }
  | Named name -> (
      match Typed.descriptor_of_name ~types ~at name with
      | Typed.Sequence { element; length; bitvector; _ } ->
          { element = Named element; length; bitvector }
      | _ -> Error.reject ~at "Expected a reviewed sequence")
  | ByteInteger -> Error.reject ~at "A byte element is not a sequence"
  | G1Point -> Error.reject ~at "A G1 point requires a point operation"
  | ByteString _ -> Error.reject ~at "Byte strings require byte operations"
  | Optional _ ->
      Error.reject ~at "An optional value needs a None test before use"
  | Product _ -> Error.reject ~at "Tuple values are not sequence inputs"
  | Empty -> Error.reject ~at "Untyped empty sequence"
  | Set _ -> Error.reject ~at "Set enumeration is not an ordered sequence"

let bounded_ssz_list ~types ~at name =
  match Typed.descriptor_of_name ~types ~at name with
  | Typed.Sequence
      { element; length = None; limit = Some capacity; bitvector = false } ->
      Some (Named element, capacity)
  | _ -> None

let product ~types ~at = function
  | Product elements -> elements
  | kind -> (
      match descriptor_of_kind types at kind with
      | Some (Typed.Product elements) ->
          List.map (fun name -> Named name) elements
      | _ -> Error.reject ~at "Expected a tuple")

let is_readonly_product ~types ~at kind =
  let component name =
    is_copyable_scalar ~types ~at (Named name)
    ||
    match Typed.descriptor_of_name ~types ~at name with
    | Typed.Sequence { element; _ } ->
        is_copyable_scalar ~types ~at (Named element)
    | _ -> false
  in
  match descriptor_of_kind types at kind with
  | Some (Typed.Product elements) -> List.for_all component elements
  | _ -> false

let fields ~types ~at kind =
  match descriptor_of_kind types at kind with
  | Some (Typed.Record fields) -> fields
  | _ -> Error.reject ~at "Expected record"

let byte_width ~types ~at = function
  | ByteString length -> Some length
  | kind -> (
      match descriptor_of_kind types at kind with
      | Some (Typed.Bytes { length; _ }) -> length
      | _ -> None)

(* Source values whose target representation is a byte string of some width. *)
let is_byte_valued ~types ~at = function
  | ByteString _ -> true
  | kind -> (
      match descriptor_of_kind types at kind with
      | Some (Typed.Bytes _) -> true
      | _ -> false)

let is_named_container_or_set ~types ~at = function
  | Set _ -> true
  | kind -> (
      match descriptor_of_kind types at kind with
      | Some (Typed.Record _ | Typed.Sequence _ | Typed.Set _) -> true
      | _ -> false)

let is_flat_record ~types ~at kind =
  match descriptor_of_kind types at kind with
  | Some (Typed.Record fields) ->
      List.for_all
        (fun (_, name) ->
          match Typed.descriptor_of_name ~types ~at name with
          | Typed.Uint _ | Typed.Boolean | Typed.Bytes _ -> true
          | _ -> false)
        fields
  | _ -> false

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

let rec plaintyp_of_kind ~types ~at kind =
  let tuple_type elements =
    TupleT (List.map (plaintyp_of_kind ~types ~at) elements) $ at
  in
  let list_type element =
    IterT (plaintyp_of_kind ~types ~at element, List) $ at
  in
  match kind with
  | Optional element -> IterT (plaintyp_of_kind ~types ~at element, Opt) $ at
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
      let typ = Typed.python_type_of_name ~types ~at name in
      match typ.Typed.descriptor with
      | Typed.Product elements ->
          tuple_type (List.map (fun element -> Named element) elements)
      | Typed.Sequence { element; _ } | Typed.Set element ->
          list_type (Named element)
      | _ -> (
          match typ.Typed.spectec_type with
          | Some Typed.Int -> NumT `IntT $ at
          | Some Typed.Bool -> BoolT $ at
          | Some (Typed.Defined name) -> VarT (id ~at name, []) $ at
          | None -> Error.reject ~at ("Unmapped source type: " ^ name)))

let rec variable ~at name ~typ =
  match typ.it with
  | IterT (element, iter) -> IterE (variable ~at name ~typ:element, iter) $ at
  | _ -> var ~at name

let function_definitions ~at name ~parameters ~result ~equations =
  let declaration =
    DecD
      ( id ~at name,
        [],
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
             [],
             List.map (fun value -> ExpA value $ at) args,
             result,
             premises )
         $ at)
       equations

let conclusion_of_relation ~at declaration ~values =
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
