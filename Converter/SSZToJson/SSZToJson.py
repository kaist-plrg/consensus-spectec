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

def _to_hex(b: bytes) -> str:
    return "0x" + b.hex()

def bitfield_to_bool_list(v):
    return [bool(b) for b in v]


def ssz_to_json(v: Any) -> Any:
    # 1) Container
    if isinstance(v, Container):
        out = {}
        for fname in type(v).model_fields:
            sub = getattr(v, fname)
            out[fname] = ssz_to_json(sub)
        return out

    # 2) Vectors/Lists (of anything)
    if isinstance(v, (Vector, List)):
        return [ssz_to_json(e) for e in v]

    # 3) Byte arrays → hex
    if isinstance(v, (ByteVector, ByteList)):
        return _to_hex(bytes(v))

    # 4) Bitfields → bit value
    if isinstance(v, (BitVector, BitList)):
        return bitfield_to_bool_list(v)

    # 5) Basic ints/bools
    if isinstance(v, BaseUint):
        # Cast to Python int
        return int(v)
    if isinstance(v, Boolean):
        return bool(v)

    # 6) Raw Python primitives (int/bytes/str/bool)
    if isinstance(v, (int, bool)):
        return v
    if isinstance(v, (bytes, bytearray, memoryview)):
        return _to_hex(bytes(v))
    if v is None:
        return None

    # An unknown SSZ type (e.g. a progressive type of a later fork) must not turn into str(v)
    raise TypeError(f"Cannot render {type(v).__name__} as JSON")

def main():
    p = argparse.ArgumentParser(description="Convert SSZ to JSON using pyspec (eth-ssz-specs) types.")
    p.add_argument("--type-module", default="eth_consensus_specs.capella.mainnet", help="Python module path containing the SSZ type (default: eth_consensus_specs.capella.mainnet)")
    p.add_argument("--type", dest="type_name", required=True, help="Type name inside the module (e.g., BeaconState, SignedBeaconBlock, Attestation)")
    p.add_argument("--in", dest="in_path", required=True, help="Input SSZ file path")
    p.add_argument("--out", dest="out_path", required=True, help="Output JSON file path")
    args = p.parse_args()

    # 1) Load type
    mod = importlib.import_module(args.type_module)
    typ = getattr(mod, args.type_name, None)
    if typ is None:
        raise SystemExit(f"Type {args.type_name!r} not found in module {args.type_module!r}")

    # 2) Read SSZ bytes
    with open(args.in_path, "rb") as f:
        ssz_bytes = f.read()

    # 3) Deserialize: use decode_bytes class method
    try:
        value = typ.decode_bytes(ssz_bytes)
    except Exception as e:
        raise SystemExit(f"Failed to deserialize SSZ as {args.type_name}: {e}")
    py_obj = ssz_to_json(value)

    # Dump JSON
    with open(args.out_path, "w", encoding="utf-8") as f:
        json.dump(py_obj, f, ensure_ascii=False, indent=2)

    print(f"OK: wrote {args.out_path}")

if __name__ == "__main__":
    main()
