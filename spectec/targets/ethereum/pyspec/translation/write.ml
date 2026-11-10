open Common.Annotated
open Lang.El
open Store
open Value
open Branch

let path_of_location at location =
  List.fold_left
    (fun selection -> function
      | Field field -> DotP (selection, atom ~at field) $ at
      | Element index -> IdxP (selection, unarith index.exp) $ at)
    (RootP $ at) location

let bit_of_number ctx at value =
  if
    Value.is_integer ~types:(Ctx.types ctx) ~at value.kind
    || Value.bits ~types:(Ctx.types ctx) ~at value.kind <> None
  then comparison ~at ~op:`NeOp value.exp (nat ~at 0)
  else Error.reject ~at "Unsupported bit assignment value"

type owner = StateWrite of Store.location | ReferenceWrite of Store.reference

type destination = {
  container : Value.t;
  selection : Lang.El.path;
  owner : owner;
}

let apply ~ctx ~at destination ~replacement ~branch =
  let update container selection replacement branch =
    let exp =
      match selection.it with
      | RootP -> replacement
      | _ -> UpdE (container.exp, selection, replacement) $ at
    in
    bind ~ctx ~at branch ~term:{ container with exp }
  in
  let branch, value =
    update destination.container destination.selection replacement branch
  in
  match destination.owner with
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
            Error.find_or_reject ~at ~name:Names.state_parameter
              (Store.bindings branch.storage)
          in
          let branch, state =
            update state (path_of_location at location) value.exp branch
          in
          write_state ~identity:reference.identity ~location ~value:state branch
      )

let destination_of_expr ~ctx (node : Syntax.expr) ~value ~branch =
  let at = node.at in
  match node.it with
  | Syntax.Attribute ({ it = Syntax.Name name; _ }, _)
  | Syntax.Index ({ it = Syntax.Name name; _ }, _)
    when name <> Names.state_parameter ->
      let reference =
        match List.assoc_opt name (Store.references branch.storage) with
        | Some reference when reference.valid -> reference
        | Some _ ->
            Error.reject ~at
              "Writable reference invalidated by an overlapping update or call"
        | None -> Error.reject ~at "Writable reference has no tracked storage"
      in
      if
        reference.location <> None
        && (Ctx.source ctx).signature.effect = Typed.Pure
      then Error.reject ~at "State mutation in a read-only helper";
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
                   (Value.fields ~types:(Ctx.types ctx) ~at record.kind)),
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
            let { Value.element = kind; bitvector; _ } =
              Value.sequence ~types:(Ctx.types ctx) ~at record.kind
            in
            if
              reference.location = None
              && Value.is_named_container_or_set ~types:(Ctx.types ctx) ~at kind
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
                && not (Value.is_boolean ~types:(Ctx.types ctx) ~at value.kind)
              then { exp = bit_of_number ctx at value; kind }
              else value
            in
            (branch, IdxP (RootP $ at, unarith index.exp) $ at, kind, value)
        | _ -> assert false
      in
      let branch, value =
        match record.kind with
        | Named _ -> Ssz_ops.coerce ~ctx ~at ~kind ~branch value
        | _ ->
            if value.kind <> kind then
              Error.reject ~at
                "Python lists store a value unconverted, so it must have the \
                 list's element class";
            (branch, value)
      in
      ( branch,
        {
          container = record;
          selection = suffix;
          owner = ReferenceWrite reference;
        },
        value.exp )
  | Syntax.Attribute
      ({ it = Syntax.Attribute ({ it = Syntax.Name root; _ }, field); _ }, child)
    when root = Names.state_parameter ->
      if (Ctx.source ctx).signature.effect = Typed.Pure then
        Error.reject ~at "Nested state mutation in a read-only helper";
      let state =
        Error.find_or_reject ~at ~name:Names.state_parameter
          (Store.bindings branch.storage)
      in
      let record_kind =
        Named
          (Error.find_or_reject ~at ~name:field
             (Value.fields ~types:(Ctx.types ctx) ~at state.kind))
      in
      let expected =
        Named
          (Error.find_or_reject ~at ~name:child
             (Value.fields ~types:(Ctx.types ctx) ~at record_kind))
      in
      let branch, value =
        Ssz_ops.coerce ~ctx ~at ~kind:expected ~branch value
      in
      let location = [ Field field; Field child ] in
      ( branch,
        {
          container = state;
          selection = path_of_location at location;
          owner = StateWrite location;
        },
        value.exp )
  | _ ->
      if (Ctx.source ctx).signature.effect = Typed.Pure then
        Error.reject ~at "State mutation in a read-only helper";
      let state =
        Error.find_or_reject ~at ~name:Names.state_parameter
          (Store.bindings branch.storage)
      in
      let field, index =
        match node.it with
        | Syntax.Attribute ({ it = Syntax.Name root; _ }, field)
          when root = Names.state_parameter ->
            (field, None)
        | Syntax.Index
            ( { it = Syntax.Attribute ({ it = Syntax.Name root; _ }, field); _ },
              index )
          when root = Names.state_parameter ->
            (field, Some index)
        | _ -> Error.reject ~at "Mutation through an alias or nested record"
      in
      let kind =
        Named
          (Error.find_or_reject ~at ~name:field
             (Value.fields ~types:(Ctx.types ctx) ~at state.kind))
      in
      let sequence_value =
        { exp = DotE (state.exp, atom ~at field) $ at; kind }
      in
      let root = DotP (RootP $ at, atom ~at field) $ at in
      let branch, selection, replacement =
        match index with
        | None ->
            let branch, value = Ssz_ops.coerce ~ctx ~at ~kind ~branch value in
            (branch, root, value.exp)
        | Some { it = Syntax.Slice (lower, upper, step); _ } ->
            let { Value.length; bitvector; _ } =
              Value.sequence ~types:(Ctx.types ctx) ~at kind
            in
            if not bitvector then
              Error.reject ~at "Slice assignment requires a fixed SSZ bitvector";
            let branch = Sequence_ops.shape ~ctx ~at ~branch sequence_value in
            let branch, start, finish =
              Expr.slice_bounds ~ctx ~at ~branch (Option.get length) ~lower
                ~upper ~step
            in
            if Bigint.compare start finish > 0 then
              Error.reject ~at
                "Bitvector slice assignment requires a start at or before its \
                 end";
            let { Value.length = count; _ } =
              Value.sequence ~types:(Ctx.types ctx) ~at value.kind
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
            let branch, index =
              Numeric_ops.natural_of_integer ~ctx ~at ~branch index
            in
            let branch =
              guard ~at
                ~exp:
                  (comparison ~at ~op:`LtOp index.exp
                     (LenE sequence_value.exp $ at))
                branch
            in
            let { Value.element; bitvector; _ } =
              Value.sequence ~types:(Ctx.types ctx) ~at kind
            in
            let value =
              if
                (not bitvector)
                || Value.is_boolean ~types:(Ctx.types ctx) ~at value.kind
              then value
              else { exp = bit_of_number ctx at value; kind = element }
            in
            let branch, value =
              Ssz_ops.coerce ~ctx ~at ~kind:element ~branch value
            in
            (branch, IdxP (root, unarith index.exp) $ at, value.exp)
      in
      ( branch,
        { container = state; selection; owner = StateWrite [ Field field ] },
        replacement )

