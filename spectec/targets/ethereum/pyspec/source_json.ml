open Common.Source
open Source
open Syntax

let invalid message = Error.reject ~at:no_region message
let string = function `String s -> s | _ -> invalid "Expected JSON string"
let list = function `List xs -> xs | _ -> invalid "Expected JSON array"
let object_ = function `Assoc xs -> xs | _ -> invalid "Expected JSON object"

let field name fields =
  match List.assoc_opt name fields with
  | Some x -> x
  | None -> invalid ("Missing field: " ^ name)

let keys expected fields =
  if
    List.sort String.compare (List.map fst fields)
    <> List.sort String.compare expected
  then invalid ("Expected fields: " ^ String.concat ", " expected)

let distinct message names =
  if List.length names <> List.length (List.sort_uniq String.compare names) then
    invalid message

let lowercase_hex =
  String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)

let source_hash message json =
  let hash = string json in
  if String.length hash <> 64 || not (lowercase_hex hash) then invalid message;
  hash

let rec unique = function
  | `Assoc fields ->
      let names = List.map fst fields in
      distinct "Duplicate JSON object key" names;
      List.iter (fun (_, value) -> unique value) fields
  | `List values -> List.iter unique values
  | _ -> ()

let identifier json =
  let name = string json in
  let letter c = ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || c = '_' in
  if
    name = ""
    || (not (letter name.[0]))
    || not (String.for_all (fun c -> letter c || ('0' <= c && c <= '9')) name)
  then invalid "Invalid source identifier";
  name

let integer json =
  let text = string json in
  let digits =
    if String.starts_with ~prefix:"-" text then
      String.sub text 1 (String.length text - 1)
    else text
  in
  if digits = "" || not (String.for_all (fun c -> '0' <= c && c <= '9') digits)
  then invalid "Expected decimal integer string";
  Bigint.of_string text

let natural json =
  let n = integer json in
  if Bigint.compare n Bigint.zero < 0 then
    invalid "Expected nonnegative integer"
  else n

let position file = function
  | `List [ `Int line; `Int column ] when line >= 1 && column >= 0 ->
      { file; line; column }
  | _ -> invalid "Expected [positive line, nonnegative byte column]"

