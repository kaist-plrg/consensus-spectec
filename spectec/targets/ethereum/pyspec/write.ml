open Common.Source
open Lang.El
open Store
open Kind
open Operand
open Ctx
open Branch
module S = Source
module B = Python_builtins

let path_of_location at location =
  List.fold_left
    (fun selection -> function
      | Field field -> DotP (selection, atom ~at field) $ at
      | Element index -> IdxP (selection, unarith index.exp) $ at)
    (RootP $ at) location

let bit_of_number ctx at value =
  if
    Kind.is_integer ~types:ctx.source.types ~at value.kind
    || Kind.bits ~types:ctx.source.types ~at value.kind <> None
  then comparison ~at ~op:`NeOp value.exp (nat ~at 0)
  else Error.reject ~at "Unsupported bit assignment value"

let convert ~ctx ~at ~kind ~branch value =
  match kind with
  | Named name when Kind.bits ~types:ctx.source.types ~at kind <> None ->
      Numeric_ops.cast ~ctx ~at ~name ~branch value
  | _ ->
      if
        value.kind <> kind
        && (not
              (Kind.is_boolean ~types:ctx.source.types ~at value.kind
              && Kind.is_boolean ~types:ctx.source.types ~at kind))
        && not
             (Kind.is_byte_valued ~types:ctx.source.types ~at value.kind
             && Kind.byte_width ~types:ctx.source.types ~at value.kind <> None
             && Kind.byte_width ~types:ctx.source.types ~at value.kind
                = Kind.byte_width ~types:ctx.source.types ~at kind)
      then Error.reject ~at "Assignment conversion is unsupported";
      (branch, value)

type owner =
  | StateWrite of Operand.t Store.location
  | ReferenceWrite of Operand.t Store.reference

type target = { container : Operand.t; selection : Lang.El.path; owner : owner }

let apply ~ctx ~at target ~replacement ~branch =
  let update container selection replacement branch =
    let exp =
      match selection.it with
      | RootP -> replacement
      | _ -> UpdE (container.exp, selection, replacement) $ at
    in
    bind ~ctx ~at branch ~term:{ container with exp }
  in
  let branch, value =
    update target.container target.selection replacement branch
  in
  match target.owner with
  | StateWrite location -> write_state ~location ~value branch
  | ReferenceWrite reference -> (
      let branch = update_aliases ~identity:reference.identity ~value branch in
      match reference.location with
      | None -> branch
      | Some location ->
          let branch, location, value =
            match (reference.iterator_parent, location) with
            | Some parent_name, [ Field field; Element index ] ->
                let parent =
                  Error.find_or_reject ~at ~name:parent_name
                    (Store.bindings branch.storage)
                in
                let branch, parent =
                  update parent
                    (IdxP (RootP $ at, unarith index.exp) $ at)
                    value.exp branch
                in
                ( replace_local ~name:parent_name ~value:parent branch,
                  [ Field field ],
                  parent )
            | None, _ -> (branch, location, value)
            | _ -> Error.reject ~at "Unsupported iterator parent location"
          in
          let state =
            Error.find_or_reject ~at ~name:"state"
              (Store.bindings branch.storage)
          in
          let branch, state =
            update state (path_of_location at location) value.exp branch
          in
          write_state ~identity:reference.identity ~location ~value:state branch
      )

let resolve ctx (node : Syntax.expr) value branch =
  let at = node.at in
  match node.it with
  | Syntax.Attribute ({ it = Syntax.Name name; _ }, _)
  | Syntax.Index ({ it = Syntax.Name name; _ }, _)
    when name <> "state" ->
      let reference =
        match List.assoc_opt name (Store.references branch.storage) with
        | Some reference when reference.valid -> reference
        | Some _ ->
            Error.reject ~at
              "Writable reference invalidated by an overlapping update or call"
        | None -> Error.reject ~at "Writable reference has no tracked storage"
      in
      if reference.location <> None && ctx.source.signature.effect = S.Pure then
        Error.reject ~at "State mutation in a read-only helper";
      let record =
        Error.find_or_reject ~at ~name (Store.bindings branch.storage)
      in
      let branch, suffix, kind, value =
        match node.it with
        | Syntax.Attribute (_, field) ->
            ( branch,
              DotP (RootP $ at, atom ~at field) $ at,
              Named
                (Error.find_or_reject ~at ~name:field
                   (Kind.fields ~types:ctx.source.types ~at record.kind)),
              value )
        | Syntax.Index (_, { it = Syntax.Slice _; _ }) ->
            Error.reject ~at "Slice mutation through a reference is unsupported"
        | Syntax.Index (_, index) ->
            let branch, index =
              match Expr.translate ~ctx index ~branch with
              | [ result ] -> result
              | _ -> Error.reject ~at "Branching assignment index"
            in
            let branch, index =
              Sequence_ops.normalize_index ~ctx ~at ~branch record ~index
            in
            let kind, _, bitvector =
              Kind.sequence ~types:ctx.source.types ~at record.kind
            in
            if
              reference.location = None
              && Kind.is_named_container_or_set ~types:ctx.source.types ~at kind
            then
              Error.reject ~at
                "Replacing a local record-list element requires an alias \
                 contract";
            let branch, _ =
              Sequence_ops.read_index ~ctx ~at ~branch record ~index
            in
            let value =
              if
                bitvector
                && not (Kind.is_boolean ~types:ctx.source.types ~at value.kind)
              then { exp = bit_of_number ctx at value; kind }
              else value
            in
            (branch, IdxP (RootP $ at, unarith index.exp) $ at, kind, value)
        | _ -> assert false
      in
      let branch, value = convert ~ctx ~at ~kind ~branch value in
      ( branch,
        {
          container = record;
          selection = suffix;
          owner = ReferenceWrite reference;
        },
        value.exp )
  | Syntax.Attribute
      ( { it = Syntax.Attribute ({ it = Syntax.Name "state"; _ }, field); _ },
        child ) ->
      if ctx.source.signature.effect = S.Pure then
        Error.reject ~at "Nested state mutation in a read-only helper";
      let state =
        Error.find_or_reject ~at ~name:"state" (Store.bindings branch.storage)
      in
      let record_kind =
        Named
          (Error.find_or_reject ~at ~name:field
             (Kind.fields ~types:ctx.source.types ~at state.kind))
      in
      let expected =
        Named
          (Error.find_or_reject ~at ~name:child
             (Kind.fields ~types:ctx.source.types ~at record_kind))
      in
      let branch, value = convert ~ctx ~at ~kind:expected ~branch value in
      let location = [ Field field; Field child ] in
      ( branch,
        {
          container = state;
          selection = path_of_location at location;
          owner = StateWrite location;
        },
        value.exp )
  | _ ->
      if ctx.source.signature.effect = S.Pure then
        Error.reject ~at "State mutation in a read-only helper";
      let state =
        Error.find_or_reject ~at ~name:"state" (Store.bindings branch.storage)
      in
      let field, index =
        match node.it with
        | Syntax.Attribute ({ it = Syntax.Name "state"; _ }, field) ->
            (field, None)
        | Syntax.Index
            ( {
                it = Syntax.Attribute ({ it = Syntax.Name "state"; _ }, field);
                _;
              },
              index ) ->
            (field, Some index)
        | _ -> Error.reject ~at "Mutation through an alias or nested record"
      in
      let kind =
        Named
          (Error.find_or_reject ~at ~name:field
             (Kind.fields ~types:ctx.source.types ~at state.kind))
      in
      let sequence_value =
        { exp = DotE (state.exp, atom ~at field) $ at; kind }
      in
      let root = DotP (RootP $ at, atom ~at field) $ at in
      let branch, selection, replacement =
        match index with
        | None ->
            let branch, value = convert ~ctx ~at ~kind ~branch value in
            (branch, root, value.exp)
        | Some { it = Syntax.Slice (lower, upper, step); _ } ->
            let _, length, bitvector =
              Kind.sequence ~types:ctx.source.types ~at kind
            in
            if not bitvector then
              Error.reject ~at "Slice assignment requires a fixed SSZ bitvector";
            let branch = Sequence_ops.shape ~ctx ~at ~branch sequence_value in
            let branch, start, finish =
              Expr.slice_bounds ~ctx ~at ~branch (Option.get length) ~lower
                ~upper ~step
            in
            let _, count, _ =
              Kind.sequence ~types:ctx.source.types ~at value.kind
            in
            let count =
              match count with
              | Some n -> n
              | None ->
                  Error.reject ~at "Operation requires a fixed boolean sequence"
            in
            let branch = Sequence_ops.shape ~ctx ~at ~branch value in
            let branch, value = bind ~ctx ~at branch ~term:value in
            let size =
              arithmetic ~at ~op:`AddOp (number ~at start) (LenE value.exp $ at)
            in
            let branch =
              guard ~at
                ~exp:(comparison ~at ~op:`EqOp size (number ~at finish))
                branch
            in
            if Bigint.equal count Bigint.zero then
              (branch, RootP $ at, state.exp)
            else
              let branch =
                guard ~at
                  ~exp:
                    (comparison ~at ~op:`LeOp size
                       (LenE sequence_value.exp $ at))
                  branch
              in
              ( branch,
                SliceP (root, number ~at start, number ~at count) $ at,
                value.exp )
        | Some index ->
            let branch = Sequence_ops.shape ~ctx ~at ~branch sequence_value in
            let branch, index =
              match Expr.translate ~ctx index ~branch with
              | [ result ] -> result
              | _ -> Error.reject ~at "Branching assignment index"
            in
            let branch, index = Numeric_ops.to_natural ~ctx ~at ~branch index in
            let branch =
              guard ~at
                ~exp:
                  (comparison ~at ~op:`LtOp index.exp
                     (LenE sequence_value.exp $ at))
                branch
            in
            let element, _, bitvector =
              Kind.sequence ~types:ctx.source.types ~at kind
            in
            let value =
              if
                (not bitvector)
                || Kind.is_boolean ~types:ctx.source.types ~at value.kind
              then value
              else { exp = bit_of_number ctx at value; kind = element }
            in
            let branch, value = convert ~ctx ~at ~kind:element ~branch value in
            (branch, IdxP (root, unarith index.exp) $ at, value.exp)
      in
      ( branch,
        { container = state; selection; owner = StateWrite [ Field field ] },
        replacement )

let store ?copied ~ctx (node : Syntax.expr) ~value ~branch =
  let at = node.at in
  if
    Kind.set_element ~types:ctx.source.types ~at value.kind <> None
    && match node.it with Syntax.Name _ -> false | _ -> true
  then Error.reject ~at "Set ordering cannot escape into state";
  match node.it with
  | Syntax.Name name ->
      if name = "state" || value.kind = Named Spec_names.state_type then
        Error.reject ~at "Saving or rebinding the mutable root state";
      let location = origin branch ~value in
      let reference =
        Option.bind copied (fun name ->
            List.assoc_opt name (Store.references branch.storage))
      in
      let reference =
        match reference with
        | Some _ -> reference
        | None ->
            List.find_map
              (fun (name, reference) ->
                if
                  reference.location = None
                  && string_of_exp
                       (Error.find_or_reject ~at ~name
                          (Store.bindings branch.storage))
                         .exp
                     = string_of_exp value.exp
                then Some reference
                else None)
              (Store.references branch.storage)
      in
      let empty_record_list =
        match (value.kind, value.exp.it) with
        | Sequence (element, _), EpsE ->
            Kind.is_flat_record ~types:ctx.source.types ~at element
        | _ -> false
      in
      let branch, value = bind ~ctx ~at branch ~term:value in
      let reference =
        match (reference, location) with
        | Some reference, _ -> Some reference
        | None, Some location
          when Kind.is_named_container_or_set ~types:ctx.source.types ~at
                 value.kind ->
            Some (Store.state_view ~identity:(string_of_exp value.exp) location)
        | None, None -> (
            match value.kind with
            | Sequence (element, _)
              when Kind.is_copyable_scalar ~types:ctx.source.types ~at element
                   || empty_record_list ->
                Some (Store.owned (string_of_exp value.exp))
            | _ -> None)
        | _ -> None
      in
      {
        branch with
        storage = Store.bind_local ~name ~value ~reference branch.storage;
      }
  | _ ->
      let branch, target, replacement = resolve ctx node value branch in
      apply ~ctx ~at target ~replacement ~branch