let store ?copied ~ctx (node : Syntax.expr) ~value ~branch =
  let at = node.at in
  if
    Value.set_element ~types:(Ctx.types ctx) ~at value.kind <> None
    && match node.it with Syntax.Name _ -> false | _ -> true
  then Error.reject ~at "Set ordering cannot escape into state";
  match node.it with
  | Syntax.Name name ->
      if name = Names.state_parameter || value.kind = Named Names.state_type
      then Error.reject ~at "Saving or rebinding the mutable root state";
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
                  && Lang.El.Unparse.string_of_exp
                       (Error.find_or_reject ~at ~name
                          (Store.bindings branch.storage))
                         .exp
                     = Lang.El.Unparse.string_of_exp value.exp
                then Some reference
                else None)
              (Store.references branch.storage)
      in
      let empty_record_list =
        match (value.kind, value.exp.it) with
        | Sequence (element, _), EpsE ->
            Value.is_flat_record ~types:(Ctx.types ctx) ~at element
        | _ -> false
      in
      let branch, value = bind ~ctx ~at branch ~term:value in
      let reference =
        match (reference, location) with
        | Some reference, _ -> Some reference
        | None, Some location
          when Value.is_named_container_or_set ~types:(Ctx.types ctx) ~at
                 value.kind ->
            Some
              (Store.state_view
                 ~identity:(Lang.El.Unparse.string_of_exp value.exp)
                 location)
        | None, None -> (
            match value.kind with
            | Sequence (element, _)
              when Value.is_copyable_scalar ~types:(Ctx.types ctx) ~at element
                   || empty_record_list ->
                Some (Store.owned (Lang.El.Unparse.string_of_exp value.exp))
            | _ -> None)
        | _ -> None
      in
      Branch.map_storage ~f:(Store.bind_local ~name ~value ~reference) branch
  | _ ->
      let branch, destination, replacement =
        destination_of_expr ~ctx node ~value ~branch
      in
      apply ~ctx ~at destination ~replacement ~branch

