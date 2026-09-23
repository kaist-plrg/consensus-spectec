"""Read ssz-specs (eth-ssz-specs) types as ssz.schema type expressions (see schema/ssz_schema.mli).

This is the only place that knows the ssz-specs type API.

As a script, exports the types its v0.1.0 test fillers declare. Type names repeat across
filler files with different definitions, so each is qualified by its module:

    python ssz_specs_schema.py --fillers <ssz-specs checkout> > _vectors/ssz_specs.json
"""

import argparse
import importlib
import inspect
import json
import pkgutil
import sys

import ssz
from ssz.layout import field_names


class Schema:
    """Collects named container and union types while describing others inline."""

    def __init__(self, qualify):
        self.types = {}
        self.qualify = qualify

    def _define(self, name, body):
        if self.types.setdefault(name, body) != body:
            raise ValueError(f"two different types named {name}")

    def add(self, name, t):
        self._define(name, self._body(t))

    def expr(self, t):
        if issubclass(t, (ssz.Container, ssz.ProgressiveContainer, ssz.CompatibleUnion)):
            name = self.qualify(t)
            self._define(name, self._body(t))
            return name
        return self._body(t)

    def _fields(self, t):
        return [[n, self.expr(t.model_fields[n].annotation)] for n in field_names(t)]

    def _body(self, t):
        body = self._describe(t)
        args = next(iter(body.values())) if isinstance(body, dict) else body
        if args is None or (isinstance(args, list) and None in args):
            raise TypeError(f"{t!r} has no length or limit")  # an unparameterized base class
        return body

    def _describe(self, t):
        if issubclass(t, ssz.Boolean):
            return "boolean"
        if issubclass(t, ssz.BaseUint):
            return f"uint{t.get_byte_length() * 8}"
        if issubclass(t, ssz.ByteVector):
            return {"vector": ["uint8", t.LENGTH]}
        if issubclass(t, ssz.ByteList):
            return {"list": ["uint8", t.LIMIT]}
        if issubclass(t, ssz.BitVector):
            return {"bitvector": t.LENGTH}
        if issubclass(t, ssz.BitList):
            return {"bitlist": t.LIMIT}
        if issubclass(t, ssz.ProgressiveBitList):
            return "progressive_bitlist"
        if issubclass(t, ssz.ProgressiveList):
            return {"progressive_list": self.expr(t.ELEMENT_TYPE)}
        if issubclass(t, ssz.Vector):
            return {"vector": [self.expr(t.ELEMENT_TYPE), t.LENGTH]}
        if issubclass(t, ssz.List):
            return {"list": [self.expr(t.ELEMENT_TYPE), t.LIMIT]}
        if issubclass(t, ssz.ProgressiveContainer):
            return {
                "progressive_container": {
                    "active_fields": list(t.ACTIVE_FIELDS),
                    "fields": self._fields(t),
                }
            }
        if issubclass(t, ssz.Container):
            return {"container": self._fields(t)}
        if issubclass(t, ssz.CompatibleUnion):
            return {
                "compatible_union": [[sel, self.expr(opt)] for sel, opt in sorted(t.OPTIONS.items())]
            }
        raise TypeError(f"unsupported ssz-specs type {t!r}")

    def to_json(self):
        return {"types": dict(sorted(self.types.items()))}


def filler_types(specs_dir):
    sys.path.insert(0, specs_dir)
    fillers = importlib.import_module("tests.fillers.ssz")

    def qualify(t):
        return f"{t.__module__.rsplit('.', 1)[-1]}.{t.__name__}"

    schema = Schema(qualify)
    for info in pkgutil.iter_modules(fillers.__path__):
        module = importlib.import_module(f"tests.fillers.ssz.{info.name}")
        for name, t in inspect.getmembers(module, inspect.isclass):
            if t.__module__ == module.__name__ and issubclass(t, ssz.SSZType):
                schema.add(f"{info.name}.{name}", t)
            elif issubclass(t, ssz.SSZType) and t.__module__.startswith("ssz"):
                # Library types a filler refers to by their own name, e.g. Uint64, Boolean;
                # generic bases such as List have no parameters and are skipped.
                try:
                    body = schema._body(t)
                except (AttributeError, TypeError):
                    continue
                schema._define(f"{info.name}.{name}", body)
    return schema.to_json()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--fillers", metavar="SSZ_SPECS", required=True)
    args = ap.parse_args()
    json.dump(filler_types(args.fillers), sys.stdout, indent=1)
    print()
