open Lang.Il

(* Function *)

type t = Builtin | Defined of tparam list * clause list

let to_string = function
  | Builtin -> "builtin function"
  | Defined (tparams, clauses) ->
      "def"
      ^ Print.string_of_tparams tparams
      ^ "\n"
      ^ String.concat "\n"
          (List.mapi
             (fun idx clause -> Print.string_of_clause idx clause)
             clauses)
