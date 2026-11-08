import ast

from .error import Unsupported


# Calls through these library namespaces become primitives whose arguments
# retain source order.
LIBRARY_NAMESPACES = {
    "bls": "Unreviewed BLS primitive",
    "int": "Unreviewed integer byte decoding",
}


def span(node):
    return {
        "start": [node.lineno, node.col_offset],
        "end": [node.end_lineno, node.end_col_offset],
    }


def expression(node):
    location = {"span": span(node)}

    def emit(kind, **fields):
        return {"kind": kind, **fields, **location}

    if isinstance(node, ast.Name):
        return emit("name", id=node.id)
    if isinstance(node, ast.Constant) and type(node.value) is int:
        return emit("integer", value=str(node.value))
    if isinstance(node, ast.Constant) and type(node.value) is bytes:
        return emit("bytes_literal", value=node.value.hex())
    if isinstance(node, ast.Constant) and type(node.value) is bool:
        return emit("boolean", value=node.value)
    if isinstance(node, ast.Constant) and node.value is None:
        return emit("none")
    if isinstance(node, ast.List) and not node.elts:
        return emit("empty")
    if isinstance(node, ast.List):
        return emit("list", elements=[expression(item) for item in node.elts])
    if isinstance(node, ast.Tuple):
        return emit("tuple", elements=[expression(item) for item in node.elts])
    if isinstance(node, ast.Lambda):
        args = node.args
        if (
            args.posonlyargs
            or args.kwonlyargs
            or args.vararg
            or args.kwarg
            or args.defaults
            or len(args.args) != 1
        ):
            raise Unsupported("Filter lambdas require one ordinary parameter")
        return emit("lambda", parameter=args.args[0].arg, body=expression(node.body))
    if (
        isinstance(node, ast.Attribute)
        and isinstance(node.value, ast.Name)
        and node.value.id == "config"
    ):
        return emit("name", id=node.attr)
    if isinstance(node, ast.Attribute):
        return emit("attribute", value=expression(node.value), field=node.attr)
    if isinstance(node, ast.Subscript):
        return emit(
            "subscript", value=expression(node.value), index=expression(node.slice)
        )
    if isinstance(node, ast.Slice):
        return emit(
            "slice",
            lower=expression(node.lower) if node.lower else None,
            upper=expression(node.upper) if node.upper else None,
            step=expression(node.step) if node.step else None,
        )
    if isinstance(node, ast.BinOp) and type(node.op) in (
        ast.Add,
        ast.Sub,
        ast.Mult,
        ast.Mod,
        ast.FloorDiv,
        ast.Pow,
        ast.BitAnd,
        ast.BitOr,
        ast.BitXor,
        ast.RShift,
    ):
        return emit(
            "binary",
            operator=type(node.op).__name__,
            left=expression(node.left),
            right=expression(node.right),
        )
    if isinstance(node, ast.BoolOp):
        return emit(
            "boolop",
            operator=type(node.op).__name__,
            values=[expression(x) for x in node.values],
        )
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
        return emit("negate", value=expression(node.operand))
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
        return emit("not", value=expression(node.operand))
    if isinstance(node, ast.Compare) and all(
        type(op)
        in (
            ast.Eq,
            ast.NotEq,
            ast.Lt,
            ast.LtE,
            ast.Gt,
            ast.GtE,
            ast.In,
            ast.NotIn,
            ast.Is,
            ast.IsNot,
        )
        for op in node.ops
    ):
        return emit(
            "compare",
            left=expression(node.left),
            operators=[type(x).__name__ for x in node.ops],
            rights=[expression(x) for x in node.comparators],
        )
    if isinstance(node, ast.IfExp):
        return emit(
            "conditional",
            test=expression(node.test),
            body=expression(node.body),
            orelse=expression(node.orelse),
        )
    if (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and isinstance(node.func.value, ast.Name)
        and node.func.value.id in LIBRARY_NAMESPACES
    ):
        if node.keywords:
            raise Unsupported(LIBRARY_NAMESPACES[node.func.value.id])
        return emit(
            "primitive",
            namespace=node.func.value.id,
            name=node.func.attr,
            args=[expression(argument) for argument in node.args],
        )
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
        if (
            node.func.attr
            not in {
                "append",
                "count",
                "index",
                "intersection",
                "verify_and_notify_new_payload",
            }
            or node.keywords
            or len(node.args) != 1
        ):
            raise Unsupported("Only reviewed single-argument methods can be exported")
        return emit(
            "method",
            value=expression(node.func.value),
            method=node.func.attr,
            args=[expression(node.args[0])],
        )
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
        if any(x.arg is None for x in node.keywords):
            raise Unsupported("Unpacked keyword arguments")
        return emit(
            "call",
            name=node.func.id,
            args=[expression(x) for x in node.args],
            keywords=[
                {"name": x.arg, "value": expression(x.value)} for x in node.keywords
            ],
        )
    if isinstance(node, (ast.ListComp, ast.GeneratorExp)):
        if (
            len(node.generators) != 1
            or node.generators[0].is_async
            or any(
                isinstance(x, (ast.ListComp, ast.GeneratorExp)) and x is not node
                for x in ast.walk(node)
            )
        ):
            raise Unsupported(
                "Only single synchronous nonnested comprehensions are supported"
            )
        loop = node.generators[0]
        targets = (
            loop.target.elts if isinstance(loop.target, ast.Tuple) else [loop.target]
        )
        if not all(isinstance(x, ast.Name) for x in targets):
            raise Unsupported("Comprehension target must contain names")
        return emit(
            "comprehension" if isinstance(node, ast.ListComp) else "generator",
            element=expression(node.elt),
            targets=[x.id for x in targets],
            tuple_target=isinstance(loop.target, ast.Tuple),
            iterable=expression(loop.iter),
            filters=[expression(x) for x in loop.ifs],
        )
    raise Unsupported(f"Source export: {type(node).__name__} at line {node.lineno}")


