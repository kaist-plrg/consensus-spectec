open Common.Source
open Lang.El
open Kind
open Operand
module S = Source

let to_bytes ~ctx ~at ~branch value =
  match value.kind with
  | ByteString _ -> (branch, value)
  | Named name
    when Kind.byte_width ~types:(Ctx.types ctx) ~at (Named name) = None
         && Kind.is_byte_valued ~types:(Ctx.types ctx) ~at (Named name) ->
      (* A variable-width byte list already carries its encoded width. *)
      (branch, value)
  | _ ->
      let length =
        match Kind.byte_width ~types:(Ctx.types ctx) ~at value.kind with
        | Some length -> length
        | None ->
            Error.reject ~at "Byte operations require a fixed source width"
      in
      let branch =
        Branch.guard ~at
          ~exp:(comparison ~at ~op:`LeOp (nat ~at 0) value.exp)
          branch
        |> Branch.guard ~at
             ~exp:
               (comparison ~at ~op:`LtOp value.exp
                  (number ~at Bigint.(pow (of_int 256) length)))
      in
      ( branch,
        {
          exp = Target_builtins.to_bytes ~ctx ~at ~width:length value.exp;
          kind = ByteString length;
        } )

let elements ~ctx ~at ~branch value =
  let length = Kind.byte_width ~types:(Ctx.types ctx) ~at value.kind in
  let branch, value = to_bytes ~ctx ~at ~branch value in
  Target_builtins.declare ~ctx ~at "bytes_length";
  Target_builtins.declare ~ctx ~at "bytes_get";
  let name = "translated_byte_elements" in
  Ctx.share_helper_text ctx ~at ~name ~operation:"byte_iteration"
    ~text:
      {|
    dec $translated_byte_elements(bytes, nat): int*
    def $translated_byte_elements(bytes, nat_index) = eps
      -- if $(nat_index >= $bytes_length(bytes))
    def $translated_byte_elements(bytes, nat_index) = [int_byte] ++ $translated_byte_elements(bytes, $(nat_index + 1))
      -- if $(nat_index < $bytes_length(bytes))
      -- if int_byte = $bytes_get(bytes, nat_index)
      -- if $(0 <= int_byte)
      -- if $(int_byte < 256)
  |};
  Branch.bind ~ctx ~at branch
    ~term:
      {
        exp = call ~at name ~args:[ value.exp; nat ~at 0 ];
        kind = Sequence (ByteInteger, length);
      }

let bytes32_kind ~ctx ~at ~missing =
  match
    List.find_opt
      (fun (_, typ) ->
        typ.S.target = Some "bytes32"
        &&
        match typ.S.descriptor with
        | S.Bytes { length = Some length; _ } ->
            Bigint.equal length (Bigint.of_int 32)
        | _ -> false)
      (Ctx.types ctx)
  with
  | Some (name, _) -> Named name
  | None -> Error.reject ~at missing

