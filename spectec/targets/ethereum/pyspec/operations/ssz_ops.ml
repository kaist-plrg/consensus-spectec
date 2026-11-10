open Common.Annotated
open Lang.El
open Value

type record = { name : string; fields : (string * string) list }

let validity_guards ~ctx ~at value ~branch =
  let bounds exp bits =
    List.map
      (fun exp -> IfPr exp $ at)
      (Numeric_ops.unsigned_bounds ~at ~bits exp)
  in
  let rec premises exp kind =
    match kind with
    | Named name -> (
        match Typed.descriptor_of_name ~types:(Ctx.types ctx) ~at name with
        | Typed.Uint width -> bounds exp (Bigint.of_int width)
        | Typed.Bytes { length = Some length; _ } ->
            bounds exp Bigint.(of_int 8 * length)
        | Typed.Bytes { limit = Some limit; _ } ->
            let length = Prelude.bytes_length ~at exp in
            [
              IfPr (Prelude.bytes_valid ~at exp) $ at;
              IfPr (comparison ~at ~op:`LeOp length (number ~at limit)) $ at;
            ]
        | Typed.Boolean -> []
        | Typed.SszParameter -> []
        | Typed.Record fields ->
            List.concat_map
              (fun (field, kind) ->
                premises (DotE (exp, atom ~at field) $ at) (Named kind))
              fields
        | Typed.Sequence { element; length; limit; _ } ->
            let shape =
              match (length, limit) with
              | Some length, None ->
                  [
                    IfPr
                      (comparison ~at ~op:`EqOp (LenE exp $ at)
                         (number ~at length))
                    $ at;
                  ]
              | None, Some limit ->
                  [
                    IfPr
                      (comparison ~at ~op:`LeOp (LenE exp $ at)
                         (number ~at limit))
                    $ at;
                  ]
              | _ ->
                  Error.reject ~at
                    "SSZ hash input requires concrete sequence bounds"
            in
            let item = Ctx.fresh ctx ~at ~kind:(Named element) in
            let elements = premises item.exp item.kind in
            if elements = [] then shape
            else
              shape
              @ [
                  IfPr
                    (comparison ~at ~op:`EqOp exp (IterE (item.exp, List) $ at))
                  $ at;
                ]
              @ List.map (fun premise -> IterPr (premise, List) $ at) elements
        | _ -> Error.reject ~at ("Unreviewed SSZ hash input type: " ^ name))
    | _ -> Error.reject ~at "SSZ hash input requires a concrete source type"
  in
  List.fold_left
    (fun branch premise -> Branch.require ~prem:premise branch)
    branch
    (premises value.exp value.kind)

let targ_of_kind ~ctx ~at = function
  | Named name as kind ->
      (match Typed.descriptor_of_name ~types:(Ctx.types ctx) ~at name with
      | Typed.SszParameter -> ()
      | _ ->
          if not (Prelude.accepts_polymorphic_hash_input name) then
            Error.reject ~at ("Unreviewed polymorphic SSZ hash input: " ^ name));
      Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at kind
  | _ -> Error.reject ~at "Polymorphic SSZ inputs require a nominal source type"

let prepare_record ~ctx ~at name ~positional ~keywords =
  let fields = Value.fields ~types:(Ctx.types ctx) ~at (Named name) in
  if
    positional
    || List.sort String.compare keywords
       <> List.sort String.compare (List.map fst fields)
  then Error.reject ~at (name ^ " requires every field once as a keyword");
  { name; fields }

(* A Python list or comprehension result can fill an SSZ sequence with the same
   element type. remerkleable requires an exact vector length or a list length
   within its limit. Other destination shapes or element types need a separate
   conversion. *)
