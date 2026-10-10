"""Flatten the ssz-specs test vectors into JSONL cases for test/run_vectors.exe.

Each output line is {"id", "type", "value", "root"}: "type" is a name from
<out>/ssz_specs.json (scripts/ssz_specs_schema.py), "value" follows the ssz.schema value
convention.
Only valid cases are kept; invalid ones test decoding, which is out of scope.

    python build_vectors.py --ssz-specs <dir>/fixtures/ssz/ssz --out _vectors
"""

import argparse
import json
import os
from pathlib import Path

# ssz-specs values wrap every collection as {"data": ...}; unwrap them by type.
def unwrap(t, v, types):
    while isinstance(t, str) and t in types:
        t = types[t]
    if isinstance(t, str):
        return v.get("data", v) if isinstance(v, dict) else v
    (kind, arg), = t.items()
    if kind in ("container", "progressive_container"):
        fields = arg if kind == "container" else arg["fields"]
        return {n: unwrap(ft, v[n], types) for n, ft in fields}
    if kind == "compatible_union":
        opt = dict((sel, ot) for sel, ot in arg)[v["selector"]]
        return {"selector": v["selector"], "data": unwrap(opt, v["data"], types)}
    if isinstance(v, dict):
        v = v["data"]
    if kind in ("vector", "list", "progressive_list") and isinstance(v, list):
        elem = arg[0] if kind != "progressive_list" else arg
        return [unwrap(elem, e, types) for e in v]
    return v


def ssz_specs_cases(root, types):
    for path in sorted(Path(root).rglob("*.json")):
        for key, case in json.loads(path.read_text()).items():
            if "rejectionReason" in case:
                continue
            module = key.split("::")[0].rsplit("/", 1)[-1].removesuffix(".py")
            name = f"{module}.{case['typeName']}"
            yield {
                "id": key,
                "type": name,
                "value": unwrap(name, case["value"], types),
                "root": case["root"],
            }


def write(path, cases):
    n = 0
    with open(path, "w") as f:
        for c in cases:
            f.write(json.dumps(c) + "\n")
            n += 1
    print(f"{path}: {n} cases")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--ssz-specs", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    types = json.loads(Path(args.out, "ssz_specs.json").read_text())["types"]
    write(Path(args.out, "ssz_specs.jsonl"), ssz_specs_cases(args.ssz_specs, types))
