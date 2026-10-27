import ast
import builtins
import hashlib
import inspect
from collections.abc import Sequence
from pathlib import Path
from textwrap import dedent
from typing import Any, get_args, get_origin

from .error import RegistrationRequired, Unsupported
from .interface import interfaces
from .load import assemble, python_blocks
from .metadata.capella import (
    FORK,
    PRESET,
    REVIEWED_EFFECTS,
    REVIEWED_FRESH_RESULTS,
    REVIEWED_RECORD_CONSTRUCTORS,
    REVIEWED_STATE_READS,
    REVISION,
    TYPE_NAMES,
)
from .pyspec import configuration_fields, constant_value, literal_default, source_function
from .provenance import select_sources
from .ssz import bitlist_limit, bitvector_length, byte_vector_target, ssz_parameter
BLS_PRIMITIVES = {
    "KeyValidate": ("bls_key_validate", 1),
    "AggregatePKs": ("bls_aggregate_pubkeys", 1),
    "Verify": ("bls_verify", 3),
    "FastAggregateVerify": ("bls_fast_aggregate_verify", 3),
    "bytes48_to_G1": ("bls_g1_decode", 1),
    "G1_to_bytes48": ("bls_g1_encode", 1),
    "add": ("bls_g1_add", 2),
    "neg": ("bls_g1_neg", 1),
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
        and node.func.value.id == "bls"
    ):
        if node.func.attr not in BLS_PRIMITIVES or node.keywords:
            raise Unsupported("Unreviewed BLS primitive")
        name, arity = BLS_PRIMITIVES[node.func.attr]
        if len(node.args) != arity:
            raise Unsupported("Unreviewed BLS primitive")
        return emit(
            "primitive",
            name=name,
            args=[expression(argument) for argument in node.args],
        )
    if (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and isinstance(node.func.value, ast.Name)
        and node.func.value.id == "int"
        and node.func.attr == "from_bytes"
    ):
        if (
            node.keywords
            or len(node.args) != 2
            or not isinstance(node.args[1], ast.Name)
            or node.args[1].id != "ENDIANNESS"
        ):
            raise Unsupported("Unreviewed integer byte decoding")
        return emit(
            "primitive",
            name="int_from_bytes",
            args=[expression(node.args[0])],
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
    """One nested helper that applies a mutator to each element of a sequence.

    The admitted shape is exactly a `for` over the sequence parameter whose body
    calls the callable parameter with the captured state and the element. The
    translator emits one shared generic definition for that shape, so any other
    body, signature or capture rejects here rather than being approximated.
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


class Metadata:
    def __init__(self):
        self.types = {}
        self.ids = {}

    def type(self, kind):
        from remerkleable.basic import uint
        from remerkleable.byte_arrays import ByteList, ByteVector

        if kind in self.ids:
            return self.ids[kind]
        name = getattr(kind, "__name__", str(kind))
        if name in self.types:
            name += "_" + str(len(self.types))
        self.ids[kind] = name
        self.types[name] = {}
        target = TYPE_NAMES.get(name) or byte_vector_target(kind)
        if parameter := ssz_parameter(kind):
            item = {"kind": "ssz_parameter"}
            target = parameter
        elif kind is bytes:
            # Plain Python ``bytes`` has no nominal SSZ width, unlike every
            # other reviewed byte type. ``unbounded`` marks this explicitly,
            # so a length/limit both missing from an SSZ byte type's metadata
            # is a malformed document rather than a silent width relaxation.
            item = {"kind": "bytes", "length": None, "limit": None, "unbounded": True}
            target = "bytes"
        elif kind in (bool, int) or name == "boolean":
            item = {"kind": "integer" if kind is int else "boolean"}
        elif isinstance(kind, type) and issubclass(kind, uint):
            item = {"kind": "uint", "bits": kind.type_byte_length() * 8}
        elif isinstance(kind, type) and issubclass(kind, (ByteVector, ByteList)):
            fixed = issubclass(kind, ByteVector)
            item = {
                "kind": "bytes",
                "length": str(kind.type_byte_length()) if fixed else None,
                "limit": None if fixed else str(kind.limit()),
                "unbounded": False,
            }
            if not fixed:
                target = "bytes"
        elif bitvector_length(kind) is not None:
            item = {
                "kind": "sequence",
                "element": self.type(bool),
                "length": str(bitvector_length(kind)),
                "limit": None,
                "bitvector": True,
            }
        elif bitlist_limit(kind) is not None:
            # A bitlist is a bounded sequence of bits, so it carries a limit
            # rather than a length and is not a fixed bitvector.
            item = {
                "kind": "sequence",
                "element": self.type(bool),
                "length": None,
                "limit": str(bitlist_limit(kind)),
                "bitvector": False,
            }
        elif get_origin(kind) is tuple:
            item = {
                "kind": "tuple",
                "elements": [self.type(value) for value in get_args(kind)],
            }
        elif get_origin(kind) is set:
            item = {"kind": "set", "element": self.type(get_args(kind)[0])}
        elif get_origin(kind) is Sequence or hasattr(kind, "element_cls"):
            element = (
                get_args(kind)[0]
                if get_origin(kind) is Sequence
                else kind.element_cls()
            )
            length = kind.vector_length() if hasattr(kind, "vector_length") else None
            limit = kind.limit() if hasattr(kind, "limit") else None
            item = {
                "kind": "sequence",
                "element": self.type(element),
                "length": str(length) if length is not None else None,
                "limit": str(limit) if limit is not None else None,
                "bitvector": False,
            }
        elif hasattr(kind, "fields"):
            item = {
                "kind": "record",
                "fields": {
                    name: self.type(value) for name, value in kind.fields().items()
                },
            }
        else:
            item = {"kind": "opaque"}
        self.types[name] = {**item, "target": target}
        return name


def markdown_definition(markdown, original):
    source_root, documents = markdown
    for document in documents:
        raw = (source_root / document).read_bytes()
        for offset, block in python_blocks(raw.decode()):
            for definition in ast.parse(block).body:
                if isinstance(definition, ast.FunctionDef) and ast.dump(
                    definition
                ) == ast.dump(original):
                    return definition, document, raw, offset
    raise Unsupported("Generic helper does not match original Markdown")


def sequence_helpers(module, node, markdown):
    names = {
        item.func.id
        for item in ast.walk(node)
        if isinstance(item, ast.Call)
        and isinstance(item.func, ast.Name)
        and item.func.id == "set_or_append_list"
    }
    helpers = []
    for name in sorted(names):
        from remerkleable.complex import List

        function = getattr(module, name)
        signature = inspect.signature(function)
        parameters = list(signature.parameters.values())
        if (
            [p.name for p in parameters] != ["list", "index", "value"]
            or [p.annotation for p in parameters] != [List, module.ValidatorIndex, Any]
            or any(
                p.default != inspect.Parameter.empty
                or p.kind != inspect.Parameter.POSITIONAL_OR_KEYWORD
                for p in parameters
            )
            or signature.return_annotation is not None
            or getattr(module, "len", builtins.len) is not builtins.len
        ):
            raise Unsupported("Unreviewed generic sequence helper signature")
        lines, start = inspect.getsourcelines(function)
        original = ast.parse(dedent("".join(lines))).body[0]
        if original.decorator_list or getattr(original, "type_params", []):
            raise Unsupported("Decorated generic helper")
        filename = inspect.getsourcefile(function)
        raw = Path(filename).read_bytes()
        if markdown is not None:
            original, filename, raw, start = markdown_definition(markdown, original)
        ast.increment_lineno(original, start - 1)
        helpers.append(
            {
                "name": name,
                "parameters": [p.name for p in parameters],
                "source": {"file": filename, "sha256": hashlib.sha256(raw).hexdigest()},
                "span": span(original),
                "body": statements(original.body),
            }
        )
    return helpers


def check_noop_engine(module):
    engine = getattr(module, "EXECUTION_ENGINE", None)
    noop = getattr(module, "NoopExecutionEngine", None)
    method = getattr(type(engine), "verify_and_notify_new_payload", None)
    if (
        not isinstance(noop, type)
        or type(engine) is not noop
        or getattr(method, "__qualname__", None)
        != "NoopExecutionEngine.verify_and_notify_new_payload"
        or getattr(method, "__module__", None) != module.__name__
    ):
        raise Unsupported("Unreviewed external execution-engine binding")
    # The runner answers an unsupplied engine with the reviewed noop response,
    # so that response is observed here rather than assumed.
    request = module.NewPayloadRequest(execution_payload=module.ExecutionPayload())
    if engine.verify_and_notify_new_payload(request) is not True:
        raise Unsupported("Unreviewed external execution-engine response")


def referenced_global_names(function):
    import types

    names, pending = set(), [function.__code__]
    while pending:
        code = pending.pop()
        names |= set(code.co_names)
        pending += [
            value for value in code.co_consts if isinstance(value, types.CodeType)
        ]
    return names


def reaches_external_engine_global(module, name):
    """Whether the reviewed call closure of ``name`` can read EXECUTION_ENGINE.

    Compiled code objects are used rather than source text so that the answer
    is available for every reviewed function, including fixtures with no file.
    Attribute names widen the reviewed call graph, which can only reject more.
    """
    pending, seen = [name], set()
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)
        names = referenced_global_names(source_function(module, current))
        if "EXECUTION_ENGINE" in names:
            return True
        pending += sorted(names & (REVIEWED_EFFECTS.keys() - seen))
    return False


def local_helper_contract(module, node):
    """How a nested mutator helper and the mutators it receives may be used.

    The helper exists only to be called, and a mutator named at a call site may
    not also be read as a value, so neither can escape into a position the
    target has no function value for.
    """
    helpers = [item for item in ast.walk(node) if isinstance(item, ast.FunctionDef)][1:]
    if not helpers:
        return
    import typing

    if (
        getattr(module, "Sequence", None) is not typing.Sequence
        or getattr(module, "Callable", None) is not typing.Callable
        or getattr(module, "Any", None) is not typing.Any
        or not isinstance(getattr(module, "BeaconState", None), type)
    ):
        raise Unsupported("Unreviewed local helper annotation bindings")
    # Python evaluates a nested definition's annotations in the enclosing
    # scope, so a name bound there hides the module binding checked above. A
    # name bound inside a helper is not one of those lookups.
    inside = {id(item) for helper in helpers for item in ast.walk(helper)}
    enclosing = (
        {argument.arg for argument in node.args.args}
        | {
            item.id
            for item in ast.walk(node)
            if isinstance(item, ast.Name)
            and isinstance(item.ctx, ast.Store)
            and id(item) not in inside
        }
        | {
            item.name
            for item in ast.walk(node)
            if isinstance(item, (ast.FunctionDef, ast.ClassDef)) and item is not node
        }
    )
    shadowed = sorted(enclosing & set(LOCAL_HELPER_ANNOTATION_NAMES))
    if shadowed:
        raise Unsupported(
            f"A local helper annotation name is shadowed: {', '.join(shadowed)}"
        )
    names = [helper.name for helper in helpers]
    if len(set(names)) != len(names) or any(
        name in REVIEWED_EFFECTS or hasattr(module, name) for name in names
    ):
        raise Unsupported("A local helper name must be fresh")
    nested = [
        item
        for helper in helpers
        for item in ast.walk(helper)
        if isinstance(item, ast.FunctionDef) and item is not helper
    ]
    if nested:
        raise Unsupported("A local helper cannot define another helper")
    mutators = set()
    for name in names:
        reads = [
            item
            for item in ast.walk(node)
            if isinstance(item, ast.Name) and item.id == name
        ]
        calls = [
            item
            for item in ast.walk(node)
            if isinstance(item, ast.Call)
            and isinstance(item.func, ast.Name)
            and item.func.id == name
        ]
        if len(reads) != len(calls):
            raise Unsupported(f"A local helper is only callable: {name}")
        for call in calls:
            if (
                call.keywords
                or len(call.args) != 2
                or not isinstance(call.args[1], ast.Name)
            ):
                raise Unsupported(
                    f"A local helper call passes one sequence and one mutator: {name}"
                )
            mutator = call.args[1].id
            if REVIEWED_EFFECTS.get(mutator) != "state":
                raise Unsupported(f"Unreviewed local helper mutator: {mutator}")
            mutators.add(mutator)
    for mutator in sorted(mutators):
        positions = [
            item
            for item in ast.walk(node)
            if isinstance(item, ast.Name) and item.id == mutator
        ]
        arguments = [
            call.args[1]
            for call in ast.walk(node)
            if isinstance(call, ast.Call)
            and isinstance(call.func, ast.Name)
            and call.func.id in names
        ]
        if len(positions) != len([item for item in arguments if item.id == mutator]):
            raise Unsupported(
                f"A mutator passed to a local helper cannot escape: {mutator}"
            )


def checked_state_reads(module):
    """The reviewed read footprints, checked against the pinned source.

    Each declared footprint must cover every BeaconState field name reachable
    from that helper through the reviewed call graph. Attribute names widen
    the reachable set, so the check can only demand more.
    """
    fields = set(module.BeaconState.fields())
    result = {}
    for name, declared in REVIEWED_STATE_READS.items():
        pending, seen, reads = [name], set(), set()
        while pending:
            current = pending.pop()
            if current in seen:
                continue
            seen.add(current)
            names = referenced_global_names(source_function(module, current))
            reads |= names & fields
            pending += sorted(names & (REVIEWED_EFFECTS.keys() - seen))
        if not reads <= set(declared):
            raise Unsupported(
                f"Reviewed state reads for {name} miss {sorted(reads - set(declared))}"
            )
        result[name] = sorted(declared)
    return result


def check_signature(node, signature):
    if (
        getattr(node, "type_params", [])
        or node.args.posonlyargs
        or node.args.kwonlyargs
        or node.args.vararg
        or node.args.kwarg
        or node.decorator_list
        or [arg.arg for arg in node.args.args] != list(signature.parameters)
    ):
        raise Unsupported("Source export: unsupported function signature")
    # A default is either None, which makes the parameter optional, or a boolean
    # literal, which keeps the present type and is bound at an omitting call
    # site. The Markdown defaults and the assembled signature must name the same
    # trailing parameters and the same values, so the exported defaults come
    # from both views of the source.
    defaults = node.args.defaults
    annotated = [
        arg.arg for arg in node.args.args[len(node.args.args) - len(defaults) :]
    ]
    defaulted = [
        name
        for name, parameter in signature.parameters.items()
        if parameter.default is not inspect.Parameter.empty
    ]
    if (
        any(
            not isinstance(default, ast.Constant)
            or (
                default.value is not None
                and default.value is not True
                and default.value is not False
            )
            for default in defaults
        )
        or annotated != defaulted
        or any(
            signature.parameters[name].default is not default.value
            for name, default in zip(annotated, defaults)
        )
    ):
        raise Unsupported("Source export: unsupported parameter default")


def bls_primitives(module, node, signature, source_calls):
    from eth2spec.utils import bls

    primitive_calls = [
        item
        for item in source_calls
        if isinstance(item.func, ast.Attribute)
        and isinstance(item.func.value, ast.Name)
        and item.func.value.id == "bls"
    ]
    if primitive_calls and (
        getattr(module, "bls", None) is not bls
        or any(
            isinstance(item, ast.Name)
            and item.id == "bls"
            and isinstance(item.ctx, ast.Store)
            for item in ast.walk(node)
        )
        or "bls" in signature.parameters
    ):
        raise Unsupported("Unreviewed BLS namespace binding")
    primitives = sorted(
        {
            BLS_PRIMITIVES[item.func.attr][0]
            for item in primitive_calls
            if item.func.attr in BLS_PRIMITIVES
        }
    )
    if "bls_aggregate_pubkeys" in primitives:
        primitives.append("bls_key_validate")
    # Both G1 conversions call the target's bls_g1_canonicalize builtin.
    if {"bls_g1_decode", "bls_g1_encode"} & set(primitives):
        primitives.append("bls_g1_canonicalize")
    for item in source_calls:
        if isinstance(item.func, ast.Name) and item.func.id in primitives:
            raise Unsupported(
                f"Source call name collides with synthetic BLS primitive {item.func.id}"
            )
    return primitives


def execution_primitives(
    module, node, signature, source_calls, call_names, bound_names
):
    primitives = []
    if "NewPayloadRequest" in call_names:
        from dataclasses import fields, is_dataclass

        request = getattr(module, "NewPayloadRequest", None)
        if "NewPayloadRequest" in bound_names:
            raise Unsupported("Shadowed execution-payload request constructor")
        if not is_dataclass(request) or [
            (field.name, field.type) for field in fields(request)
        ] != [("execution_payload", module.ExecutionPayload)]:
            raise Unsupported("Unreviewed execution-payload request binding")
        primitives.append("NewPayloadRequest")
    # The engine method is rewritten to the privileged builtin name
    # "ee_verify_and_notify_new_payload", so an ordinary source call already
    # spelled that way would be indistinguishable from the rewritten form.
    if (
        any(
            isinstance(item.func, ast.Attribute)
            and item.func.attr == "verify_and_notify_new_payload"
            for item in source_calls
        )
        and "ee_verify_and_notify_new_payload" in call_names
    ):
        raise Unsupported(
            "Source call name collides with the synthetic ee_verify_and_notify_new_payload builtin"
        )
    if any(
        isinstance(item, ast.Name) and item.id == "EXECUTION_ENGINE"
        for item in ast.walk(node)
    ):
        if "EXECUTION_ENGINE" in bound_names:
            raise Unsupported("Shadowed external execution-engine global")
        check_noop_engine(module)
        primitives.append("EXECUTION_ENGINE")
    engine_parameters = [
        name
        for name, parameter in signature.parameters.items()
        if parameter.annotation is module.ExecutionEngine
    ]
    if engine_parameters and reaches_external_engine_global(module, node.name):
        # One unit-typed handle stands for one external service per request, so
        # a supplied engine and the global cannot both be consulted.
        raise Unsupported(
            "A supplied execution engine cannot reach the execution-engine global"
        )
    return primitives


def byte_primitives(module, source_calls, call_names, bound_names):
    primitives = []
    if "hash_tree_root" in call_names:
        from eth2spec.utils.ssz.ssz_impl import hash_tree_root

        if getattr(module, "hash_tree_root", None) is not hash_tree_root:
            raise Unsupported("Unreviewed SSZ hash binding")
        primitives.append("hash_tree_root")
    if "Bytes32" in call_names:
        from eth2spec.utils.ssz.ssz_typing import Bytes32

        if getattr(module, "Bytes32", None) is not Bytes32:
            raise Unsupported("Unreviewed Bytes32 constructor binding")
        primitives.append("Bytes32")
    # A reviewed fixed byte constructor either zero-fills or reinterprets an
    # exact-width byte string, so each name is checked against its bound class
    # and its evaluated default rather than its spelling.
    for constructor, width in {
        "Root": 32,
        "Domain": 32,
        "ExecutionAddress": 20,
        "BLSPubkey": 48,
    }.items():
        if constructor not in call_names:
            continue
        from remerkleable.byte_arrays import ByteVector

        kind = getattr(module, constructor, None)
        if (
            not isinstance(kind, type)
            or not issubclass(kind, ByteVector)
            or kind.type_byte_length() != width
            or bytes(kind()) != bytes(width)
        ):
            raise Unsupported(
                f"Unreviewed fixed byte constructor binding: {constructor}"
            )
        primitives.append(constructor)
    from eth2spec.utils.hash_function import hash as source_hash_function
    from eth2spec.utils.ssz.ssz_impl import uint_to_bytes

    for name, primitive in [
        ("hash", source_hash_function),
        ("uint_to_bytes", uint_to_bytes),
    ]:
        if name in call_names:
            if getattr(module, name, None) is not primitive:
                raise Unsupported(f"Unreviewed byte primitive binding: {name}")
            primitives.append(name)
    if any(
        isinstance(item.func, ast.Attribute)
        and isinstance(item.func.value, ast.Name)
        and item.func.value.id == "int"
        and item.func.attr == "from_bytes"
        for item in source_calls
    ):
        if (
            getattr(module, "int", builtins.int) is not builtins.int
            or getattr(module, "ENDIANNESS", None) != "little"
            or {"int", "ENDIANNESS"} & bound_names
        ):
            raise Unsupported("Unreviewed little-endian byte decoding")
        if "int_from_bytes" in call_names:
            raise Unsupported(
                "Source call name collides with the synthetic int_from_bytes builtin"
            )
        primitives.append("int_from_bytes")
    return primitives


def configuration_accesses(module, node, bound_names):
    config_accesses = {
        item.attr
        for item in ast.walk(node)
        if isinstance(item, ast.Attribute)
        and isinstance(item.value, ast.Name)
        and item.value.id == "config"
    }
    if config_accesses:
        if "config" in bound_names or not config_accesses <= configuration_fields(
            module
        ):
            raise Unsupported("Unreviewed configuration namespace binding")
        from remerkleable.byte_arrays import ByteVector as _ByteVector

        if any(
            not isinstance(constant_value(module, name), (int, _ByteVector))
            for name in config_accesses
        ):
            raise Unsupported(
                "Configuration constants must be integers or fixed byte values"
            )
    return config_accesses


def call_metadata(module, metadata, presentation, name):
    sig = inspect.signature(source_function(module, name))
    return {
        "name": name,
        # "optional" carries a None default, which widens the type. "default"
        # carries a literal default, which a call site binds without
        # changing the type, and is absent when the parameter has none.
        "parameters": [
            {
                "name": p.name,
                "type": metadata.type(p.annotation),
                "optional": p.default is None,
            }
            | (
                {}
                if literal_default(p) is None
                else {"default": literal_default(p)}
            )
            for p in sig.parameters.values()
        ],
        "returns": metadata.type(sig.return_annotation)
        if sig.return_annotation is not None
        else None,
        "effect": REVIEWED_EFFECTS[name],
        "interface": presentation[name].metadata(),
        "fresh_result": name in REVIEWED_FRESH_RESULTS,
    }



def constant_metadata(module, metadata, names):
    constants, casts = {}, {}
    from remerkleable.byte_arrays import ByteVector

    for name in sorted(names):
        value = constant_value(module, name)
        if isinstance(value, int) and not isinstance(value, bool):
            constants[name] = {
                "type": metadata.type(type(value)),
                "value": str(int(value)),
            }
        if isinstance(value, list) and value:
            from remerkleable.basic import uint

            element = type(value[0])
            if (
                issubclass(element, uint)
                and element.type_byte_length() == 8
                and all(type(item) is element for item in value)
            ):
                constants[name] = {
                    "type": metadata.type(Sequence[element]),
                    "value": [str(int(item)) for item in value],
                }
        if isinstance(value, ByteVector):
            # A fixed byte constant carries the big-endian value of its bytes,
            # matching the target representation of a fixed byte width.
            constants[name] = {
                "type": metadata.type(type(value)),
                "value": str(int.from_bytes(bytes(value), "big")),
            }
        if isinstance(value, type):
            from remerkleable.basic import uint

            if issubclass(value, uint):
                casts[name] = metadata.type(value)

    return constants, casts


def local_annotation(module, metadata):
    def annotate(node):
        # Python never evaluates a local variable annotation, so the spec can
        # write an SSZ sequence without its limit. The annotation is read
        # syntactically for its element type, which is all an empty literal
        # needs in order to be typed.
        if (
            isinstance(node, ast.Subscript)
            and isinstance(node.value, ast.Name)
            and node.value.id in ("List", "Sequence", "Vector")
        ):
            element = node.slice
            if isinstance(element, ast.Tuple) and element.elts:
                element = element.elts[0]
            if isinstance(element, ast.Name):
                resolved = getattr(module, element.id, None)
                if resolved is not None:
                    return metadata.type(resolved)
        raise Unsupported("Unreviewed local annotation")

    return annotate


def python_builtins(module):
    return [
        name
        for name in (
            "all",
            "enumerate",
            "len",
            "min",
            "max",
            "range",
            "sum",
            "set",
            "filter",
            "sorted",
            "zip",
        )
        if getattr(module, name, getattr(builtins, name)) is getattr(builtins, name)
    ]


def export_function(
    module,
    node,
    filename,
    source_hash,
    all_expansion_limit=4,
    markdown=None,
):
    if node.name not in REVIEWED_EFFECTS:
        raise RegistrationRequired(
            f"Register an effect contract for {node.name} before translation"
        )
    signature = inspect.signature(source_function(module, node.name))
    check_signature(node, signature)
    presentation = interfaces(module)
    source_calls = [item for item in ast.walk(node) if isinstance(item, ast.Call)]
    call_names = {
        item.func.id for item in source_calls if isinstance(item.func, ast.Name)
    }
    primitives = bls_primitives(module, node, signature, source_calls)
    local_helper_contract(module, node)
    bound_names = {
        item.id
        for item in ast.walk(node)
        if isinstance(item, ast.Name) and isinstance(item.ctx, ast.Store)
    } | {item.arg for item in ast.walk(node) if isinstance(item, ast.arg)}
    primitives += execution_primitives(
        module, node, signature, source_calls, call_names, bound_names
    )
    primitives += byte_primitives(module, source_calls, call_names, bound_names)
    config_accesses = configuration_accesses(module, node, bound_names)
    metadata = Metadata()
    calls = [
        call_metadata(module, metadata, presentation, name)
        for name in REVIEWED_EFFECTS
    ]
    selected = next(item for item in calls if item["name"] == node.name)
    names = (
        {x.id for x in ast.walk(node) if isinstance(x, ast.Name)}
        | {"UINT64_MAX"}
        | config_accesses
    )
    constants, casts = constant_metadata(module, metadata, names)
    metadata.type(int)
    metadata.type(bool)
    metadata.type(module.Checkpoint)
    metadata.type(module.Bytes32)
    metadata.type(module.ForkData)
    metadata.type(module.SigningData)
    metadata.type(module.DepositMessage)
    metadata.type(module.ExecutionEngine)
    constructors = sorted(
        {
            x.func.id
            for x in ast.walk(node)
            if isinstance(x, ast.Call) and isinstance(x.func, ast.Name)
        }
        & set(REVIEWED_RECORD_CONSTRUCTORS)
    )
    for name in constructors:
        metadata.type(getattr(module, name))
    return {
        "source": {
            "revision": REVISION,
            "fork": FORK,
            "preset": PRESET,
            "file": filename,
            "sha256": source_hash,
            "span_units": "line-1-byte-column-0-end-exclusive",
        },
        "options": {"all_expansion_limit": all_expansion_limit},
        "types": metadata.types,
        "constants": constants,
        "casts": casts,
        "state_reads": checked_state_reads(module),
        "calls": calls,
        "builtins": python_builtins(module) + primitives,
        "constructors": constructors,
        "sequence_helpers": sequence_helpers(module, node, markdown),
        "function": {
            **selected,
            "body": statements(
                node.body, local_annotation(module, metadata), enclosing_body=True
            ),
            "locals": sorted(bound_names | set(signature.parameters)),
            "span": span(node),
        },
    }


def export(source, name):
    module, documents = assemble(source)
    body = select_sources(source, module, documents, [name])[name]
    return export_function(
        module, body.node, body.filename, body.sha256, markdown=(source, documents)
    )