let span file = function
  | `Null -> no_region
  | json ->
      let fields = object_ json in
      keys [ "start"; "end" ] fields;
      let left = position file (field "start" fields)
      and right = position file (field "end" fields) in
      if (right.line, right.column) < (left.line, left.column) then
        invalid "Reversed source span";
      { left; right }

let boolean = function `Bool x -> x | _ -> invalid "Expected JSON boolean"
let optional f = function `Null -> None | x -> Some (f x)
let strings json = List.map identifier (list json)

let target names tuple =
  match (names, boolean tuple) with
  | _, true -> Unpacked names
  | [ name ], false -> Single name
  | _, false -> invalid "A loop target without a tuple needs one name"

let operator operators json =
  let op = string json in
  match List.assoc_opt op operators with
  | Some op -> op
  | None -> invalid ("Unsupported operator: " ^ op)

let arithmetic =
  operator
    (List.map
       (fun op -> (string_of_binop op, op))
       [ Add; Sub; Mult; Mod; FloorDiv; Pow; BitAnd; BitOr; BitXor; RShift ])

let comparison =
  operator
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

let rec expression file json =
  let fields = object_ json in
  let at = span file (field "span" fields) in
  let get name = field name fields in
  let check names = keys ("kind" :: "span" :: names) fields in
  let expr name = expression file (get name) in
  let exprs name = List.map (expression file) (list (get name)) in
  let it =
    match string (get "kind") with
    | "name" ->
        check [ "id" ];
        Name (identifier (get "id"))
    | "integer" ->
        check [ "value" ];
        Int (integer (get "value"))
    | "bytes_literal" ->
        check [ "value" ];
        let value = string (get "value") in
        if String.length value mod 2 <> 0 || not (lowercase_hex value) then
          invalid
            "Byte literals require an even number of lowercase hexadecimal \
             digits";
        BytesLiteral value
    | "boolean" ->
        check [ "value" ];
        Bool (boolean (get "value"))
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
        Lambda (identifier (get "parameter"), expr "body")
    | "attribute" ->
        check [ "value"; "field" ];
        Attribute (expr "value", identifier (get "field"))
    | "subscript" ->
        check [ "value"; "index" ];
        Index (expr "value", expr "index")
    | "slice" ->
        check [ "lower"; "upper"; "step" ];
        Slice
          ( optional (expression file) (get "lower"),
            optional (expression file) (get "upper"),
            optional (expression file) (get "step") )
    | "binary" ->
        check [ "operator"; "left"; "right" ];
        Binary (arithmetic (get "operator"), expr "left", expr "right")
    | "boolop" ->
        check [ "operator"; "values" ];
        let op = operator [ ("And", And); ("Or", Or) ] (get "operator") in
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
        let ops = List.map comparison (list (get "operators"))
        and rights = exprs "rights" in
        if ops = [] || List.length ops <> List.length rights then
          invalid "Comparison arity";
        Compare (expr "left", List.combine ops rights)
    | "conditional" ->
        check [ "test"; "body"; "orelse" ];
        Conditional (expr "test", expr "body", expr "orelse")
    | "method" ->
        check [ "value"; "method"; "args" ];
        let method_ = identifier (get "method") in
        if
          not
            (List.mem method_
               [
                 "append";
                 "count";
                 "index";
                 "intersection";
                 "verify_and_notify_new_payload";
               ])
        then invalid "Unreviewed sequence method";
        Method (expr "value", method_, exprs "args")
    | "primitive" ->
        check [ "name"; "args" ];
        let primitive =
          match string (get "name") with
          | "bls_key_validate" -> BlsKeyValidate
          | "bls_aggregate_pubkeys" -> BlsAggregatePubkeys
          | "bls_verify" -> BlsVerify
          | "bls_fast_aggregate_verify" -> BlsFastAggregateVerify
          | "bls_g1_decode" -> BlsG1Decode
          | "bls_g1_encode" -> BlsG1Encode
          | "bls_g1_add" -> BlsG1Add
          | "bls_g1_neg" -> BlsG1Neg
          | "int_from_bytes" -> IntFromBytes
          | _ -> invalid "Unreviewed primitive"
        in
        Primitive (primitive, exprs "args")
    | "call" ->
        check [ "name"; "args"; "keywords" ];
        let keywords =
          List.map
            (fun json ->
              let fields = object_ json in
              keys [ "name"; "value" ] fields;
              ( identifier (field "name" fields),
                expression file (field "value" fields) ))
            (list (get "keywords"))
        in
        Call (identifier (get "name"), exprs "args", keywords)
    | ("comprehension" | "generator") as kind ->
        check [ "element"; "targets"; "tuple_target"; "iterable"; "filters" ];
        let element = expr "element" in
        let target = target (strings (get "targets")) (get "tuple_target") in
        let iterable = expr "iterable" and filters = exprs "filters" in
        if kind = "generator" then Generator (element, target, iterable, filters)
        else Comprehension (element, target, iterable, filters)
    | name -> invalid ("Unsupported expression: " ^ name)
  in
  it $ at

let rec statements file json =
  List.map
    (fun json ->
      let fields = object_ json in
      let get name = field name fields in
      let check names = keys ("kind" :: "span" :: names) fields in
      let expr name = expression file (get name) in
      let it =
        match string (get "kind") with
        | "assign" ->
            check [ "target"; "value" ];
            Assign (expr "target", expr "value")
        | "annotated_assign" ->
            check [ "target"; "annotation"; "value" ];
            AnnotatedAssign
              (expr "target", identifier (get "annotation"), expr "value")
        | "aug_assign" ->
            check [ "operator"; "target"; "value" ];
            AugAssign (arithmetic (get "operator"), expr "target", expr "value")
        | "break" ->
            check [];
            Break
        | "local_helper" ->
            check [ "name"; "elements"; "callable"; "element"; "captured" ];
            let names =
              List.map
                (fun name -> identifier (get name))
                [ "name"; "elements"; "callable"; "element"; "captured" ]
            in
            if List.length (List.sort_uniq String.compare names) <> 5 then
              invalid "Local helper names must be distinct";
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
            Return (optional (expression file) (get "value"))
        | "if" ->
            check [ "test"; "body"; "orelse" ];
            If
              ( expr "test",
                statements file (get "body"),
                statements file (get "orelse") )
        | "for" ->
            check [ "targets"; "tuple_target"; "iterable"; "body" ];
            For
              ( target (strings (get "targets")) (get "tuple_target"),
                expr "iterable",
                statements file (get "body") )
        | "while" ->
            check [ "test"; "body" ];
            While (expr "test", statements file (get "body"))
        | "assert" ->
            check [ "test" ];
            Assert (expr "test")
        | "expression" ->
            check [ "value" ];
            Expression (expr "value")
        | name -> invalid ("Unsupported statement: " ^ name)
      in
      it $ span file (get "span"))
    (list json)

let bytes_descriptor fields =
  let length = optional natural (field "length" fields) in
  let limit = optional natural (field "limit" fields) in
  let unbounded = boolean (field "unbounded" fields) in
  (* A length and a limit cannot both be present. Absence of both is
     ambiguous between a malformed document and a deliberately unbounded
     plain byte string, so the exporter must mark the latter
     explicitly. The decoder does not infer it. *)
  (match (length, limit, unbounded) with
  | Some _, None, false | None, Some _, false | None, None, true -> ()
  | _ ->
      invalid "Bytes require exactly one length or limit, or explicit unbounded");
  Bytes { length; limit }

let uint_descriptor = function
  | `Int bits when bits > 0 -> Uint bits
  | _ -> invalid "Invalid uint width"

