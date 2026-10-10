"""Flatten consensus-spec-tests ssz_static cases into JSONL for the SSZ checks.

    python spec/ssz/build_static.py <fixture dir> <preset> <out dir>

<fixture dir> is the tree of `make download-fixture SPEC_TESTS_SUITES=ssz_static`. Writes
<out>/<fork>-<preset>.jsonl, one {"id", "type", "value", "root"} line per case, for every
fork with ssz_static cases. "value" is value.yaml as JSON (the ssz.schema convention).
Cases whose type SpecTec also defines carry "spectec": serialized.ssz_snappy decoded with
eth_consensus_specs and rendered by the Converter, i.e. the JSON the executor reads its inputs from.
"""

import importlib
import json
import sys
from pathlib import Path

import snappy
import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Converter" / "SSZToJson"))
from SSZToJson import ssz_to_json  # noqa: E402

LOADER = getattr(yaml, "CSafeLoader", yaml.SafeLoader)


def cases(root, preset, fork):
    spec = importlib.import_module(f"eth_consensus_specs.{fork}.{preset}")
    schema = json.loads((Path(__file__).parent / f"{fork}-{preset}.json").read_text())
    spectec = set(schema["x-spectec"]["types"].values())
    static = root / fork / "ssz_static"
    for type_dir in sorted(static.iterdir()):
        for case in sorted(type_dir.glob("*/*")):
            with open(case / "value.yaml") as f:
                value = yaml.load(f, Loader=LOADER)
            with open(case / "roots.yaml") as f:
                root_hex = yaml.load(f, Loader=LOADER)["root"]
            line = {
                "id": str(case.relative_to(static)),
                "type": type_dir.name,
                "value": value,
                "root": root_hex,
            }
            if type_dir.name in spectec:
                raw = snappy.decompress((case / "serialized.ssz_snappy").read_bytes())
                line["spectec"] = ssz_to_json(getattr(spec, type_dir.name).decode_bytes(raw))
            yield line


if __name__ == "__main__":
    root, preset, out = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    for fork_dir in sorted(p for p in root.iterdir() if (p / "ssz_static").is_dir()):
        path = out / f"{fork_dir.name}-{preset}.jsonl"
        with open(path, "w") as f:
            n = sum(f.write(json.dumps(c) + "\n") > 0 for c in cases(root, preset, fork_dir.name))
        print(f"{path}: {n} cases")
