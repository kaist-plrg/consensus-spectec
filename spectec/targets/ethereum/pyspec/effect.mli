(** Whether the receiver names a list the function owns, which a read-only
    function may still extend. *)
val is_owned_list : branch:Branch.t -> Syntax.expr -> bool

(** Translates a statement-level call or append for its effect. *)
val call : ctx:Ctx.t -> Syntax.expr -> branch:Branch.t -> Branch.t list