let sequence_descriptor fields =
  Sequence
    {
      element = string (field "element" fields);
      length = optional natural (field "length" fields);
      limit = optional natural (field "limit" fields);
      bitvector = boolean (field "bitvector" fields);
    }

let type_ json =
  let fields = object_ json in
  let get name = field name fields in
  let check names = keys ("kind" :: "target" :: names) fields in
  let descriptor =
    match string (get "kind") with
    | "uint" ->
        check [ "bits" ];
        uint_descriptor (get "bits")
    | "integer" ->
        check [];
        Integer
    | "boolean" ->
        check [];
        Boolean
    | "bytes" ->
        check [ "length"; "limit"; "unbounded" ];
        bytes_descriptor fields
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
             (fun (name, typ) -> (identifier (`String name), string typ))
             (object_ (get "fields")))
    | "tuple" ->
        check [ "elements" ];
        Product (List.map string (list (get "elements")))
    | "set" ->
        check [ "element" ];
        Set (string (get "element"))
    | "sequence" ->
        check [ "element"; "length"; "limit"; "bitvector" ];
        sequence_descriptor fields
    | name -> invalid ("Unsupported type descriptor: " ^ name)
  in
  { descriptor; target = optional string (get "target") }

let validate_type_references check (typ : typ) =
  match typ.descriptor with
  | Product elements -> List.iter check elements
  | Record fields -> List.iter (fun (_, name) -> check name) fields
  | Sequence { element; _ } | Set element -> check element
  | _ -> ()

let presentation_arguments names optional_parameters interface =
  keys
    [
      "arguments";
      "parameter_types";
      "result_type";
      "relation";
      "notation";
      "declaration";
    ]
    interface;
  let arguments =
    List.map
      (fun (name, value) -> (identifier (`String name), identifier value))
      (object_ (field "arguments" interface))
  in
  keys names arguments;
  let arguments =
    List.map (fun name -> (name, List.assoc name arguments)) names
  in
  distinct "Duplicate presentation argument" (List.map snd arguments);
  let parameter_types = object_ (field "parameter_types" interface) in
  keys names parameter_types;
  (* The presentation type carries the option iteration exactly for the
     parameters the source reports as optional, so the declaration and the
     generated clause heads cannot disagree about presence. *)
  List.iter
    (fun (name, value) ->
      if
        String.ends_with ~suffix:"?" (string value)
        <> List.mem name optional_parameters
      then invalid "Optional parameter and presentation type disagree")
    parameter_types;
  ignore (string (field "result_type" interface));
  ignore (optional string (field "notation" interface));
  arguments

