module Syntax = Syntax
module Source = Source
module Error = Error
module Source_json = Source_json
module Bundle = Bundle

module Assembly : sig
  (** The output of one translation and its insertion into a target spec.

      Assembly removes repeated shared definitions by their rendered text, then
      places declarations before bodies. Source entries and helpers are kept
      whatever their names, and different definitions of the same symbol stay
      distinct.

      [replace] finds the bundle's source symbols in the context, in separate
      function, relation and type namespaces. It rejects an auxiliary symbol
      that collides with the context, whatever its spelling, and reuses
      identical shared builtin and type declarations. Generated declarations go
      at the first replaced source declaration, and generated bodies go after
      the rest of the context. *)

  type t

  val definitions : t -> Lang.El.spec

  (** Replaces source entry symbols and rejects auxiliary symbol collisions.
      Identical shared builtin and type declarations may occur in the context.
  *)
  val replace : context:Lang.El.spec -> t -> Lang.El.spec

  (** Replaces the bundle's definitions into the context as [replace] does, then
      elaborates and structures the result. *)
  val compile :
    context:Lang.El.spec -> t -> (Lang.Il.spec * Lang.Sl.spec) Spectec.result
end

module Translate : sig
  (** Translates every function of the bundle. The assembly holds the generated
      definitions. *)
  val bundle : Bundle.t -> Assembly.t
end