let owned_list_name ~branch (receiver : Syntax.expr) =
  match receiver.it with
  | Syntax.Name name -> (
      match List.assoc_opt name (Store.references branch.storage) with
      | Some { location = None; valid = true; _ } -> Some name
      | _ -> None)
  | _ -> None

(* The generated append replaces the stored sequence and updates every alias
   that shares the list's reference identity. *)
let append_owned ~ctx ~at ~name receiver ~value:node ~branch =
  let list = Error.find_or_reject ~at ~name (Store.bindings branch.storage) in
  let { Value.element; _ } =
    Value.sequence ~types:(Ctx.types ctx) ~at list.kind
  in
  let branch, list = bind ~ctx ~at branch ~term:list in
  Expr.translate ~ctx node ~branch
  |> List.map (fun (branch, value) ->
         if value.kind <> element then
           Error.reject ~at
             "Appending to a local list cannot convert the element";
         (if
            Value.is_named_container_or_set ~types:(Ctx.types ctx) ~at
              value.kind
          then
            match node.it with
            | Syntax.Call (constructor, _, _)
              when value.kind = Named constructor
                   && Value.is_flat_record ~types:(Ctx.types ctx) ~at value.kind
              ->
                ()
            | _ ->
                Error.reject ~at
                  "A local record list only accepts freshly constructed flat \
                   records");
         let branch, value = bind ~ctx ~at branch ~term:value in
         let reference =
           Error.find_or_reject ~at ~name (Store.references branch.storage)
         in
         let branch =
           store ~copied:name ~ctx receiver
             ~value:
               {
                 kind = Sequence (element, None);
                 exp = CatE (list.exp, ListE [ value.exp ] $ at) $ at;
               }
             ~branch
         in
         let result =
           Error.find_or_reject ~at ~name (Store.bindings branch.storage)
         in
         update_aliases ~identity:reference.identity ~value:result branch)

let append_ssz ~ctx ~at receiver ~value:node ~branch =
  if (Ctx.source ctx).signature.effect = Typed.Pure then
    Error.reject ~at "SSZ append requires a mutating caller";
  (match receiver.it with
  | Syntax.Attribute ({ it = Syntax.Name name; _ }, _)
    when name = Names.state_parameter ->
      ()
  | _ -> Error.reject ~at "Append requires a direct state field or a local list");
  Expr.translate ~ctx receiver ~branch
  |> List.concat_map (fun (branch, list) ->
         let element, capacity =
           match list.kind with
           | Named name -> (
               match Value.bounded_ssz_list ~types:(Ctx.types ctx) ~at name with
               | Some result -> result
               | None -> Error.reject ~at "Append requires a bounded SSZ List")
           | _ -> Error.reject ~at "Append requires concrete SSZ metadata"
         in
         let branch, list = bind ~ctx ~at branch ~term:list in
         Expr.translate ~ctx node ~branch
         |> List.map (fun (branch, value) ->
                if value.kind <> element then
                  Error.reject ~at "Append element conversion is unsupported";
                let branch =
                  match Value.bits ~types:(Ctx.types ctx) ~at element with
                  | Some width ->
                      Numeric_ops.guard_unsigned_bounds ~at
                        ~bits:(Bigint.of_int width) ~branch value
                  | None -> branch
                in
                let branch, value = bind ~ctx ~at branch ~term:value in
                let branch =
                  guard ~at
                    ~exp:
                      (comparison ~at ~op:`LtOp (LenE list.exp $ at)
                         (number ~at capacity))
                    branch
                in
                store ~ctx receiver
                  ~value:
                    {
                      list with
                      exp = CatE (list.exp, ListE [ value.exp ] $ at) $ at;
                    }
                  ~branch))

let append ~ctx ~at (receiver : Syntax.expr) ~value ~branch =
  (match receiver.it with
  | Syntax.Name name -> (
      match List.assoc_opt name (Store.references branch.storage) with
      | Some { location = None; valid = false; _ } ->
          Error.reject ~at
            "Mutation of an iterated local list requires a live-iterator \
             contract"
      | _ -> ())
  | _ -> ());
  match owned_list_name ~branch receiver with
  | Some name -> append_owned ~ctx ~at ~name receiver ~value ~branch
  | None -> append_ssz ~ctx ~at receiver ~value ~branch

let set_or_append_list_name = "translated_set_or_append_list"

let set_or_append_list ~ctx ~at args ~branch =
  if (Ctx.source ctx).signature.effect = Typed.Pure then
    Error.reject ~at "Sequence mutation requires a state-mutating caller";
  let receiver =
    match args with
    | [ receiver; _; _ ] -> receiver
    | _ -> Error.reject ~at "Generic sequence helper arity"
  in
  Expr.arguments ~ctx args ~branch
  |> List.map (fun (branch, values) ->
         match values with
         | [ list; index; value ] -> (
             let element, capacity =
               match list.kind with
               | Named name -> (
                   match
                     Value.bounded_ssz_list ~types:(Ctx.types ctx) ~at name
                   with
                   | Some result -> result
                   | None ->
                       Error.reject ~at
                         "Generic mutation requires a bounded SSZ List")
               | _ ->
                   Error.reject ~at
                     "Generic mutation requires concrete SSZ metadata"
             in
             if index.kind <> Named Names.validator_index then
               Error.reject ~at "Generic list index must be ValidatorIndex";
             let valid =
               match
                 ( Value.bits ~types:(Ctx.types ctx) ~at element,
                   Value.bits ~types:(Ctx.types ctx) ~at value.kind )
               with
               | Some width, Some source when width = source ->
                   comparison ~at ~op:`LeOp value.exp
                     (number ~at (Numeric_ops.unsigned_maximum width))
               | Some _, Some _ ->
                   Error.reject ~at
                     "Generic mutation requires a value of the element width"
               | Some width, None
                 when Value.is_integer ~types:(Ctx.types ctx) ~at value.kind
                 -> (
                   match value.exp.it with
                   | NumE (_, `Nat _) ->
                       comparison ~at ~op:`LeOp value.exp
                         (number ~at (Numeric_ops.unsigned_maximum width))
                   | _ ->
                       Error.reject ~at
                         "Integer variables need a reviewed SSZ conversion")
               | None, None when value.kind = element -> bool ~at true
               | _ -> Error.reject ~at "Unreviewed SSZ element conversion"
             in
             let branch, list = bind ~ctx ~at branch ~term:list in
             let branch, index = bind ~ctx ~at branch ~term:index in
             let branch, value =
               bind ~ctx ~at branch ~term:{ value with kind = element }
             in
             let result =
               {
                 kind = list.kind;
                 exp =
                   call
                     ~types:
                       [
                         Value.plaintyp_of_kind ~types:(Ctx.types ctx) ~at
                           element;
                       ]
                     ~at set_or_append_list_name
                     ~args:
                       [
                         list.exp;
                         index.exp;
                         value.exp;
                         number ~at capacity;
                         valid;
                       ];
               }
             in
             match receiver.it with
             | Syntax.Name name ->
                 let reference =
                   match
                     List.assoc_opt name (Store.references branch.storage)
                   with
                   | Some reference when reference.valid -> reference
                   | _ ->
                       Error.reject ~at
                         "Sequence receiver has no valid tracked state location"
                 in
                 if reference.location = None then
                   Error.reject ~at
                     "SSZ sequence helper requires a state-backed receiver";
                 apply ~ctx ~at
                   {
                     container = result;
                     selection = RootP $ at;
                     owner = ReferenceWrite reference;
                   }
                   ~replacement:result.exp ~branch
             | _ -> store ~ctx receiver ~value:result ~branch)
         | _ -> assert false)
