module S = Source

type t =
  | Named of string
  | Optional of t
  | ByteString of Bigint.t
  | ByteInteger (* Plain Python int in [0, 256), produced by byte iteration. *)
  | G1Point
  | Sequence of t * Bigint.t option
  | PythonList of t
  | Set of t
  | Empty
  | FrozenSequence of t * Bigint.t
  | Product of t list

type metadata = (string * Source.typ) list

let boolean = Named "bool"
let integer = Named "int"

let source_type ~types ~at name =
  match List.assoc_opt name types with
  | Some typ -> typ
  | None -> Error.reject ~at ("Unresolved name: " ^ name)

let descriptor ~types ~at name = (source_type ~types ~at name).S.descriptor

let named_descriptor types at = function
  | Named name -> Some (descriptor ~types ~at name)
  | _ -> None

(* Two SSZ byte types with the same width or limit and the same target name
   hold the same representation, even when the source builds them from
   distinct class objects. *)
let equal_byte_types ~types ~at left right =
  let left = source_type ~types ~at left
  and right = source_type ~types ~at right in
  match (left.S.descriptor, right.S.descriptor) with
  | S.Bytes left_bytes, S.Bytes right_bytes ->
      left.S.target = right.S.target
      && Option.equal Bigint.equal left_bytes.length right_bytes.length
      && Option.equal Bigint.equal left_bytes.limit right_bytes.limit
  | _ -> false

let bits ~types ~at kind =
  match named_descriptor types at kind with
  | Some (S.Uint width) -> Some width
  | _ -> None

let is_integer ~types ~at kind =
  kind = ByteInteger || named_descriptor types at kind = Some S.Integer

let is_boolean ~types ~at kind = named_descriptor types at kind = Some S.Boolean

let is_copyable_scalar ~types ~at kind =
  is_integer ~types ~at kind
  || bits ~types ~at kind = Some 64
  || is_boolean ~types ~at kind

let set_element ~types ~at = function
  | Set element -> Some element
  | kind -> (
      match named_descriptor types at kind with
      | Some (S.Set element) -> Some (Named element)
      | _ -> None)

let check_set_value ~types ~at kind ~expected ~diagnostic =
  if set_element ~types ~at kind <> expected then Error.reject ~at diagnostic

let sequence ~types ~at = function
  | FrozenSequence (element, length) -> (element, Some length, false)
  | Sequence (element, length) -> (element, length, false)
  | PythonList element -> (element, None, false)
  | Named name -> (
      match descriptor ~types ~at name with
      | S.Sequence { element; length; bitvector; _ } ->
          (Named element, length, bitvector)
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
  match descriptor ~types ~at name with
  | S.Sequence
      { element; length = None; limit = Some capacity; bitvector = false } ->
      Some (Named element, capacity)
  | _ -> None

let product ~types ~at = function
  | Product elements -> elements
  | kind -> (
      match named_descriptor types at kind with
      | Some (S.Product elements) -> List.map (fun name -> Named name) elements
      | _ -> Error.reject ~at "Expected a tuple")

let is_readonly_product ~types ~at kind =
  let component name =
    is_copyable_scalar ~types ~at (Named name)
    ||
    match descriptor ~types ~at name with
    | S.Sequence { element; _ } -> is_copyable_scalar ~types ~at (Named element)
    | _ -> false
  in
  match named_descriptor types at kind with
  | Some (S.Product elements) -> List.for_all component elements
  | _ -> false

let fields ~types ~at kind =
  match named_descriptor types at kind with
  | Some (S.Record fields) -> fields
  | _ -> Error.reject ~at "Expected record"

let byte_width ~types ~at = function
  | ByteString length -> Some length
  | kind -> (
      match named_descriptor types at kind with
      | Some (S.Bytes { length; _ }) -> length
      | _ -> None)

(* Source values whose target representation is a byte string of some width. *)
let is_byte_valued ~types ~at = function
  | ByteString _ -> true
  | kind -> (
      match named_descriptor types at kind with
      | Some (S.Bytes _) -> true
      | _ -> false)

let is_named_container_or_set ~types ~at = function
  | Set _ -> true
  | kind -> (
      match named_descriptor types at kind with
      | Some (S.Record _ | S.Sequence _ | S.Set _) -> true
      | _ -> false)

let is_flat_record ~types ~at kind =
  match named_descriptor types at kind with
  | Some (S.Record fields) ->
      List.for_all
        (fun (_, name) ->
          match descriptor ~types ~at name with
          | S.Uint _ | S.Boolean | S.Bytes _ -> true
          | _ -> false)
        fields
  | _ -> false