# The annotation names a local helper looks up when Python evaluates its
# definition. They resolve in the enclosing scope, not in the helper.
LOCAL_HELPER_ANNOTATION_NAMES = ("Sequence", "Callable", "Any", "BeaconState")


def annotation_shape(node):
    """A structural description of an annotation, or None outside the subset.

    Matching is exact rather than flattening, so an unrecognised piece makes
    the whole annotation unknown instead of disappearing from the comparison.
    """
    if isinstance(node, ast.Name):
        return ("name", node.id)
    if isinstance(node, ast.Constant) and node.value is None:
        return ("none",)
    if isinstance(node, ast.Tuple):
        return ("tuple", tuple(annotation_shape(item) for item in node.elts))
    if isinstance(node, ast.List):
        return ("list", tuple(annotation_shape(item) for item in node.elts))
    if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name):
        return ("subscript", node.value.id, annotation_shape(node.slice))
    return None


ELEMENTS_ANNOTATION = ("subscript", "Sequence", ("name", "Any"))


MUTATOR_ANNOTATION = (
    "subscript",
    "Callable",
    (
        "tuple",
        (
            ("list", (("name", "BeaconState"), ("name", "Any"))),
            ("none",),
        ),
    ),
)


def local_mutator_helper(node):
    """Admits one nested helper that applies a mutator to each sequence element.

    Its single loop calls the callable parameter with the captured state and
    the element. The translator supplies one shared generic definition for
    this shape. Other bodies, signatures and captures are rejected.
    """
    arguments = node.args
    if (
        node.decorator_list
        or getattr(node, "type_params", [])
        or arguments.posonlyargs
        or arguments.kwonlyargs
        or arguments.vararg
        or arguments.kwarg
        or arguments.defaults
        or len(arguments.args) != 2
    ):
        raise Unsupported("A local helper takes one sequence and one mutator")
    elements, callable_ = (argument.arg for argument in arguments.args)
    if annotation_shape(arguments.args[0].annotation) != ELEMENTS_ANNOTATION:
        raise Unsupported("A local helper's first parameter must be Sequence[Any]")
    if annotation_shape(arguments.args[1].annotation) != MUTATOR_ANNOTATION:
        raise Unsupported(
            "A local helper's second parameter must be "
            "Callable[[BeaconState, Any], None]"
        )
    if not (isinstance(node.returns, ast.Constant) and node.returns.value is None):
        raise Unsupported("A local helper returns None")
    if len(node.body) != 1 or not isinstance(node.body[0], ast.For):
        raise Unsupported("A local helper's body is one loop over its sequence")
    loop = node.body[0]
    if (
        loop.orelse
        or not isinstance(loop.target, ast.Name)
        or not isinstance(loop.iter, ast.Name)
        or loop.iter.id != elements
        or len(loop.body) != 1
        or not isinstance(loop.body[0], ast.Expr)
        or not isinstance(loop.body[0].value, ast.Call)
    ):
        raise Unsupported("A local helper iterates its sequence parameter once")
    call = loop.body[0].value
    element = loop.target.id
    if (
        not isinstance(call.func, ast.Name)
        or call.func.id != callable_
        or call.keywords
        or len(call.args) != 2
        or not all(isinstance(argument, ast.Name) for argument in call.args)
        or call.args[1].id != element
    ):
        raise Unsupported(
            "A local helper applies its mutator to the captured state and the element"
        )
    captured = call.args[0].id
    bound = {elements, callable_, element}
    body_names = [
        item
        for statement in node.body
        for item in ast.walk(statement)
        if isinstance(item, ast.Name)
    ]
    free = {item.id for item in body_names if item.id not in bound}
    if free != {captured}:
        raise Unsupported("A local helper captures only the mutated state")
    rebound = {
        item.id
        for item in body_names
        if isinstance(item.ctx, ast.Store) and item.id != element
    }
    if rebound:
        raise Unsupported("A local helper cannot rebind a name")
    return {
        "name": node.name,
        "elements": elements,
        "callable": callable_,
        "element": element,
        "captured": captured,
    }