let signature_parameter json =
  let fields = object_ json in
  if List.mem_assoc "default" fields then
    keys [ "name"; "type"; "optional"; "default" ] fields
  else keys [ "name"; "type"; "optional" ] fields;
  let name = identifier (field "name" fields) in
  let typ = string (field "type" fields) in
  let flag = boolean (field "optional" fields) in
  let default =
    match List.assoc_opt "default" fields with
    | None -> None
    | Some value ->
        (* A None default already widens the type, so the two kinds of
           default cannot describe the same parameter. *)
        if flag then invalid "Optional parameter with a literal default";
        if typ <> "bool" then
          invalid "Literal default on a non-boolean parameter";
        Some (boolean value)
  in
  (name, typ, flag, default)

let signature fields =
  let get name = field name fields in
  let parameters = List.map signature_parameter (list (get "parameters")) in
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
  let names = List.map fst parameters in
  distinct "Duplicate parameter name" names;
  let interface = object_ (get "interface") in
  let arguments = presentation_arguments names optional_parameters interface in
  {
    name = identifier (get "name");
    parameters;
    optional = optional_parameters;
    defaults = literal_defaults;
    returns = optional string (get "returns");
    effect =
      (match optional identifier (get "effect") with
      | None -> Pure
      | Some "state" -> MutatesState
      | Some _ -> invalid "Invalid reviewed effect/signature contract");
    arguments;
    declaration = string (field "declaration" interface);
    relation = optional identifier (field "relation" interface);
    fresh_result = boolean (get "fresh_result");
  }

let validate_signature check (signature : signature) =
  List.iter (fun (_, name) -> check name) signature.parameters;
  Option.iter check signature.returns;
  match
    ( signature.effect,
      signature.returns,
      signature.relation,
      signature.parameters )
  with
  | Pure, Some _, None, _ :: _ -> ()
  | MutatesState, None, Some _, ("state", "BeaconState") :: _ -> ()
  | _ -> invalid "Invalid reviewed effect/signature contract"

