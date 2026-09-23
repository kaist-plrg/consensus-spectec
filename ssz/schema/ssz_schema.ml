exception Error of string

let fail fmt = Printf.ksprintf (fun msg -> raise (Error msg)) fmt
let guard f = try Ok (f ()) with Error msg -> Error msg

type t = (string * Ssz.typ) list

let int_of = function
  | `Int n when n >= 0 -> n
  | j -> fail "expected a count, got %s" (Yojson.Safe.to_string j)

let uint_of_name = function
  | "uint8" -> Some 1
  | "uint16" -> Some 2
  | "uint32" -> Some 4
  | "uint64" -> Some 8
  | "uint128" -> Some 16
  | "uint256" -> Some 32
  | _ -> None

(* [lookup] resolves a type name. *)
let rec parse lookup (j : Yojson.Safe.t) : Ssz.typ =
  let fields l =
    List.map
      (function
        | `List [ `String name; t ] -> (name, parse lookup t)
        | j -> fail "expected [name, type], got %s" (Yojson.Safe.to_string j))
      l
  in
  match j with
  | `String "boolean" -> Boolean
  | `String "progressive_bitlist" -> Progressive_bitlist
  | `String s -> (
      match uint_of_name s with Some n -> Uint n | None -> lookup s)
  | `Assoc [ ("vector", `List [ t; n ]) ] -> Vector (parse lookup t, int_of n)
  | `Assoc [ ("list", `List [ t; n ]) ] -> List (parse lookup t, int_of n)
  | `Assoc [ ("bitvector", n) ] -> Bitvector (int_of n)
  | `Assoc [ ("bitlist", n) ] -> Bitlist (int_of n)
  | `Assoc [ ("progressive_list", t) ] -> Progressive_list (parse lookup t)
  | `Assoc [ ("container", `List l) ] -> Container (fields l)
  | `Assoc [ ("progressive_container", `Assoc m) ] -> (
      match (List.assoc_opt "active_fields" m, List.assoc_opt "fields" m) with
      | Some (`List bits), Some (`List l) ->
          let active_fields =
            List.map
              (function
                | `Int 0 -> false
                | `Int 1 -> true
                | _ -> fail "active_fields must be 0 or 1")
              bits
          in
          let fields = fields l in
          if
            List.length (List.filter Fun.id active_fields) <> List.length fields
          then fail "active_fields set bits must match the field count";
          Progressive_container { active_fields; fields }
      | _ -> fail "progressive_container needs active_fields and fields")
  | `Assoc [ ("compatible_union", `List l) ] ->
      Compatible_union
        (List.map
           (function
             | `List [ `Int sel; t ] -> (sel, parse lookup t)
             | j ->
                 fail "expected [selector, type], got %s"
                   (Yojson.Safe.to_string j))
           l)
  | j -> fail "not a type expression: %s" (Yojson.Safe.to_string j)

let of_json j =
  guard (fun () ->
      let defs =
        match j with
        | `Assoc m -> (
            match List.assoc_opt "types" m with
            | Some (`Assoc d) -> d
            | _ -> fail "missing \"types\" object")
        | _ -> fail "schema must be an object"
      in
      let resolved = Hashtbl.create 64 in
      let rec lookup visiting name =
        match Hashtbl.find_opt resolved name with
        | Some t -> t
        | None -> (
            if List.mem name visiting then fail "cyclic type %s" name;
            match List.assoc_opt name defs with
            | None -> fail "unknown type %s" name
            | Some d ->
                let t = parse (lookup (name :: visiting)) d in
                Hashtbl.replace resolved name t;
                t)
      in
      List.map (fun (name, _) -> (name, lookup [] name)) defs)

let load path =
  try of_json (Yojson.Safe.from_file path)
  with Yojson.Json_error msg | Sys_error msg -> Error msg

let find t name = List.assoc_opt name t
let names t = List.map fst t

let typ_of_json t j =
  guard (fun () ->
      parse
        (fun name ->
          match find t name with
          | Some ty -> ty
          | None -> fail "unknown type %s" name)
        j)

(* Values *)

let le_of_decimal size s =
  let b = Bytes.make size '\000' in
  String.iter
    (fun c ->
      if c < '0' || c > '9' then fail "not a decimal number: %s" s;
      let carry = ref (Char.code c - Char.code '0') in
      for i = 0 to size - 1 do
        let v = (Char.code (Bytes.get b i) * 10) + !carry in
        Bytes.set b i (Char.chr (v land 0xff));
        carry := v lsr 8
      done;
      if !carry <> 0 then fail "%s does not fit in uint%d" s (size * 8))
    s;
  if s = "" then fail "empty number";
  Bytes.to_string b

let bytes_of_hex s =
  let n = String.length s in
  if n < 2 || String.sub s 0 2 <> "0x" || n mod 2 <> 0 then
    fail "not 0x-prefixed even-length hex: %s" s;
  String.init
    ((n - 2) / 2)
    (fun i -> Char.chr (int_of_string ("0x" ^ String.sub s (2 + (2 * i)) 2)))

let bit s i = Char.code s.[i / 8] land (1 lsl (i mod 8)) <> 0

let bits_of_bitvector n s =
  let b = bytes_of_hex s in
  if String.length b <> (n + 7) / 8 then
    fail "bitvector[%d] needs %d bytes, got %s" n ((n + 7) / 8) s;
  List.init (String.length b * 8) (bit b)
  |> List.iteri (fun i x ->
         if i >= n && x then fail "bitvector[%d] has bits set past its length" n);
  List.init n (bit b)

let bits_of_bitlist s =
  let b = bytes_of_hex s in
  let n = String.length b in
  if n = 0 || b.[n - 1] = '\000' then fail "bitlist without delimiter: %s" s;
  let last = Char.code b.[n - 1] in
  let rec top k = if last lsr (k + 1) = 0 then k else top (k + 1) in
  List.init (((n - 1) * 8) + top 0) (bit b)

let rec value_of (t : Ssz.typ) (j : Yojson.Safe.t) : Ssz.value =
  let seq elem l = Ssz.Seq (List.map (value_of elem) l) in
  match (t, j) with
  | Uint n, `Int i when i >= 0 -> Ssz.uint_of_int ~size:n i
  | Uint n, (`Intlit s | `String s) -> Uint (le_of_decimal n s)
  | Boolean, `Bool b -> Bool b
  | ( (Vector (Uint 1, _) | List (Uint 1, _) | Progressive_list (Uint 1)),
      `String s ) ->
      Bytes (bytes_of_hex s)
  | (Vector (elem, _) | List (elem, _) | Progressive_list elem), `List l ->
      seq elem l
  | Bitvector n, `String s -> Bits (bits_of_bitvector n s)
  | (Bitlist _ | Progressive_bitlist), `String s -> Bits (bits_of_bitlist s)
  | (Bitvector _ | Bitlist _ | Progressive_bitlist), `List l ->
      Bits
        (List.map (function `Bool b -> b | _ -> fail "expected booleans") l)
  | (Container fields | Progressive_container { fields; _ }), `Assoc m ->
      Fields
        (List.map
           (fun (name, ft) ->
             match List.assoc_opt name m with
             | Some v -> (
                 try value_of ft v with Error msg -> fail "%s: %s" name msg)
             | None -> fail "missing field %s" name)
           fields)
  | Compatible_union options, `Assoc m -> (
      match (List.assoc_opt "selector" m, List.assoc_opt "data" m) with
      | Some (`Int sel), Some data -> (
          match List.assoc_opt sel options with
          | Some opt -> Union (sel, value_of opt data)
          | None -> fail "selector %d is not an option" sel)
      | _ -> fail "union needs selector and data")
  | _ -> fail "JSON %s does not fit the type" (Yojson.Safe.to_string j)

let value_of_json t j = guard (fun () -> value_of t j)
