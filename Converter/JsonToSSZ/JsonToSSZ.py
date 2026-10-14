import argparse
import importlib
import json
import os
import sys
from typing import Any

# Add the pyspec (eth_consensus_specs) to path
# Get the absolute path to ensure it works from any directory
script_dir = os.path.dirname(os.path.abspath(__file__))
consensus_specs_path = os.path.abspath(os.path.join(script_dir, '../../consensus-specs/tests/core/pyspec'))
if consensus_specs_path not in sys.path:
    sys.path.insert(0, consensus_specs_path)

from ssz import BaseUint, BitList, BitVector, Boolean, ByteList, ByteVector, Container, List, Vector

def _from_hex(s: str) -> bytes:
    if not isinstance(s, str) or not s.startswith("0x"):
        raise ValueError("Expected 0x-prefixed hex string")
    return bytes.fromhex(s[2:])

def json_to_ssz(j: Any, typ) -> Any:
    # 1) Container
    if issubclass(typ, Container):
        if not isinstance(j, dict):
            raise TypeError(f"Container expects dict, got {type(j)}")
        kwargs = {}
        for fname, field in typ.model_fields.items():
            if fname not in j:
                raise KeyError(f"Missing field '{fname}' for {typ.__name__}")
            kwargs[fname] = json_to_ssz(j[fname], field.annotation)
        return typ(**kwargs)

    # 2) Byte arrays
    if issubclass(typ, (ByteVector, ByteList)):
        if not isinstance(j, str):
            raise TypeError(f"{typ.__name__} expects 0x-hex string")
        return typ(data=_from_hex(j)) if issubclass(typ, ByteList) else typ(_from_hex(j))

    # 3) Lists/Vectors
    if issubclass(typ, (List, Vector)):
        if not isinstance(j, list):
            raise TypeError(f"{typ.__name__} expects list JSON")
        return typ(data=[json_to_ssz(e, typ.ELEMENT_TYPE) for e in j])

    # 4) Bitfields
    if issubclass(typ, (BitVector, BitList)):
        if not isinstance(j, list) or not all(isinstance(x, bool) for x in j):
            raise TypeError(f"{typ.__name__} expects a JSON list of booleans, e.g. [true, false, ...]")
        return typ(data=j)

    # 5) Basic ints/bools
    if issubclass(typ, BaseUint):
        if not isinstance(j, int):
            raise TypeError(f"{typ.__name__} expects int")
        return typ(int(j))
    if issubclass(typ, Boolean):
        if not isinstance(j, bool):
            if isinstance(j, int) and j in (0, 1):
                return typ(bool(j))
            raise TypeError(f"{typ.__name__} expects bool")
        return typ(j)

    raise TypeError(f"Cannot coerce JSON value {j!r} to {typ}")

def main():
    p = argparse.ArgumentParser(description="Convert JSON to SSZ using pyspec (eth-ssz-specs) types.")
    p.add_argument("--type-module", default="eth_consensus_specs.capella.mainnet", help="Python module path containing the SSZ type (default: eth_consensus_specs.capella.mainnet)")
    p.add_argument("--type", dest="type_name", required=True, help="Type name inside the module (e.g., BeaconState, SignedBeaconBlock)")
    p.add_argument("--in", dest="in_path", required=True, help="Input JSON file path")
    p.add_argument("--out", dest="out_path", required=True, help="Output SSZ file path")
    args = p.parse_args()

    # 1) Load the SSZ type
    mod = importlib.import_module(args.type_module)
    typ = getattr(mod, args.type_name, None)
    if typ is None:
        raise SystemExit(f"Type {args.type_name!r} not found in module {args.type_module!r}")

    # 2) Read JSON
    with open(args.in_path, "r", encoding="utf-8") as f:
        j = json.load(f)

    # 3) Build the SSZ value from JSON
    value = json_to_ssz(j, typ)

    # 4) Serialize to SSZ
    try:
        ssz_bytes = value.encode_bytes()
    except AttributeError:
        raise SystemExit(f"{typ.__name__} instance has no .serialize(); ensure the top-level type is an SSZ container/list/vector, not a bare basic type.")
    with open(args.out_path, "wb") as f:
        f.write(ssz_bytes)

    print(f"OK: wrote {args.out_path}")

if __name__ == "__main__":
    main()
