open Common.Annotated
open Syntax

type descriptor =
  | Uint of int
  | Integer
  | Boolean
  | Opaque
  | SszParameter
  | Bytes of { length : Bigint.t option; limit : Bigint.t option }
  | Product of string list
  | Record of (string * string) list
  | Set of string
  | Sequence of {
      element : string;
      length : Bigint.t option;
      limit : Bigint.t option;
      bitvector : bool;
    }

type spectec_type = Names.spectec_type = Int | Bool | Defined of string

type python_type = {
  descriptor : descriptor;
  spectec_type : spectec_type option;
}

type effect = Pure | MutatesState

type signature = {
  name : string;
  parameters : (string * string) list;
  optional : string list;
  defaults : (string * bool) list;
  returns : string option;
  effect : effect;
  variables : (string * string) list;
  relation : string option;
  fresh_result : bool;
}

type constant_value =
  | IntegerConstant of Bigint.t
  | SequenceConstant of Bigint.t list

type namespace = {
  (* Includes parameters and names bound by assignments, loops, comprehensions,
     lambdas and local helpers. A helper's own name is excluded. *)
  locals : string list;
  (* The module's library bindings that the body reads or calls. *)
  uses : string list;
  (* Record types that a body may construct by calling the type's name. *)
  constructors : string list;
  calls : signature list;
}

type source = {
  signature : signature;
  body : Syntax.statement list;
  at : Common.Location.t;
  namespace : namespace;
  types : (string * python_type) list;
  constants : (string * (string * constant_value)) list;
  state_reads : (string * string list) list;
}

type name_role =
  | Local
  | Function of signature
  | Constructor
  | Cast
  | LibraryBinding
  | SetOrAppendList

type t = {
  types : (string * python_type) list;
  signatures : signature list;
  sources : source list;
  list_results : string list;
}

let invalid message = Error.reject ~at:Common.Location.Unknown message

let string_of_json = function
  | `String s -> s
  | _ -> invalid "Expected JSON string"

let list_of_json = function
  | `List xs -> xs
  | _ -> invalid "Expected JSON array"

let fields_of_json = function
  | `Assoc xs -> xs
  | _ -> invalid "Expected JSON object"

let field name fields =
  match List.assoc_opt name fields with
  | Some x -> x
  | None -> invalid ("Missing field: " ^ name)

let check_keys ~expected fields =
  if
    List.sort String.compare (List.map fst fields)
    <> List.sort String.compare expected
  then invalid ("Expected fields: " ^ String.concat ", " expected)

let check_distinct ~message names =
  Error.check_distinct ~at:Common.Location.Unknown ~message names

let is_lowercase_hex =
  String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)

let sha256_of_json message json =
  let hash = string_of_json json in
  if String.length hash <> 64 || not (is_lowercase_hex hash) then
    invalid message;
  hash

let rec check_unique_keys = function
  | `Assoc fields ->
      check_distinct ~message:"Duplicate JSON object key" (List.map fst fields);
      List.iter (fun (_, value) -> check_unique_keys value) fields
  | `List values -> List.iter check_unique_keys values
  | _ -> ()

let identifier_of_json json =
  let name = string_of_json json in
  let letter c = ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || c = '_' in
  if
    name = ""
    || (not (letter name.[0]))
    || not (String.for_all (fun c -> letter c || ('0' <= c && c <= '9')) name)
  then invalid "Invalid source identifier";
  name

let integer_of_json json =
  let text = string_of_json json in
  let digits =
    if String.starts_with ~prefix:"-" text then
      String.sub text 1 (String.length text - 1)
    else text
  in
  if digits = "" || not (String.for_all (fun c -> '0' <= c && c <= '9') digits)
  then invalid "Expected decimal integer string";
  Bigint.of_string text

let natural_of_json json =
  let n = integer_of_json json in
  if Bigint.compare n Bigint.zero < 0 then
    invalid "Expected nonnegative integer"
  else n

let pos_of_json = function
  | `List [ `Int line; `Int column ] when line >= 1 && column >= 0 ->
      { Common.Location.line; column }
  | _ -> invalid "Expected [positive line, nonnegative byte column]"

let location_of_json file = function
  | `Null -> Common.Location.Unknown
  | json ->
      let fields = fields_of_json json in
      check_keys ~expected:[ "start"; "end" ] fields;
      let left = pos_of_json (field "start" fields)
      and right = pos_of_json (field "end" fields) in
      if (right.line, right.column) < (left.line, left.column) then
        invalid "Reversed source span";
      Common.Location.Span { file; left; right }

let bool_of_json = function
  | `Bool x -> x
  | _ -> invalid "Expected JSON boolean"

let option_of_json f = function `Null -> None | x -> Some (f x)
let identifiers_of_json json = List.map identifier_of_json (list_of_json json)

let target_of_json names tuple =
  match (names, bool_of_json tuple) with
  | _, true -> Unpacked names
  | [ name ], false -> Single name
  | _, false -> invalid "A loop target without a tuple needs one name"

let operator_of_json operators json =
  let op = string_of_json json in
  match List.assoc_opt op operators with
  | Some op -> op
  | None -> invalid ("Unsupported operator: " ^ op)

let binop_of_json =
  operator_of_json
    (List.map
       (fun op -> (string_of_binop op, op))
       [ Add; Sub; Mult; Mod; FloorDiv; Pow; BitAnd; BitOr; BitXor; RShift ])

let cmpop_of_json =
  operator_of_json
    [
      ("Eq", Eq);
      ("NotEq", NotEq);
      ("Lt", Lt);
      ("LtE", LtE);
      ("Gt", Gt);
      ("GtE", GtE);
      ("In", In);
      ("NotIn", NotIn);
      ("Is", Is);
      ("IsNot", IsNot);
    ]

let rec expr_of_json file json =
  let fields = fields_of_json json in
  let at = location_of_json file (field "span" fields) in
  let get name = field name fields in
  let check names = check_keys ~expected:("kind" :: "span" :: names) fields in
  let expr name = expr_of_json file (get name) in
  let exprs name = List.map (expr_of_json file) (list_of_json (get name)) in
  let it =
    match string_of_json (get "kind") with
    | "name" ->
        check [ "id" ];
        Name (identifier_of_json (get "id"))
    | "integer" ->
        check [ "value" ];
        Int (integer_of_json (get "value"))
    | "bytes_literal" ->
        check [ "value" ];
        let value = string_of_json (get "value") in
        if String.length value mod 2 <> 0 || not (is_lowercase_hex value) then
          invalid
            "Byte literals require an even number of lowercase hexadecimal \
             digits";
        BytesLiteral value
    | "boolean" ->
        check [ "value" ];
        Bool (bool_of_json (get "value"))
    | "empty" ->
        check [];
        Empty
    | "none" ->
        check [];
        NoneValue
    | "list" ->
        check [ "elements" ];
        ListLiteral (exprs "elements")
    | "tuple" ->
        check [ "elements" ];
        Tuple (exprs "elements")
    | "lambda" ->
        check [ "parameter"; "body" ];
        Lambda (identifier_of_json (get "parameter"), expr "body")
    | "attribute" ->
        check [ "value"; "field" ];
        Attribute (expr "value", identifier_of_json (get "field"))
    | "subscript" ->
        check [ "value"; "index" ];
        Index (expr "value", expr "index")
    | "slice" ->
        check [ "lower"; "upper"; "step" ];
        Slice
          ( option_of_json (expr_of_json file) (get "lower"),
            option_of_json (expr_of_json file) (get "upper"),
            option_of_json (expr_of_json file) (get "step") )
    | "binary" ->
        check [ "operator"; "left"; "right" ];
        Binary (binop_of_json (get "operator"), expr "left", expr "right")
    | "boolop" ->
        check [ "operator"; "values" ];
        let op =
          operator_of_json [ ("And", And); ("Or", Or) ] (get "operator")
        in
        let values = exprs "values" in
        if List.length values < 2 then invalid "Boolean operator arity";
        Boolop (op, values)
    | "negate" ->
        check [ "value" ];
        Negate (expr "value")
    | "not" ->
        check [ "value" ];
        Not (expr "value")
    | "compare" ->
        check [ "left"; "operators"; "rights" ];
        let ops = List.map cmpop_of_json (list_of_json (get "operators"))
        and rights = exprs "rights" in
        if ops = [] || List.length ops <> List.length rights then
          invalid "Comparison arity";
        Compare (expr "left", List.combine ops rights)
    | "conditional" ->
        check [ "test"; "body"; "orelse" ];
        Conditional (expr "test", expr "body", expr "orelse")
    | "method" ->
        check [ "value"; "method"; "args" ];
        let method_ = identifier_of_json (get "method") in
        if not (List.mem method_ Names.admitted_methods) then
          invalid "Unreviewed sequence method";
        Method (expr "value", method_, exprs "args")
    | "primitive" ->
        check [ "namespace"; "name"; "args" ];
        let primitive =
          match
            Names.primitive_of_name
              ~namespace:(identifier_of_json (get "namespace"))
              (identifier_of_json (get "name"))
          with
          | Some primitive -> primitive
          | None -> Error.reject ~at "Unreviewed primitive"
        in
        let args = exprs "args" in
        (match (primitive, args) with
        | IntFromBytes, [ _; { it = Name name; _ } ]
          when name = Names.endianness ->
            ()
        | IntFromBytes, _ -> Error.reject ~at "Unreviewed integer byte decoding"
        | _ -> ());
        Primitive (primitive, args)
    | "call" ->
        check [ "name"; "args"; "keywords" ];
        let keywords =
          List.map
            (fun json ->
              let fields = fields_of_json json in
              check_keys ~expected:[ "name"; "value" ] fields;
              ( identifier_of_json (field "name" fields),
                expr_of_json file (field "value" fields) ))
            (list_of_json (get "keywords"))
        in
        Call (identifier_of_json (get "name"), exprs "args", keywords)
    | ("comprehension" | "generator") as kind ->
        check [ "element"; "targets"; "tuple_target"; "iterable"; "filters" ];
        let element = expr "element" in
        let target =
          target_of_json
            (identifiers_of_json (get "targets"))
            (get "tuple_target")
        in
        let iterable = expr "iterable" and filters = exprs "filters" in
        if kind = "generator" then Generator (element, target, iterable, filters)
        else Comprehension (element, target, iterable, filters)
    | name -> invalid ("Unsupported expression: " ^ name)
  in
  it $ at

let rec statements_of_json file json =
  List.map
    (fun json ->
      let fields = fields_of_json json in
      let get name = field name fields in
      let check names =
        check_keys ~expected:("kind" :: "span" :: names) fields
      in
      let expr name = expr_of_json file (get name) in
      let it =
        match string_of_json (get "kind") with
        | "assign" ->
            check [ "target"; "value" ];
            Assign (expr "target", expr "value")
        | "annotated_assign" ->
            check [ "target"; "annotation"; "value" ];
            AnnotatedAssign
              ( expr "target",
                identifier_of_json (get "annotation"),
                expr "value" )
        | "aug_assign" ->
            check [ "operator"; "target"; "value" ];
            AugAssign
              (binop_of_json (get "operator"), expr "target", expr "value")
        | "break" ->
            check [];
            Break
        | "local_helper" ->
            check [ "name"; "elements"; "callable"; "element"; "captured" ];
            let names =
              List.map
                (fun name -> identifier_of_json (get name))
                [ "name"; "elements"; "callable"; "element"; "captured" ]
            in
            check_distinct ~message:"Local helper names must be distinct" names;
            LocalHelper
              {
                helper = List.nth names 0;
                elements = List.nth names 1;
                mutator = List.nth names 2;
                element = List.nth names 3;
                captured = List.nth names 4;
              }
        | "return" ->
            check [ "value" ];
            Return (option_of_json (expr_of_json file) (get "value"))
        | "if" ->
            check [ "test"; "body"; "orelse" ];
            If
              ( expr "test",
                statements_of_json file (get "body"),
                statements_of_json file (get "orelse") )
        | "for" ->
            check [ "targets"; "tuple_target"; "iterable"; "body" ];
            For
              ( target_of_json
                  (identifiers_of_json (get "targets"))
                  (get "tuple_target"),
                expr "iterable",
                statements_of_json file (get "body") )
        | "while" ->
            check [ "test"; "body" ];
            While (expr "test", statements_of_json file (get "body"))
        | "assert" ->
            check [ "test" ];
            Assert (expr "test")
        | "expression" ->
            check [ "value" ];
            Expression (expr "value")
        | name -> invalid ("Unsupported statement: " ^ name)
      in
      it $ location_of_json file (get "span"))
    (list_of_json json)

let bytes_descriptor_of_fields fields =
  let length = option_of_json natural_of_json (field "length" fields) in
  let limit = option_of_json natural_of_json (field "limit" fields) in
  let unbounded = bool_of_json (field "unbounded" fields) in
  (* A length and a limit cannot both be present. Absence of both is
     ambiguous between a malformed document and a deliberately unbounded
     plain byte string, so the exporter must mark the latter
     explicitly. The decoder does not infer it. *)
  (match (length, limit, unbounded) with
  | Some _, None, false | None, Some _, false | None, None, true -> ()
  | _ ->
      invalid "Bytes require exactly one length or limit, or explicit unbounded");
  Bytes { length; limit }

let uint_descriptor_of_json = function
  | `Int bits when bits > 0 -> Uint bits
  | _ -> invalid "Invalid uint width"

let sequence_descriptor_of_fields fields =
  let length = option_of_json natural_of_json (field "length" fields) in
  let limit = option_of_json natural_of_json (field "limit" fields) in
  let bitvector = bool_of_json (field "bitvector" fields) in
  (match (bitvector, length, limit) with
  | true, None, _ | true, _, Some _ ->
      invalid "A bitvector requires a length and no limit"
  | _ -> ());
  Sequence
    {
      element = string_of_json (field "element" fields);
      length;
      limit;
      bitvector;
    }

let spectec_type_of_descriptor name = function
  | SszParameter -> Some (Defined name)
  | Bytes { length = None; _ } -> Names.spectec_type_of_named (Type "bytes")
  | Bytes { length = Some width; _ } -> (
      match Names.spectec_type_of_named (Type name) with
      | Some _ as named -> named
      | None ->
          Option.bind (Bigint.to_int width) (fun width ->
              Names.spectec_type_of_named (ByteVector width)))
  | _ -> Names.spectec_type_of_named (Type name)

let python_type_of_json (name, json) =
  let fields = fields_of_json json in
  let get name = field name fields in
  let check names = check_keys ~expected:("kind" :: names) fields in
  let descriptor =
    match string_of_json (get "kind") with
    | "uint" ->
        check [ "bits" ];
        uint_descriptor_of_json (get "bits")
    | "integer" ->
        check [];
        Integer
    | "boolean" ->
        check [];
        Boolean
    | "bytes" ->
        check [ "length"; "limit"; "unbounded" ];
        bytes_descriptor_of_fields fields
    | "opaque" ->
        check [];
        Opaque
    | "ssz_parameter" ->
        check [];
        SszParameter
    | "record" ->
        check [ "fields" ];
        Record
          (List.map
             (fun (name, typ) ->
               (identifier_of_json (`String name), string_of_json typ))
             (fields_of_json (get "fields")))
    | "tuple" ->
        check [ "elements" ];
        Product (List.map string_of_json (list_of_json (get "elements")))
    | "set" ->
        check [ "element" ];
        Set (string_of_json (get "element"))
    | "sequence" ->
        check [ "element"; "length"; "limit"; "bitvector" ];
        sequence_descriptor_of_fields fields
    | name -> invalid ("Unsupported type descriptor: " ^ name)
  in
  ( name,
    { descriptor; spectec_type = spectec_type_of_descriptor name descriptor } )

let parameter_of_json json =
  let fields = fields_of_json json in
  if List.mem_assoc "default" fields then
    check_keys ~expected:[ "name"; "type"; "optional"; "default" ] fields
  else check_keys ~expected:[ "name"; "type"; "optional" ] fields;
  let name = identifier_of_json (field "name" fields) in
  let typ = string_of_json (field "type" fields) in
  let flag = bool_of_json (field "optional" fields) in
  let default =
    match List.assoc_opt "default" fields with
    | None -> None
    | Some value ->
        (* A None default makes the parameter optional, so it cannot also have a
           literal boolean default. *)
        if flag then invalid "Optional parameter with a literal default";
        if typ <> "bool" then
          invalid "Literal default on a non-boolean parameter";
        Some (bool_of_json value)
  in
  (name, typ, flag, default)

let check_type ~types name =
  if not (List.mem_assoc name types) then invalid ("Unresolved type: " ^ name)

let check_type_references ~check (typ : python_type) =
  match typ.descriptor with
  | Product elements -> List.iter check elements
  | Record fields -> List.iter (fun (_, name) -> check name) fields
  | Sequence { element; _ } | Set element -> check element
  | _ -> ()

let python_type_of_name ~types ~at name = Error.find_or_reject ~at ~name types

let descriptor_of_name ~types ~at name =
  (python_type_of_name ~types ~at name).descriptor

let rec holds_ssz_parameter ~types name =
  match descriptor_of_name ~types ~at:Common.Location.Unknown name with
  | SszParameter -> true
  | Sequence { element; _ } | Set element -> holds_ssz_parameter ~types element
  | Product elements -> List.exists (holds_ssz_parameter ~types) elements
  | _ -> false

let nests_ssz_parameter ~types name =
  descriptor_of_name ~types ~at:Common.Location.Unknown name <> SszParameter
  && holds_ssz_parameter ~types name

let check_signature_contract ~types ~name ~parameters ~optional ~returns ~effect
    =
  let generic typ =
    descriptor_of_name ~types ~at:Common.Location.Unknown typ = SszParameter
  in
  let types_of_signature = Option.to_list returns @ List.map snd parameters in
  if parameters = [] then invalid ("Unsupported source signature for " ^ name);
  if List.exists (nests_ssz_parameter ~types) types_of_signature then
    invalid "Nested SSZ type parameters are outside the source subset";
  if Option.fold ~none:false ~some:generic returns then
    invalid "Generic return types are outside the source subset";
  (match (effect, returns, parameters) with
  | Pure, Some _, _ -> ()
  | MutatesState, None, (parameter, typ) :: _
    when parameter = Names.state_parameter && typ = Names.state_type ->
      ()
  | _ -> invalid "Invalid reviewed effect/signature contract");
  if
    effect = MutatesState
    && List.exists (fun (_, typ) -> generic typ) parameters
  then invalid "Generic state-mutator signatures are unsupported";
  if
    List.length
      (List.filter (fun (_, typ) -> typ = Names.execution_engine) parameters)
    > 1
  then invalid ("More than one execution engine for " ^ name);
  if
    List.exists
      (fun (parameter, typ) -> List.mem parameter optional && generic typ)
      parameters
  then invalid "Optional SSZ type parameters are outside the source subset"

let is_alphanumeric c =
  ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || ('0' <= c && c <= '9')

let is_valid_variable variable =
  match String.split_on_char '_' variable with
  | first :: rest ->
      first <> ""
      && (not ('0' <= first.[0] && first.[0] <= '9'))
      && List.for_all
           (fun word -> word <> "" && String.for_all is_alphanumeric word)
           (first :: rest)
  | [] -> false

let is_valid_relation relation =
  relation <> ""
  && 'A' <= relation.[0]
  && relation.[0] <= 'Z'
  && String.for_all is_alphanumeric relation

let rec spectec_type_of_parameter_type ~types ~invalid_variable name =
  let typ = List.assoc name types in
  match (typ.descriptor, typ.spectec_type) with
  | (Sequence { element; _ } | Set element), _ ->
      spectec_type_of_parameter_type ~types ~invalid_variable element
  | Product _, _ -> invalid_variable ()
  | _, Some spectec_type -> spectec_type
  | _, None -> invalid ("Unmapped source type: " ^ name)

let variables_of_parameters ~types ~name parameters =
  let arguments =
    List.map
      (fun (parameter, typ) ->
        let invalid_variable () =
          invalid ("Invalid argument variable for " ^ name ^ "." ^ parameter)
        in
        let variable =
          Names.variable_of_parameter
            (spectec_type_of_parameter_type ~types ~invalid_variable typ)
            parameter
        in
        if not (is_valid_variable variable) then invalid_variable ();
        (parameter, variable))
      parameters
  in
  check_distinct
    ~message:("Argument variables must be distinct for " ^ name)
    (List.map snd arguments);
  arguments

let signature_of_fields ~types ~fresh_results fields =
  let get name = field name fields in
  let parameters =
    List.map parameter_of_json (list_of_json (get "parameters"))
  in
  let optional_parameters =
    List.filter_map
      (fun (name, _, flag, _) -> if flag then Some name else None)
      parameters
  in
  let literal_defaults =
    List.filter_map
      (fun (name, _, _, default) ->
        Option.map (fun value -> (name, value)) default)
      parameters
  in
  let parameters = List.map (fun (name, typ, _, _) -> (name, typ)) parameters in
  check_distinct ~message:"Duplicate parameter name" (List.map fst parameters);
  let name = identifier_of_json (get "name") in
  let returns = option_of_json string_of_json (get "returns") in
  let effect =
    match option_of_json identifier_of_json (get "effect") with
    | None -> Pure
    | Some "state" -> MutatesState
    | Some _ -> invalid "Invalid reviewed effect/signature contract"
  in
  List.iter (fun (_, typ) -> check_type ~types typ) parameters;
  Option.iter (check_type ~types) returns;
  check_signature_contract ~types ~name ~parameters
    ~optional:optional_parameters ~returns ~effect;
  let relation =
    match effect with
    | Pure -> None
    | MutatesState ->
        let relation = Names.relation_of_function name in
        if not (is_valid_relation relation) then
          invalid ("Invalid relation name for " ^ name);
        Some relation
  in
  {
    name;
    parameters;
    optional = optional_parameters;
    defaults = literal_defaults;
    returns;
    effect;
    variables = variables_of_parameters ~types ~name parameters;
    relation;
    fresh_result = List.mem name fresh_results;
  }

let function_fields_of_json json =
  let fields = fields_of_json json in
  let signature = [ "name"; "parameters"; "returns"; "effect" ] in
  (match field "body" fields with
  | `Null -> check_keys ~expected:("body" :: signature) fields
  | _ -> check_keys ~expected:("body" :: "span" :: signature) fields);
  fields

let check_sequence_constant ~types typ values =
  let element =
    match (List.assoc typ types).descriptor with
    | Sequence { element; length = None; limit = None; bitvector = false } ->
        element
    | _ -> invalid "Sequence constant requires a scalar sequence type"
  in
  if (List.assoc element types).descriptor <> Uint 64 then
    invalid "Sequence constants require uint64 elements";
  if
    values = []
    || List.exists
         (fun value ->
           Bigint.compare value (Bigint.of_string "18446744073709551615") > 0)
         values
  then invalid "Invalid sequence constant values"

let check_bindings names =
  check_distinct ~message:"Duplicate library binding" names;
  List.iter
    (fun name ->
      if not (List.mem name Names.library) then
        invalid ("Unreviewed library binding: " ^ name))
    names

let two_roles_message name = "Name with more than one role: " ^ name

(* [role_of_name] checks roles other than local in a fixed order. Validation
   must assign at most one of those roles to each name. *)
let check_one_role roles =
  let rec check = function
    | first :: (second :: _ as rest) ->
        if first = second then invalid (two_roles_message first) else check rest
    | _ -> ()
  in
  check
    (List.concat_map (List.sort_uniq String.compare) roles
    |> List.sort String.compare)

let bindings_of_primitive primitive =
  let namespace = Names.namespace_of_primitive primitive in
  match primitive with
  | Syntax.IntFromBytes ->
      ([ namespace; Names.endianness ], "Unreviewed little-endian byte decoding")
  | _ -> ([ namespace ], "Unreviewed BLS namespace binding")

let builtins_of_primitive primitive =
  Names.builtin_of_primitive primitive
  ::
  (match primitive with
  | Syntax.BlsAggregatePubkeys -> [ Names.builtin_of_primitive BlsKeyValidate ]
  | _ -> [])

let locals_and_uses ~bindings ~at (signature : signature) body =
  let locals =
    List.sort_uniq String.compare
      (List.map fst signature.parameters @ Syntax.bound_names body)
  in
  let names = Syntax.names body and called = Syntax.called_names body in
  let primitives = Syntax.primitive_calls body in
  let referenced =
    names @ called @ List.map Names.namespace_of_primitive primitives
  in
  let shadowed name = List.mem name locals in
  List.iter
    (fun primitive ->
      let required, message = bindings_of_primitive primitive in
      if
        List.exists
          (fun name -> (not (List.mem name bindings)) || shadowed name)
          required
      then Error.reject ~at message)
    primitives;
  if
    List.mem Names.new_payload_request called
    && shadowed Names.new_payload_request
  then Error.reject ~at "Shadowed execution-payload request constructor";
  if
    List.mem Names.execution_engine_global names
    && shadowed Names.execution_engine_global
  then Error.reject ~at "Shadowed external execution-engine global";
  (* An execution-engine handle represents one external service. Mixing a
     supplied handle with the global engine would make two services share one
     verdict. *)
  if
    List.mem Names.execution_engine_global names
    && List.exists
         (fun (_, typ) -> typ = Names.execution_engine)
         signature.parameters
  then
    Error.reject ~at
      "A supplied execution engine cannot be mixed with the global";
  let notifies =
    List.exists
      (fun (node : Syntax.expr) ->
        match node.it with
        | Syntax.Method (_, name, _) -> name = Names.new_payload_method
        | _ -> false)
      (Syntax.expressions body)
  in
  (* A source call and a generated builtin call with the same name would be
     indistinguishable in the target. *)
  List.iter
    (fun name ->
      if List.mem name called then
        Error.reject ~at
          ("Source call name collides with a synthetic builtin: " ^ name))
    (List.concat_map builtins_of_primitive primitives
    @ if notifies then [ Names.new_payload_builtin ] else []);
  (locals, List.filter (fun name -> List.mem name referenced) bindings)

let update_list_binding env name established =
  let remaining = List.filter (( <> ) name) env in
  if established then name :: remaining else remaining

let establishes_list known (source : source) =
  let rec list_value env (node : Syntax.expr) =
    match node.it with
    | Syntax.Empty | Syntax.ListLiteral _ | Syntax.Comprehension _ -> true
    | Syntax.Name name -> List.mem name env
    | Syntax.Conditional (_, yes, no) -> list_value env yes && list_value env no
    | Syntax.Call (name, _, _) ->
        (not (List.mem name source.namespace.locals))
        && (List.mem name known
           || (name = "sorted" && List.mem name source.namespace.uses))
    | _ -> false
  in
  let join left right =
    match (left, right) with
    | None, other | other, None -> other
    | Some left, Some right ->
        Some (List.filter (fun name -> List.mem name right) left)
  in
  let rec walk env = function
    | [] -> (Some env, [])
    | (node : Syntax.statement) :: rest -> (
        let continue env results =
          match env with
          | None -> (None, results)
          | Some env ->
              let ending, later = walk env rest in
              (ending, results @ later)
        in
        match node.it with
        | Syntax.Return value ->
            (None, [ Option.fold ~none:false ~some:(list_value env) value ])
        | Syntax.Break -> (None, [])
        | Syntax.Assign ({ it = Syntax.Name name; _ }, value)
        | Syntax.AnnotatedAssign ({ it = Syntax.Name name; _ }, _, value) ->
            let env = update_list_binding env name (list_value env value) in
            walk env rest
        | Syntax.AugAssign (_, { it = Syntax.Name name; _ }, _) ->
            walk (update_list_binding env name false) rest
        | Syntax.If (_, yes, no) ->
            let left, left_results = walk env yes in
            let right, right_results = walk env no in
            continue (join left right) (left_results @ right_results)
        | Syntax.For (target, _, body) ->
            walk_loop_body env
              (Syntax.target_names target @ Syntax.assigned_names body)
              body rest
        | Syntax.While (_, body) ->
            walk_loop_body env (Syntax.assigned_names body) body rest
        | _ -> walk env rest)
  and walk_loop_body env writes body rest =
    let env = List.filter (fun name -> not (List.mem name writes)) env in
    let _, results = walk env body in
    let ending, later = walk env rest in
    (ending, results @ later)
  in
  let generic_sequence =
    match source.signature.returns with
    | None -> false
    | Some name -> (
        match (List.assoc name source.types).descriptor with
        | Sequence { length = None; limit = None; bitvector = false; _ } -> true
        | _ -> false)
  in
  if source.signature.effect = MutatesState || not generic_sequence then false
  else
    let ending, results = walk [] source.body in
    ending = None && results <> [] && List.for_all Fun.id results

let infer_list_results sources =
  let rec fixpoint known =
    let added =
      List.filter_map
        (fun (source : source) ->
          let name = source.signature.name in
          if List.mem name known || not (establishes_list known source) then
            None
          else Some name)
        sources
    in
    if added = [] then known else fixpoint (added @ known)
  in
  fixpoint []

let of_json json =
  check_unique_keys json;
  let root = fields_of_json json in
  check_keys
    ~expected:
      [ "source"; "types"; "constants"; "bindings"; "reviewed"; "functions" ]
    root;
  let pin = fields_of_json (field "source" root) in
  check_keys
    ~expected:[ "revision"; "fork"; "preset"; "file"; "sha256"; "span_units" ]
    pin;
  List.iter
    (fun (key, expected) ->
      if string_of_json (field key pin) <> expected then
        invalid ("Unsupported source " ^ key))
    [
      ("revision", "f96d3e7acf35125295d234da4b0c67591fdef49c");
      ("fork", "capella");
      ("preset", "mainnet");
      ("span_units", "line-1-byte-column-0-end-exclusive");
    ];
  ignore (sha256_of_json "Invalid source SHA256" (field "sha256" pin));
  let file = string_of_json (field "file" pin) in
  let types =
    List.map python_type_of_json (fields_of_json (field "types" root))
  in
  let check_type = check_type ~types in
  List.iter (fun (_, typ) -> check_type_references ~check:check_type typ) types;
  let constants =
    List.map
      (fun (name, json) ->
        let fields = fields_of_json json in
        check_keys ~expected:[ "type"; "value" ] fields;
        let typ = string_of_json (field "type" fields) in
        let value =
          match field "value" fields with
          | `List values -> SequenceConstant (List.map natural_of_json values)
          | value -> IntegerConstant (integer_of_json value)
        in
        (identifier_of_json (`String name), (typ, value)))
      (fields_of_json (field "constants" root))
  in
  List.iter
    (fun (_, (typ, value)) ->
      check_type typ;
      match value with
      | IntegerConstant _ -> ()
      | SequenceConstant values -> check_sequence_constant ~types typ values)
    constants;
  let bindings = identifiers_of_json (field "bindings" root) in
  check_bindings bindings;
  let reviewed = fields_of_json (field "reviewed" root) in
  check_keys
    ~expected:[ "state_reads"; "constructors"; "fresh_results" ]
    reviewed;
  let state_reads =
    List.map
      (fun (name, value) ->
        ( identifier_of_json (`String name),
          List.sort_uniq String.compare
            (List.map
               (fun item -> identifier_of_json item)
               (list_of_json value)) ))
      (fields_of_json (field "state_reads" reviewed))
  in
  let constructors = identifiers_of_json (field "constructors" reviewed) in
  List.iter
    (fun name ->
      match List.assoc_opt name types with
      | Some { descriptor = Record _; _ } -> ()
      | _ -> invalid ("Constructor without a record type: " ^ name))
    constructors;
  let fresh_results = identifiers_of_json (field "fresh_results" reviewed) in
  let functions =
    List.map function_fields_of_json (list_of_json (field "functions" root))
  in
  let signatures =
    List.map (signature_of_fields ~types ~fresh_results) functions
  in
  let names =
    List.map (fun (signature : signature) -> signature.name) signatures
  in
  check_distinct ~message:"Duplicate function" names;
  check_distinct ~message:"Generated relation names must be distinct"
    (List.filter_map
       (fun (signature : signature) -> signature.relation)
       signatures);
  List.iter
    (fun name ->
      if not (List.mem name names) then
        invalid ("Fresh result for an unknown function: " ^ name))
    fresh_results;
  let casts =
    List.filter_map
      (fun (name, typ) ->
        match typ.descriptor with Uint _ -> Some name | _ -> None)
      types
  in
  let roles =
    [ constructors; bindings; casts; names; [ Names.set_or_append_list ] ]
  in
  check_one_role roles;
  let sources =
    List.combine signatures functions
    |> List.filter_map (fun (signature, fields) ->
           match field "body" fields with
           | `Null -> None
           | body ->
               let at = location_of_json file (field "span" fields) in
               let body = statements_of_json file body in
               Syntax.iter_statements_preorder body
                 ~f:(fun (statement : Syntax.statement) ->
                   match statement.it with
                   | Syntax.LocalHelper { helper; _ }
                     when List.exists (List.mem helper) roles ->
                       Error.reject ~at:statement.at (two_roles_message helper)
                   | _ -> ());
               let locals, uses =
                 locals_and_uses ~bindings ~at signature body
               in
               Some
                 {
                   signature;
                   body;
                   at;
                   namespace =
                     { locals; uses; constructors; calls = signatures };
                   types;
                   constants;
                   state_reads;
                 })
    |> List.sort (fun (left : source) (right : source) ->
           String.compare left.signature.name right.signature.name)
  in
  { types; signatures; sources; list_results = infer_list_results sources }

let load filename =
  let reject reason =
    invalid
      (Printf.sprintf "%s %s. Expected a module document from python -m export."
         filename reason)
  in
  match Yojson.Safe.from_file filename with
  | json -> (
      try of_json json
      with Error.Rejected (Common.Location.Unknown, message) ->
        reject ("is not a module document: " ^ message))
  | exception Sys_error _ -> reject "cannot be read"
  | exception Yojson.Json_error _ -> reject "is not JSON"

let types (pyspec : t) = pyspec.types
let signatures (pyspec : t) = pyspec.signatures
let sources (pyspec : t) = pyspec.sources
let list_results (pyspec : t) = pyspec.list_results

let role_of_name (source : source) name =
  let namespace = source.namespace in
  if List.mem name namespace.locals then Some Local
  else if name = Names.set_or_append_list then Some SetOrAppendList
  else if List.mem name namespace.constructors then Some Constructor
  else if List.mem name namespace.uses then Some LibraryBinding
  else
    match List.assoc_opt name source.types with
    | Some { descriptor = Uint _; _ } -> Some Cast
    | _ ->
        List.find_opt
          (fun (signature : signature) -> signature.name = name)
          namespace.calls
        |> Option.map (fun signature -> Function signature)
