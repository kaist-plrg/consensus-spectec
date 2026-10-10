"""Generate the per-fork SSZ schemas the executor merkleizes with.

    python spec/ssz/generate.py            # writes spec/ssz/<fork>-<preset>.json

Runs in the pyspec environment (eth_consensus_specs at the consensus-specs pin). Each
schema holds every container of eth_consensus_specs.<fork>.<preset> in the ssz.schema format,
plus an "x-spectec" member mapping SpecTec struct names to them. Generation fails when a
SpecTec struct's fields differ from its SSZ container's, in name or order.
"""

import importlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ssz" / "scripts"))

import ssz  # noqa: E402
from ssz.layout import field_names  # noqa: E402
from ssz_specs_schema import Schema  # noqa: E402

FORKS = ["capella", "deneb"]
PRESETS = ["minimal", "mainnet"]


def spectec_structs(fork):
    """{name: [FIELD, ...]} for every struct type of spec/spec_<fork>."""
    structs = {}
    for path in sorted((ROOT / "spec" / f"spec_{fork}").glob("*.spectec")):
        text = re.sub(r";;[^\n]*", "", path.read_text())
        for name, body in re.findall(r"syntax\s+(\w+)\s*=\s*\{([^}]*)\}", text):
            structs[name] = [f.split()[0] for f in body.split(",") if f.strip()]
    return structs


def generate(fork, preset):
    spec = importlib.import_module(f"eth_consensus_specs.{fork}.{preset}")
    # A fork reuses the unchanged containers of earlier forks; skip only the library's base class.
    containers = {
        n: t
        for n, t in vars(spec).items()
        if isinstance(t, type) and issubclass(t, ssz.Container) and t.__module__ != "ssz.container"
    }
    schema = Schema(lambda t: t.__name__)
    for name, t in containers.items():
        schema.add(name, t)

    by_lower = {n.lower(): n for n in containers}
    names, errors = {}, []
    for struct, fields in spectec_structs(fork).items():
        ssz_name = by_lower.get(struct.lower())
        if ssz_name is None:
            continue  # a SpecTec-only record, never merkleized
        ssz_fields = [f.upper() for f in field_names(containers[ssz_name])]
        if fields != ssz_fields:
            errors.append(f"{struct} vs {ssz_name}: {fields} != {ssz_fields}")
        names[struct] = ssz_name
    if errors:
        raise SystemExit(f"{fork}/{preset}: field mismatch\n  " + "\n  ".join(errors))

    out = schema.to_json()
    out["x-spectec"] = {"fork": fork, "preset": preset, "types": dict(sorted(names.items()))}
    return out


if __name__ == "__main__":
    for fork in FORKS:
        for preset in PRESETS:
            path = Path(__file__).parent / f"{fork}-{preset}.json"
            out = generate(fork, preset)
            path.write_text(json.dumps(out, indent=1) + "\n")
            n = len(out["x-spectec"]["types"])
            print(f"{path.name}: {len(out['types'])} types, {n} mapped to SpecTec")
