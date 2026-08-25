module type S = sig
  val builtins : (string * Builtins.Define.t) list
  val handler : (unit -> 'a) -> 'a
  val is_impure_func : string -> bool
  val is_impure_rel : string -> bool
  val state_version : int ref
end
