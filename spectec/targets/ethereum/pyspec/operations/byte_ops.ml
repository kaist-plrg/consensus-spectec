open Common.Annotated
open Lang.El
open Value

let bytes_of_value ~ctx ~at ~branch value =
  match value.kind with
  | ByteString _ -> (branch, value)
  | Named name
    when Value.byte_width ~types:(Ctx.types ctx) ~at (Named name) = None
         && Value.is_byte_valued ~types:(Ctx.types ctx) ~at (Named name) ->
      (* A variable-width byte list already carries its encoded width. *)
      (branch, value)
  | _ ->
      let length =
        match Value.byte_width ~types:(Ctx.types ctx) ~at value.kind with
        | Some length -> length
        | None ->
            Error.reject ~at "Byte operations require a fixed source width"
      in
      let branch =
        Numeric_ops.guard_unsigned_bounds ~at
          ~bits:Bigint.(of_int 8 * length)
          ~branch value
      in
      ( branch,
        {
          exp = Prelude.bytes_of_fixed ~at ~width:length value.exp;
          kind = ByteString length;
        } )

let sequence_of_bytes ~ctx ~at ~branch value =
  let length = Value.byte_width ~types:(Ctx.types ctx) ~at value.kind in
  let branch, value = bytes_of_value ~ctx ~at ~branch value in
  Branch.bind ~ctx ~at branch
    ~term:
      {
        exp = call ~at "translated_byte_elements" ~args:[ value.exp; nat ~at 0 ];
        kind = Sequence (ByteInteger, length);
      }

let bytes32_kind ~ctx ~at ~diagnostic =
  match
    List.find_opt
      (fun (_, typ) ->
        typ.Typed.spectec_type = Names.spectec_type_of_named (ByteVector 32)
        &&
        match typ.Typed.descriptor with
        | Typed.Bytes { length = Some length; _ } ->
            Bigint.equal length (Bigint.of_int 32)
        | _ -> false)
      (Ctx.types ctx)
  with
  | Some (name, _) -> Named name
  | None -> Error.reject ~at diagnostic