let decode json =
  unique json;
  let root = object_ json in
  keys
    [
      "options";
      "source";
      "types";
      "constants";
      "casts";
      "state_reads";
      "calls";
      "builtins";
      "constructors";
      "function";
      "sequence_helpers";
    ]
    root;
  let options = object_ (field "options" root) in
  keys [ "all_expansion_limit" ] options;
  let all_expansion_limit =
    match field "all_expansion_limit" options with
    | `Int n when n >= 0 -> n
    | _ -> invalid "Invalid expansion limit"
  in
  let source = object_ (field "source" root) in
  keys [ "revision"; "fork"; "preset"; "file"; "sha256"; "span_units" ] source;
  List.iter
    (fun (key, expected) ->
      if string (field key source) <> expected then
        invalid ("Unsupported source " ^ key))
    [
      ("revision", "f96d3e7acf35125295d234da4b0c67591fdef49c");
      ("fork", "capella");
      ("preset", "mainnet");
      ("span_units", "line-1-byte-column-0-end-exclusive");
    ];
  ignore (source_hash "Invalid source SHA256" (field "sha256" source));
  let file = string (field "file" source) in
  let types =
    List.map
      (fun (name, value) -> (name, type_ value))
      (object_ (field "types" root))
  in
  let check name =
    if not (List.mem_assoc name types) then invalid ("Unresolved type: " ^ name)
  in
  List.iter (fun (_, typ) -> validate_type_references check typ) types;
  let constants =
    List.map
      (fun (name, json) ->
        let fields = object_ json in
        keys [ "type"; "value" ] fields;
        let typ = string (field "type" fields) in
        check typ;
        let value =
          match field "value" fields with
          | `List values ->
              let element =
                match (List.assoc typ types).descriptor with
                | Sequence
                    { element; length = None; limit = None; bitvector = false }
                  ->
                    element
                | _ ->
                    invalid "Sequence constant requires a scalar sequence type"
              in
              if (List.assoc element types).descriptor <> Uint 64 then
                invalid "Sequence constants require uint64 elements";
              let values = List.map natural values in
              if
                values = []
                || List.exists
                     (fun value ->
                       Bigint.compare value
                         (Bigint.of_string "18446744073709551615")
                       > 0)
                     values
              then invalid "Invalid sequence constant values";
              SequenceConstant values
          | value -> IntegerConstant (integer value)
        in
        (identifier (`String name), (typ, value)))
      (object_ (field "constants" root))
  in
  let casts =
    List.map
      (fun (name, value) ->
        let typ = string value in
        check typ;
        (identifier (`String name), typ))
      (object_ (field "casts" root))
  in
  let state_reads =
    List.map
      (fun (name, value) ->
        ( identifier (`String name),
          List.sort_uniq String.compare
            (List.map (fun item -> identifier item) (list value)) ))
      (object_ (field "state_reads" root))
  in
  let calls =
    List.map
      (fun json ->
        let fields = object_ json in
        keys
          [
            "name";
            "parameters";
            "returns";
            "effect";
            "interface";
            "fresh_result";
          ]
          fields;
        signature fields)
      (list (field "calls" root))
  in
  let sequence_helpers =
    List.map
      (fun json ->
        let fields = object_ json in
        keys [ "name"; "parameters"; "source"; "span"; "body" ] fields;
        let name = identifier (field "name" fields) in
        let parameters = strings (field "parameters" fields) in
        if
          name <> "set_or_append_list"
          || parameters <> [ "list"; "index"; "value" ]
        then invalid "Unreviewed generic sequence helper";
        let source = object_ (field "source" fields) in
        keys [ "file"; "sha256" ] source;
        let file = string (field "file" source) in
        ignore
          (source_hash "Invalid helper source SHA256" (field "sha256" source));
        {
          name;
          parameters;
          body = statements file (field "body" fields);
          at = span file (field "span" fields);
        })
      (list (field "sequence_helpers" root))
  in
  distinct "Duplicate generic sequence helper"
    (List.map (fun (h : sequence_helper) -> h.name) sequence_helpers);
  let func = object_ (field "function" root) in
  keys
    [
      "name";
      "parameters";
      "returns";
      "effect";
      "interface";
      "fresh_result";
      "body";
      "locals";
      "span";
    ]
    func;
  let signature = signature func in
  List.iter (validate_signature check) (signature :: calls);
  let names = List.map (fun (s : signature) -> s.name) calls in
  distinct "Duplicate call signature" names;
  if not (List.exists (fun s -> s = signature) calls) then
    invalid "Selected function does not match reviewed call signature";
  let builtins = strings (field "builtins" root) in
  if
    List.exists
      (fun name -> not (List.mem name Python_builtins.admitted))
      builtins
  then invalid "Unreviewed builtin";
  let constructors = strings (field "constructors" root) in
  List.iter
    (fun name ->
      match List.assoc_opt name types with
      | Some { descriptor = Record _; _ } -> ()
      | _ -> invalid ("Constructor without a record type: " ^ name))
    constructors;
  {
    all_expansion_limit;
    types;
    constants;
    casts;
    state_reads;
    calls;
    sequence_helpers;
    signature;
    builtins;
    constructors;
    locals = strings (field "locals" func);
    body = statements file (field "body" func);
    at = span file (field "span" func);
  }

let load filename = decode (Yojson.Safe.from_file filename)

let load_many path =
  if Sys.is_directory path then
    let files =
      Sys.readdir path |> Array.to_list
      |> List.filter (fun name -> Filename.check_suffix name ".json")
      |> List.sort String.compare
    in
    List.map (fun name -> load (Filename.concat path name)) files
  else [ load path ]