let bytes32_of_sequence ~ctx ~at ~branch value =
  let value =
    if value.kind = Empty then
      { value with kind = Sequence (Named "int", Some Bigint.zero) }
    else value
  in
  let element, _, _ = Kind.sequence ~types:(Ctx.types ctx) ~at value.kind in
  if
    not
      (Kind.is_integer ~types:(Ctx.types ctx) ~at element
      || Kind.bits ~types:(Ctx.types ctx) ~at element <> None)
  then Error.reject ~at "Bytes32 sequence elements require integers";
  let branch, value = Branch.bind ~ctx ~at branch ~term:value in
  let branch =
    Branch.guard ~at
      ~exp:(comparison ~at ~op:`EqOp (LenE value.exp $ at) (nat ~at 32))
      branch
  in
  let name = "translated_bytes_from_ints" in
  Ctx.share_helper_text ctx ~at ~name ~operation:"integer_bytes"
    ~text:
      {|
    dec $translated_bytes_from_ints(int*, int): int
    def $translated_bytes_from_ints(eps, int_acc) = int_acc
    def $translated_bytes_from_ints(int_byte :: int_tail*, int_acc) = $translated_bytes_from_ints(int_tail*, $(int_acc * 256 + int_byte))
      -- if $(0 <= int_byte)
      -- if $(int_byte < 256)
  |};
  Branch.bind ~ctx ~at branch
    ~term:
      {
        exp =
          Target_builtins.fixed_bytes ~ctx ~at
            (call ~at name ~args:[ value.exp; nat ~at 0 ])
            ~width:(nat ~at 32);
        kind = bytes32_kind ~ctx ~at ~missing:"Missing Bytes32 target type";
      }

(* The number of bytes a byte value occupies, statically when the source width
   is nominal and through the runtime width otherwise. *)
let length ~ctx ~at ~branch value =
  match Kind.byte_width ~types:(Ctx.types ctx) ~at value.kind with
  | Some length -> (branch, number ~at length)
  | None ->
      let branch =
        Branch.guard ~at
          ~exp:(Target_builtins.bytes_valid ~ctx ~at value.exp)
          branch
      in
      let width = Target_builtins.bytes_length ~ctx ~at value.exp in
      let branch, count =
        Branch.bind ~hint:"nat" ~ctx ~at branch
          ~term:{ exp = width; kind = Named "int" }
      in
      (branch, count.exp)

let concat ~ctx ~at ~branch left ~right =
  let branch, left = to_bytes ~ctx ~at ~branch left in
  let branch, right = to_bytes ~ctx ~at ~branch right in
  Branch.bind ~ctx ~at branch
    ~term:
      {
        exp = Target_builtins.concat_bytes ~ctx ~at left.exp ~right:right.exp;
        kind =
          ByteString
            Bigint.(
              Option.get (Kind.byte_width ~types:(Ctx.types ctx) ~at left.kind)
              + Option.get
                  (Kind.byte_width ~types:(Ctx.types ctx) ~at right.kind));
      }

let literal ~ctx ~at value =
  let length = Bigint.of_int (String.length value / 2) in
  let contents =
    if value = "" then Bigint.zero else Bigint.of_string ("0x" ^ value)
  in
  {
    exp =
      Target_builtins.fixed_bytes ~ctx ~at (number ~at contents)
        ~width:(number ~at length);
    kind = ByteString length;
  }

(* Little-endian decoding is a generated recursive definition over the reviewed
   byte primitives rather than a target decoding helper. *)
let little_endian ~ctx ~at ~branch value =
  let name = "translated_bytes_le" in
  Target_builtins.declare ~ctx ~at "bytes_get";
  Ctx.share_helper ctx ~name ~definitions:(fun () ->
      let data = var ~at "bytes_value" and count = var ~at "nat_count" in
      let previous = arithmetic ~at ~op:`SubOp count (nat ~at 1) in
      function_definitions ~at name
        ~parameters:[ VarT (id ~at "bytes", []) $ at; NumT `NatT $ at ]
        ~result:(NumT `IntT $ at)
        ~equations:
          [
            ([ data; nat ~at 0 ], nat ~at 0, []);
            ( [ data; count ],
              arithmetic ~at ~op:`AddOp
                (call ~at name ~args:[ data; previous ])
                (arithmetic ~at ~op:`MulOp
                   (call ~at "bytes_get" ~args:[ data; previous ])
                   (arithmetic ~at ~op:`PowOp (nat ~at 256) previous)),
              [ IfPr (comparison ~at ~op:`GtOp count (nat ~at 0)) $ at ] );
          ]);
  let branch, bytes_ = to_bytes ~ctx ~at ~branch value in
  let branch, count = length ~ctx ~at ~branch bytes_ in
  Branch.bind ~ctx ~at branch
    ~term:
      { exp = call ~at name ~args:[ bytes_.exp; count ]; kind = Kind.integer }

(* Indexing a byte string yields a plain integer in [0, 255]. A nonnegative
   integer literal is accepted directly, since Python integer literals do not
   carry an unsigned source type but cannot be negative here (a negative
   literal is rejected earlier). An unreviewed signed dynamic index, such as
   a plain int-typed local or expression, still rejects translation. *)
let index ~ctx ~at ~branch base ~index =
  if
    Kind.bits ~types:(Ctx.types ctx) ~at index.kind = None
    && not (Numeric_ops.is_nonnegative ~ctx ~at ~branch index)
  then
    Error.reject ~at
      "Byte indexing requires an index that is unsigned or syntactically \
       nonnegative, since a negative Python index is relative to the end";
  let branch, bytes_ = to_bytes ~ctx ~at ~branch base in
  let branch, count = length ~ctx ~at ~branch bytes_ in
  (* The primitive declares a nat index, which an int-typed expression does
     not elaborate against even once it is known nonnegative. *)
  let branch, index =
    if Kind.is_integer ~types:(Ctx.types ctx) ~at index.kind then
      Branch.bind ~hint:"nat" ~ctx ~at branch ~term:index
    else (branch, index)
  in
  let branch =
    Branch.guard ~at ~exp:(comparison ~at ~op:`LtOp index.exp count) branch
  in
  Branch.bind ~ctx ~at branch
    ~term:
      {
        exp = Target_builtins.bytes_get ~ctx ~at bytes_.exp ~index:index.exp;
        kind = Kind.integer;
      }

let bytes32 ~ctx ~at ~branch value =
  if Kind.is_byte_valued ~types:(Ctx.types ctx) ~at value.kind then
    let branch, value = to_bytes ~ctx ~at ~branch value in
    let branch, length = length ~ctx ~at ~branch value in
    let branch =
      Branch.guard ~at
        ~exp:(comparison ~at ~op:`EqOp length (nat ~at 32))
        branch
    in
    ( branch,
      {
        value with
        kind = bytes32_kind ~ctx ~at ~missing:"Missing Bytes32 target type";
      } )
  else bytes32_of_sequence ~ctx ~at ~branch value

let nominal_bytes ~ctx ~at ~name ~branch value =
  if
    Kind.byte_width ~types:(Ctx.types ctx) ~at value.kind
    <> Kind.byte_width ~types:(Ctx.types ctx) ~at (Named name)
  then Error.reject ~at (name ^ " requires its exact byte width");
  (branch, { value with kind = Named name })

let hash ~ctx ~at ~branch value =
  let branch, value = to_bytes ~ctx ~at ~branch value in
  ( branch,
    {
      exp = Target_builtins.hash ~ctx ~at value.exp;
      kind = bytes32_kind ~ctx ~at ~missing:"Missing 32-byte hash result type";
    } )