def statements(nodes, annotate=None, enclosing_body=False):
    result = []
    for node in nodes:
        fields = {"span": span(node)}
        if (
            isinstance(node, ast.Expr)
            and isinstance(node.value, ast.Constant)
            and isinstance(node.value.value, str)
        ):
            continue
        if isinstance(node, ast.Assign) and len(node.targets) == 1:
            fields.update(
                kind="assign",
                target=expression(node.targets[0]),
                value=expression(node.value),
            )
        elif isinstance(node, ast.AnnAssign):
            if annotate is None or node.value is None or not node.simple:
                raise Unsupported(
                    "Annotated assignments require a reviewed local annotation"
                )
            fields.update(
                kind="annotated_assign",
                target=expression(node.target),
                annotation=annotate(node.annotation),
                value=expression(node.value),
            )
        elif isinstance(node, ast.AugAssign) and type(node.op) in (
            ast.Add,
            ast.Sub,
            ast.Mult,
            ast.Mod,
            ast.FloorDiv,
        ):
            fields.update(
                kind="aug_assign",
                operator=type(node.op).__name__,
                target=expression(node.target),
                value=expression(node.value),
            )
        elif isinstance(node, ast.Break):
            fields.update(kind="break")
        elif isinstance(node, ast.Return):
            fields.update(
                kind="return", value=expression(node.value) if node.value else None
            )
        elif isinstance(node, ast.If):
            fields.update(
                kind="if",
                test=expression(node.test),
                body=statements(node.body, annotate),
                orelse=statements(node.orelse, annotate),
            )
        elif isinstance(node, ast.For):
            targets = (
                node.target.elts
                if isinstance(node.target, ast.Tuple)
                else [node.target]
            )
            if node.orelse or not all(
                isinstance(target, ast.Name) for target in targets
            ):
                raise Unsupported("For loops require name targets and no else clause")
            fields.update(
                kind="for",
                targets=[target.id for target in targets],
                tuple_target=isinstance(node.target, ast.Tuple),
                iterable=expression(node.iter),
                body=statements(node.body, annotate),
            )
        elif isinstance(node, ast.While):
            if node.orelse:
                raise Unsupported("Loop else clauses are outside the source subset")
            fields.update(
                kind="while",
                test=expression(node.test),
                body=statements(node.body, annotate),
            )
        elif isinstance(node, ast.Assert):
            if node.msg is not None:
                raise Unsupported("Assert messages are outside the source subset")
            fields.update(kind="assert", test=expression(node.test))
        elif isinstance(node, ast.Expr) and isinstance(node.value, ast.Call):
            fields.update(kind="expression", value=expression(node.value))
        elif isinstance(node, ast.FunctionDef):
            if not enclosing_body:
                raise Unsupported(
                    "A local helper is defined directly in its enclosing body"
                )
            fields.update(kind="local_helper", **local_mutator_helper(node))
        else:
            raise Unsupported(
                f"Source export: unsupported statement {type(node).__name__} at line {node.lineno}"
            )
        result.append(fields)
    return result