let bytes32_of_sequence ~ctx ~at ~branch value =
  let value =
    if value.kind = Empty then
      { value with kind = Sequence (Value.integer, Some Bigint.zero) }
    else value
  in
  let { Value.element; _ } =
    Value.sequence ~types:(Ctx.types ctx) ~at value.kind
  in
  if
    not
      (Value.is_integer ~types:(Ctx.types ctx) ~at element
      || Value.bits ~types:(Ctx.types ctx) ~at element <> None)
  then Error.reject ~at "Bytes32 sequence elements require integers";
  let branch, value = Branch.bind ~ctx ~at branch ~term:value in
  let branch =
    Branch.guard ~at
      ~exp:(comparison ~at ~op:`EqOp (LenE value.exp $ at) (nat ~at 32))
      branch
  in
  Branch.bind ~ctx ~at branch
    ~term:
      {
        exp =
          Prelude.fixed_bytes ~at
            (call ~at "translated_bytes_from_ints"
               ~args:[ value.exp; nat ~at 0 ])
            ~width:(nat ~at 32);
        kind = bytes32_kind ~ctx ~at ~diagnostic:"Missing Bytes32 target type";
      }

(* The number of bytes a byte value occupies, statically when the source width
   is nominal and through the runtime width otherwise. *)
let length ~ctx ~at ~branch value =
  match Value.byte_width ~types:(Ctx.types ctx) ~at value.kind with
  | Some length -> (branch, number ~at length)
  | None ->
      let branch =
        Branch.guard ~at ~exp:(Prelude.bytes_valid ~at value.exp) branch
      in
      let width = Prelude.bytes_length ~at value.exp in
      let branch, count =
        Branch.bind ~hint:"nat" ~ctx ~at branch
          ~term:{ exp = width; kind = Value.integer }
      in
      (branch, count.exp)

let concat ~ctx ~at ~branch left ~right =
  let branch, left = bytes_of_value ~ctx ~at ~branch left in
  let branch, right = bytes_of_value ~ctx ~at ~branch right in
  Branch.bind ~ctx ~at branch
    ~term:
      {
        exp = Prelude.concat_bytes ~at left.exp ~right:right.exp;
        kind =
          ByteString
            Bigint.(
              Option.get (Value.byte_width ~types:(Ctx.types ctx) ~at left.kind)
              + Option.get
                  (Value.byte_width ~types:(Ctx.types ctx) ~at right.kind));
      }

let bytes_of_hex ~at value =
  let length = Bigint.of_int (String.length value / 2) in
  let contents =
    if value = "" then Bigint.zero else Bigint.of_string ("0x" ^ value)
  in
  {
    exp =
      Prelude.fixed_bytes ~at (number ~at contents) ~width:(number ~at length);
    kind = ByteString length;
  }

(* The target decoder requires eight bytes. Padding and chunking preserve
   Python's int.from_bytes behavior for other lengths. *)
let integer_of_bytes ~ctx ~at ~branch value =
  let branch, bytes_ = bytes_of_value ~ctx ~at ~branch value in
  let branch, count = length ~ctx ~at ~branch bytes_ in
  Branch.bind ~ctx ~at branch
    ~term:
      {
        exp =
          call ~at
            (Names.builtin_of_primitive Syntax.IntFromBytes)
            ~args:[ bytes_.exp; count ];
        kind = Value.integer;
      }

let index ~ctx ~at ~branch base ~index =
  if
    Value.bits ~types:(Ctx.types ctx) ~at index.kind = None
    && not (Numeric_ops.is_nonnegative ~ctx ~at ~branch index)
  then
    Error.reject ~at
      "Byte indexing requires an index that is unsigned or syntactically \
       nonnegative, since a negative Python index is relative to the end";
  let branch, bytes_ = bytes_of_value ~ctx ~at ~branch base in
  let branch, count = length ~ctx ~at ~branch bytes_ in
  (* The primitive declares a nat index, which an int-typed expression does
     not elaborate against even once it is known nonnegative. *)
  let branch, index =
    if Value.is_integer ~types:(Ctx.types ctx) ~at index.kind then
      Branch.bind ~hint:"nat" ~ctx ~at branch ~term:index
    else (branch, index)
  in
  let branch =
    Branch.guard ~at ~exp:(comparison ~at ~op:`LtOp index.exp count) branch
  in
  Branch.bind ~ctx ~at branch
    ~term:
      {
        exp = Prelude.bytes_get ~at bytes_.exp ~index:index.exp;
        kind = ByteInteger;
      }

let bytes32_of_value ~ctx ~at ~branch value =
  if Value.is_byte_valued ~types:(Ctx.types ctx) ~at value.kind then
    let branch, value = bytes_of_value ~ctx ~at ~branch value in
    let branch, length = length ~ctx ~at ~branch value in
    let branch =
      Branch.guard ~at
        ~exp:(comparison ~at ~op:`EqOp length (nat ~at 32))
        branch
    in
    ( branch,
      {
        value with
        kind = bytes32_kind ~ctx ~at ~diagnostic:"Missing Bytes32 target type";
      } )
  else bytes32_of_sequence ~ctx ~at ~branch value

let nominal_bytes_of_value ~ctx ~at ~name ~branch value =
  if
    Value.byte_width ~types:(Ctx.types ctx) ~at value.kind
    <> Value.byte_width ~types:(Ctx.types ctx) ~at (Named name)
  then Error.reject ~at (name ^ " requires its exact byte width");
  (branch, { value with kind = Named name })

let hash ~ctx ~at ~branch value =
  let branch, value = bytes_of_value ~ctx ~at ~branch value in
  ( branch,
    {
      exp = Prelude.hash ~at value.exp;
      kind =
        bytes32_kind ~ctx ~at ~diagnostic:"Missing 32-byte hash result type";
    } )
