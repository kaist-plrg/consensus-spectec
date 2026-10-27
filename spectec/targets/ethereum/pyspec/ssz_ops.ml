open Common.Source
open Lang.El
open Kind
open Operand
module S = Source

type record = { name : string; fields : (string * string) list }

let validity_guards ~ctx ~at value ~branch =
  let bounds exp bits =
    [
      IfPr (comparison ~at ~op:`LeOp (nat ~at 0) exp) $ at;
      IfPr
        (comparison ~at ~op:`LtOp exp (number ~at Bigint.(pow (of_int 2) bits)))
      $ at;
    ]
  in
  let rec premises exp kind =
    match kind with
    | Named name -> (
        match Kind.descriptor ~types:(Ctx.types ctx) ~at name with
        | S.Uint width -> bounds exp (Bigint.of_int width)
        | S.Bytes { length = Some length; _ } ->
            bounds exp Bigint.(of_int 8 * length)
        | S.Bytes { limit = Some limit; _ } ->
            let length = Target_builtins.bytes_length ~ctx ~at exp in
            [
              IfPr (Target_builtins.bytes_valid ~ctx ~at exp) $ at;
              IfPr (comparison ~at ~op:`LeOp length (number ~at limit)) $ at;
            ]
        | S.Boolean -> []
        | S.SszParameter -> []
        | S.Record fields ->
            List.concat_map
              (fun (field, kind) ->
                premises (DotE (exp, atom ~at field) $ at) (Named kind))
              fields
        | S.Sequence { element; length; limit; _ } ->
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

let type_argument ~ctx ~at = function
  | Named name as kind ->
      (match Kind.descriptor ~types:(Ctx.types ctx) ~at name with
      | S.SszParameter -> ()
      | _ ->
          if not (Target_builtins.accepts_polymorphic_hash_input name) then
            Error.reject ~at ("Unreviewed polymorphic SSZ hash input: " ^ name));
      Operand.typ ~types:(Ctx.types ctx) ~at kind
  | _ -> Error.reject ~at "Polymorphic SSZ inputs require a nominal source type"

let prepare_record ~ctx ~at name ~positional ~keywords =
  let fields = Kind.fields ~types:(Ctx.types ctx) ~at (Named name) in
  (if
     name = Spec_names.signing_data
     && not (Registry.declared_type ~name:"signingData" ctx.Ctx.registry)
   then
     let contents =
       "syntax signingData = { "
       ^ String.concat ", "
           (List.map
              (fun (field, kind) ->
                String.uppercase_ascii field
                ^ " "
                ^ Lang.El.Unparse.string_of_plaintyp
                    (Operand.typ ~types:(Ctx.types ctx) ~at (Named kind)))
              fields)
       ^ " }"
     in
     match
       Spectec.parse_spec_source { filename = "<ssz-record>"; contents }
     with
     | Ok [ declaration ] ->
         Registry.emit ~registry:ctx.Ctx.registry ~ownership:Shared
           [ declaration ]
     | _ -> Error.reject ~at "Invalid generated SSZ record declaration");
  if
    positional
    || List.sort String.compare keywords
       <> List.sort String.compare (List.map fst fields)
  then Error.reject ~at (name ^ " requires every field once as a keyword");
  { name; fields }

let record_field ~ctx ~at ~plan ~name ~branch value =
  let fields = plan.fields in
  let type_name = List.assoc name fields in
  let kind = Named type_name in
  let descriptor = Kind.descriptor ~types:(Ctx.types ctx) ~at type_name in
  let branch, sequence_compatible =
    match (descriptor, value.kind) with
    | ( S.Sequence { element; length = Some length; bitvector = false; _ },
        Sequence (actual, _) )
      when actual = Named element ->
        ( Branch.guard ~at
            ~exp:
              (comparison ~at ~op:`EqOp (LenE value.exp $ at)
                 (number ~at length))
            branch,
          true )
    | ( S.Sequence { element; limit = Some limit; bitvector = false; _ },
        Sequence (actual, _) )
      when actual = Named element ->
        ( Branch.guard ~at
            ~exp:
              (comparison ~at ~op:`LeOp (LenE value.exp $ at) (number ~at limit))
            branch,
          true )
    | _ -> (branch, false)
  in
  let value =
    if value.kind = kind then value
    else if
      Kind.bits ~types:(Ctx.types ctx) ~at value.kind = Some 64
      && Kind.bits ~types:(Ctx.types ctx) ~at kind = Some 64
      || Kind.is_boolean ~types:(Ctx.types ctx) ~at value.kind
         && Kind.is_boolean ~types:(Ctx.types ctx) ~at kind
      || sequence_compatible
    then { value with kind }
    else
      match (descriptor, value.kind) with
      | S.Bytes _, Named actual
        when Kind.equal_byte_types ~types:(Ctx.types ctx) ~at actual type_name
        ->
          { value with kind }
      | _ -> Error.reject ~at "Record field coercions are unsupported"
  in
  (branch, value)

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
    match Kind.bits ~types:(Ctx.types ctx) ~at value.kind with
    | Some (8 | 32 | 64) ->
        Option.get (Kind.bits ~types:(Ctx.types ctx) ~at value.kind)
    | _ ->
        Error.reject ~at
          "Unsigned serialization requires uint8, uint32, or uint64"
  in
  let branch =
    Numeric_ops.guard_unsigned_bounds ~at
      ~upper:(number ~at (Numeric_ops.unsigned_maximum width))
      ~branch value
  in
  ( branch,
    {
      exp = Target_builtins.uint_to_bytes ~ctx ~at ~width value.exp;
      kind = ByteString (Bigint.of_int (width / 8));
    } )

let hash_tree_root ~ctx ~at ~branch value =
  let root = Target_builtins.hash_tree_root_builtin ~ctx ~at value.kind in
  let branch, value = Branch.bind ~ctx ~at branch ~term:value in
  let branch = validity_guards ~ctx ~at value ~branch in
  ( branch,
    {
      exp =
        Target_builtins.hash_tree_root ~at ~root
          ~type_argument:(fun () -> type_argument ~ctx ~at value.kind)
          value.exp;
      kind = Named Spec_names.root;
    } )
