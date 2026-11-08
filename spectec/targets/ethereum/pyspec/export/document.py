import ast
import builtins
import hashlib
import inspect
from collections.abc import Sequence
from pathlib import Path

from .checks import (
    check_engine_parameters,
    check_set_or_append_list,
    checked_state_reads,
    local_helper_contract,
    reviewed_noop_engine,
    reviewed_payload_request,
)
from .error import Unsupported
from .forks.capella import (
    ENTRY,
    FORK,
    PRESET,
    REVIEWED_FRESH_RESULTS,
    REVIEWED_RECORD_CONSTRUCTORS,
    REVISION,
)
from .load import assemble
from .runtime import (
    configuration_fields,
    constant_value,
    literal_default,
    source_function,
)
from .selection import effect, translated_functions
from .ssz import Metadata
from .syntax import span, statements
from .uses import BodyUses


FIXED_BYTE_CONSTRUCTORS = {
    "Root": 32,
    "Domain": 32,
    "ExecutionAddress": 20,
    "BLSPubkey": 48,
}


PYTHON_BUILTINS = (
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


def fixed_byte_constructor(module, name, width):
    # A reviewed fixed byte constructor either zero-fills or reinterprets an
    # exact-width byte string, so each name is checked against its bound class
    # and its evaluated default rather than its spelling.
    from remerkleable.byte_arrays import ByteVector

    kind = getattr(module, name, None)
    return (
        isinstance(kind, type)
        and issubclass(kind, ByteVector)
        and kind.type_byte_length() == width
        and bytes(kind()) == bytes(width)
    )


def library_bindings(module):
    """Lists library names bound to the expected objects."""
    from eth2spec.utils import bls
    from eth2spec.utils.hash_function import hash as hash_function
    from eth2spec.utils.ssz.ssz_impl import hash_tree_root, uint_to_bytes
    from eth2spec.utils.ssz.ssz_typing import Bytes32

    reviewed = {
        name: getattr(module, name, getattr(builtins, name)) is getattr(builtins, name)
        for name in PYTHON_BUILTINS
    }
    reviewed |= {
        "hash_tree_root": getattr(module, "hash_tree_root", None) is hash_tree_root,
        "hash": getattr(module, "hash", None) is hash_function,
        "uint_to_bytes": getattr(module, "uint_to_bytes", None) is uint_to_bytes,
        "Bytes32": getattr(module, "Bytes32", None) is Bytes32,
        "NewPayloadRequest": reviewed_payload_request(module),
        "EXECUTION_ENGINE": reviewed_noop_engine(module),
        "bls": getattr(module, "bls", None) is bls,
        "int": getattr(module, "int", builtins.int) is builtins.int,
        "ENDIANNESS": getattr(module, "ENDIANNESS", None) == "little",
    }
    reviewed |= {
        name: fixed_byte_constructor(module, name, width)
        for name, width in FIXED_BYTE_CONSTRUCTORS.items()
    }
    return [name for name, binding in reviewed.items() if binding]


def configuration_accesses(module, uses):
    config_accesses = {
        item.attr
        for item in uses.nodes
        if isinstance(item, ast.Attribute)
        and isinstance(item.value, ast.Name)
        and item.value.id == "config"
    }
    if config_accesses:
        if "config" in uses.bound_names or not config_accesses <= configuration_fields(
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


def call_metadata(module, metadata, name):
    function = source_function(module, name)
    if inspect.iscoroutinefunction(function):
        raise Unsupported(f"Unsupported source definition {name}")
    sig = inspect.signature(function)
    if any(
        parameter.kind != inspect.Parameter.POSITIONAL_OR_KEYWORD
        for parameter in sig.parameters.values()
    ):
        raise Unsupported(f"Unsupported source signature for {name}")
    return {
        "name": name,
        # "optional" carries a None default, which widens the type. "default"
        # carries a literal default, which a call site binds without changing
        # the type, and is absent when the parameter has none.
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
        "effect": effect(module, name),
    }


def constant_metadata(module, metadata, names):
    constants = {}
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
    return constants


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


def register_unsigned_classes(module, metadata):
    """Registers unsigned classes by module binding name for cast resolution."""
    from remerkleable.basic import uint

    bound = sorted(
        name
        for name, value in vars(module).items()
        if isinstance(value, type) and issubclass(value, uint)
    )
    for name in bound:
        if metadata.type(getattr(module, name)) != name:
            raise Unsupported(
                f"Unsigned integer class bound under another name: {name}"
            )
    unbound = sorted(
        name
        for name, item in metadata.types.items()
        if item["kind"] == "uint" and name not in bound
    )
    if unbound:
        raise Unsupported(f"Unsigned integer types without a module binding: {unbound}")


def definition(module, metadata, node):
    signature = inspect.signature(source_function(module, node.name))
    uses = BodyUses(node)
    local_helper_contract(module, uses)
    if "set_or_append_list" in uses.call_names:
        check_set_or_append_list(module)
    check_engine_parameters(module, node, signature)
    config_accesses = configuration_accesses(module, uses)
    names = uses.names | config_accesses
    return constant_metadata(module, metadata, names), {
        "span": span(node),
        "body": statements(
            node.body, local_annotation(module, metadata), enclosing_body=True
        ),
    }


# Only nodes supply bodies. Other reached functions supply callable signatures.
def module_document(module, filename, source_hash, nodes):
    metadata = Metadata()
    signatures = {
        name: call_metadata(module, metadata, name)
        for name in translated_functions(module, [node.name for node in nodes])
    }
    constants, definitions = {}, {}
    for node in nodes:
        if node.name in definitions:
            raise Unsupported(f"Duplicate source function {node.name}")
        used, definitions[node.name] = definition(module, metadata, node)
        constants |= used
    # Translation needs these types in the type table even when no signature
    # names them.
    for kind in (int, bool, module.Bytes32, module.ExecutionEngine):
        metadata.type(kind)
    for name in REVIEWED_RECORD_CONSTRUCTORS:
        metadata.type(getattr(module, name))
    register_unsigned_classes(module, metadata)
    return {
        "source": {
            "revision": REVISION,
            "fork": FORK,
            "preset": PRESET,
            "file": filename,
            "sha256": source_hash,
            "span_units": "line-1-byte-column-0-end-exclusive",
        },
        "types": metadata.types,
        "constants": dict(sorted(constants.items())),
        "bindings": library_bindings(module),
        "reviewed": {
            "state_reads": checked_state_reads(module),
            "constructors": list(REVIEWED_RECORD_CONSTRUCTORS),
            "fresh_results": [
                name for name in REVIEWED_FRESH_RESULTS if name in signatures
            ],
        },
        "functions": [
            signatures[name] | definitions.get(name, {"body": None})
            for name in sorted(signatures)
        ],
    }


def assembled_document(source, module, names):
    path = Path(module.__file__).resolve()
    text = path.read_bytes()
    nodes = {
        node.name: node
        for node in ast.parse(text).body
        if isinstance(node, ast.FunctionDef)
    }
    missing = set(names) - nodes.keys()
    if missing:
        raise Unsupported(f"Missing assembled source functions: {sorted(missing)}")
    for name in names:
        code = source_function(module, name).__code__
        if (
            Path(code.co_filename).resolve() != path
            or code.co_firstlineno != nodes[name].lineno
        ):
            raise Unsupported(f"Pyspec does not run the assembled definition of {name}")
    return module_document(
        module,
        str(path),
        hashlib.sha256(text).hexdigest(),
        [nodes[name] for name in names],
    )


def export(source):
    module = assemble(source)
    return assembled_document(source, module, translated_functions(module, [ENTRY]))
