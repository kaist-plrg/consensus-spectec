open Lang.Xl
open Lang.Il
open Builtins
open Error

let ( let* ) = Result.bind

type point = Infinity | Point of Bigint.t * Bigint.t

let modulus =
  Bigint.of_string
    "4002409555221667393417789825735904156556882819939007885332058136124031650490837864442687629129015664037894272559787"

let power_two bits = Bigint.pow (Bigint.of_int 2) (Bigint.of_int bits)
let reduce value = Bigint.(((value % modulus) + modulus) % modulus)

let power base exponent =
  let rec square_and_multiply result base exponent =
    if Bigint.equal exponent Bigint.zero then result
    else
      let result =
        if Bigint.equal Bigint.(exponent % of_int 2) Bigint.zero then result
        else reduce Bigint.(result * base)
      in
      square_and_multiply result
        (reduce Bigint.(base * base))
        Bigint.(exponent / of_int 2)
  in
  square_and_multiply Bigint.one (reduce base) exponent

let decode ~at number =
  let number = Num.to_int number in
  let compression = power_two 383 in
  let infinity = power_two 382 in
  let sign_bit = power_two 381 in
  if Bigint.(number < compression || number >= power_two 384) then
    Error (runtime at "invalid compressed G1 point")
  else if Bigint.(number / infinity % of_int 2 = one) then
    (* The pinned Arkworks unchecked decoder ignores the remaining bits for
       an infinity encoding. Subgroup membership is not checked here. *)
    Ok Infinity
  else
    let x = Bigint.(number % sign_bit) in
    if Bigint.(x >= modulus) then
      Error (runtime at "G1 coordinate outside the base field")
    else
      let rhs = reduce Bigint.((x * x * x) + of_int 4) in
      let y = power rhs Bigint.((modulus + one) / of_int 4) in
      if not (Bigint.equal (reduce Bigint.(y * y)) rhs) then
        Error (runtime at "G1 point is not on the curve")
      else
        let negative = Bigint.(number / sign_bit % of_int 2 = one) in
        let y =
          if negative = Bigint.(y > modulus / of_int 2) then y
          else reduce Bigint.(zero - y)
        in
        Ok (Point (x, y))

let encode point =
  let number =
    match point with
    | Infinity -> Bigint.(power_two 383 + power_two 382)
    | Point (x, y) ->
        Bigint.(power_two 383 + x) |> fun value ->
        if Bigint.(y > modulus / of_int 2) then Bigint.(value + power_two 381)
        else value
  in
  Value.make_bytes ~num:number ~len:48

let add left right =
  match (left, right) with
  | Infinity, point | point, Infinity -> point
  | Point (x1, y1), Point (x2, y2) ->
      if
        Bigint.equal x1 x2 && Bigint.equal (reduce Bigint.(y1 + y2)) Bigint.zero
      then Infinity
      else
        let numerator, denominator =
          if Bigint.equal x1 x2 then
            (Bigint.(of_int 3 * x1 * x1), Bigint.(of_int 2 * y1))
          else (Bigint.(y2 - y1), Bigint.(x2 - x1))
        in
        let slope =
          reduce Bigint.(numerator * power denominator (modulus - of_int 2))
        in
        let x = reduce Bigint.((slope * slope) - x1 - x2) in
        let y = reduce Bigint.((slope * (x1 - x)) - y1) in
        Point (x, y)

let canonicalize ~at value =
  let* point = decode ~at value in
  Ok (encode point)

let negate ~at value =
  let* point = decode ~at value in
  Ok
    (encode
       (match point with
       | Infinity -> Infinity
       | Point (x, y) -> Point (x, reduce Bigint.(zero - y))))

let addition ~at left right =
  let* left = decode ~at left in
  let* right = decode ~at right in
  Ok (encode (add left right))

let builtins =
  [
    ("bls_g1_canonicalize", Define.T0.a1 Arg.num canonicalize);
    ("bls_g1_neg", Define.T0.a1 Arg.num negate);
    ("bls_g1_add", Define.T0.a2 Arg.num Arg.num addition);
  ]
