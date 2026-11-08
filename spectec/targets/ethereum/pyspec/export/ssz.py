import re
from collections.abc import Sequence
from typing import TypeVar, get_args, get_origin

from .error import Unsupported


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


def collection_parameters(kind):
    """Returns an SSZ collection's base class and parameters, or None."""
    from remerkleable.bitfields import Bitlist, Bitvector
    from remerkleable.byte_arrays import ByteList, ByteVector
    from remerkleable.complex import List, Vector

    if not isinstance(kind, type):
        return None
    for base, parameters in (
        (List, lambda k: (k.element_cls(), k.limit())),
        (Vector, lambda k: (k.element_cls(), k.vector_length())),
        (Bitlist, lambda k: (k.limit(),)),
        (Bitvector, lambda k: (k.vector_length(),)),
        (ByteList, lambda k: (k.limit(),)),
        (ByteVector, lambda k: (k.type_byte_length(),)),
    ):
        if issubclass(kind, base):
            return (base, *parameters(kind))
    return None


class Metadata:
    def __init__(self):
        self.types = {}
        self.ids = {}
        self.collections = {}

    def type(self, kind):
        from remerkleable.basic import uint
        from remerkleable.byte_arrays import ByteList, ByteVector

        if kind in self.ids:
            return self.ids[kind]
        name = getattr(kind, "__name__", str(kind))
        # remerkleable builds a new class each time the source writes a
        # parameterized collection such as List[T, N]. Classes with the same
        # name, base and parameters are one SSZ type and share one exported
        # name.
        collection = collection_parameters(kind)
        key = (name, collection)
        if collection is not None and key in self.collections:
            self.ids[kind] = self.collections[key]
            return self.ids[kind]
        if name in self.types:
            name += "_" + str(len(self.types))
        self.ids[kind] = name
        if collection is not None:
            self.collections[key] = name
        self.types[name] = {}
        if ssz_parameter(kind):
            item = {"kind": "ssz_parameter"}
        elif kind is bytes:
            # Plain Python ``bytes`` has no nominal SSZ width, unlike every
            # other reviewed byte type. ``unbounded`` marks this explicitly, so
            # a length/limit both missing from an SSZ byte type's metadata is a
            # malformed document rather than a silent width relaxation.
            item = {"kind": "bytes", "length": None, "limit": None, "unbounded": True}
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
        elif bitvector_length(kind) is not None:
            item = {
                "kind": "sequence",
                "element": self.type(bool),
                "length": str(bitvector_length(kind)),
                "limit": None,
                "bitvector": True,
            }
        elif bitlist_limit(kind) is not None:
            item = {
                "kind": "sequence",
                "element": self.type(bool),
                "length": None,
                "limit": str(bitlist_limit(kind)),
                "bitvector": False,
            }
        elif get_origin(kind) is tuple:
            if not get_args(kind) or Ellipsis in get_args(kind):
                raise Unsupported("Tuple types require fixed element types")
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
        self.types[name] = item
        return name
