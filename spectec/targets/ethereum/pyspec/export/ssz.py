import re
from collections.abc import Sequence
from typing import TypeVar, get_args, get_origin

from .error import Unsupported
from .metadata.capella import TYPE_NAMES


def ssz_parameter(kind):
    if not isinstance(kind, TypeVar):
        return None
    from remerkleable.core import View

    if kind.__bound__ is not View or kind.__constraints__:
        raise Unsupported("Type parameters require the SSZ View bound")
    if not re.fullmatch(r"[A-Z][A-Za-z0-9]*", kind.__name__):
        raise Unsupported(
            "SSZ type parameter names must start with an uppercase letter"
        )
    return kind.__name__


def type_name(kind):
    if parameter := ssz_parameter(kind):
        return parameter
    if get_origin(kind) is tuple:
        items = get_args(kind)
        if not items or Ellipsis in items:
            raise Unsupported("Tuple interfaces require fixed element types")
        return "(" + ", ".join(type_name(item) for item in items) + ")"
    if get_origin(kind) in (Sequence, set):
        return type_name(get_args(kind)[0]) + "*"
    if bitvector_length(kind) is not None:
        return "bool*"
    if hasattr(kind, "element_cls"):
        return type_name(kind.element_cls()) + "*"
    name = getattr(kind, "__name__", None)
    if name not in TYPE_NAMES and byte_vector_target(kind) is not None:
        return byte_vector_target(kind)
    if name not in TYPE_NAMES:
        raise Unsupported(f"Unmapped source type {kind}")
    return TYPE_NAMES[name]


def nested_type_parameter(kind):
    return any(
        ssz_parameter(argument) is not None or nested_type_parameter(argument)
        for argument in get_args(kind)
    )


def byte_vector_target(kind):
    from remerkleable.byte_arrays import ByteVector

    if (
        isinstance(kind, type)
        and issubclass(kind, ByteVector)
        and kind.type_byte_length() in {1, 4, 8, 20, 28, 31, 32, 48, 96, 256}
    ):
        return f"bytes{kind.type_byte_length()}"
    return None


def bitlist_limit(kind):
    from remerkleable.bitfields import Bitlist

    if isinstance(kind, type) and issubclass(kind, Bitlist):
        return kind.limit()
    return None


def bitvector_length(kind):
    from remerkleable.bitfields import Bitvector

    if isinstance(kind, type) and issubclass(kind, Bitvector):
        return kind.vector_length()
    return None