let guard_sequence_field ~ctx ~at ~type_name ~branch value =
  let holds element =
    match value.kind with
    | Sequence (actual, _) | PythonList actual -> actual = Named element
    | Empty -> true
    | _ -> false
  in
  let length_premise ~op bound =
    match value.kind with
    | Empty ->
        if op = `EqOp && not (Bigint.equal bound Bigint.zero) then
          Error.reject ~at "An empty list cannot fill a fixed-length SSZ vector";
        branch
    | _ ->
        Branch.guard ~at
          ~exp:(comparison ~at ~op (LenE value.exp $ at) (number ~at bound))
          branch
  in
  match Typed.descriptor_of_name ~types:(Ctx.types ctx) ~at type_name with
  | Typed.Sequence { element; length = Some length; bitvector = false; _ }
    when holds element ->
      Some (length_premise ~op:`EqOp length)
  | Typed.Sequence { element; limit = Some limit; bitvector = false; _ }
    when holds element ->
      Some (length_premise ~op:`LeOp limit)
  | _ -> None

(* remerkleable coerces SSZ field values, elements and constructor arguments. It
   range-checks plain integers and rejects unsigned values of a different byte
   length. *)
let coerce ~ctx ~at ~kind ~branch value =
  let types = Ctx.types ctx in
  match kind with
  | Named name when Value.bits ~types ~at kind <> None ->
      if Value.is_integer ~types ~at value.kind then
        Numeric_ops.cast ~ctx ~at ~name ~branch value
      else if Value.is_same_number_class ~types ~at value.kind kind then
        (branch, { value with kind })
      else
        Error.reject ~at
          "SSZ stores an unsigned value only into a field of the same width"
  | _
    when value.kind = kind
         || Value.is_boolean ~types ~at value.kind
            && Value.is_boolean ~types ~at kind
         || Value.is_byte_valued ~types ~at value.kind
            && Value.byte_width ~types ~at value.kind <> None
            && Value.byte_width ~types ~at value.kind
               = Value.byte_width ~types ~at kind ->
      (branch, { value with kind })
  | Named type_name -> (
      match guard_sequence_field ~ctx ~at ~type_name ~branch value with
      | Some branch -> (branch, { value with kind })
      | None -> Error.reject ~at "SSZ value conversion is unsupported")
  | _ -> Error.reject ~at "SSZ value conversion is unsupported"

let coerce_field ~ctx ~at ~plan ~name ~branch value =
  coerce ~ctx ~at ~kind:(Named (List.assoc name plan.fields)) ~branch value

let record ~ctx ~at ~plan values ~branch =
  Branch.bind ~ctx ~at branch
    ~term:
      {
        exp =
          StrE
            (List.map
               (fun (name, _) -> (atom ~at name, (List.assoc name values).exp))
               plan.fields)
          $ at;
        kind = Named plan.name;
      }

let serialize ~ctx ~at ~branch value =
  let width =
    match Value.bits ~types:(Ctx.types ctx) ~at value.kind with
    | Some (8 | 32 | 64) ->
        Option.get (Value.bits ~types:(Ctx.types ctx) ~at value.kind)
    | _ ->
        Error.reject ~at
          "Unsigned serialization requires uint8, uint32, or uint64"
  in
  let branch =
    Numeric_ops.guard_unsigned_bounds ~at ~bits:(Bigint.of_int width) ~branch
      value
  in
  ( branch,
    {
      exp = Prelude.uint_to_bytes ~at ~width value.exp;
      kind = ByteString (Bigint.of_int (width / 8));
    } )

let hash_tree_root ~ctx ~at ~branch value =
  let hasher = Prelude.hasher_of_kind ~ctx ~at value.kind in
  let branch, value = Branch.bind ~ctx ~at branch ~term:value in
  let branch = validity_guards ~ctx ~at value ~branch in
  ( branch,
    {
      exp =
        Prelude.hash_tree_root ~at ~hasher
          ~type_argument:(fun () -> targ_of_kind ~ctx ~at value.kind)
          value.exp;
      kind = Named Names.root;
    } )
