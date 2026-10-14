#!/usr/bin/env python3
"""Check SpecTec's JSON representation without a consensus-specs checkout."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).parent / "SSZToJson.py"

FIXTURE_MODULE = '''
from ssz import Boolean, Uint64, BitList, ByteVector, Container, List


class Root(ByteVector):
    LENGTH = 32


class Bits(BitList):
    LIMIT = 8


class Slots(List[Uint64]):
    LIMIT = 4


class Inner(Container):
    slot: Uint64
    root: Root


class Sample(Container):
    count: Uint64
    flag: Boolean
    bits: Bits
    inner: Inner
    slots: Slots
'''

EXPECTED = {
    "count": 42,
    "flag": True,
    "bits": [True, False, True],
    "inner": {"slot": 7, "root": "0x" + "ab" * 32},
    "slots": [1, 2, 3],
}


def main():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "fixture_types.py").write_text(FIXTURE_MODULE)
        sys.path.insert(0, str(tmp))
        import fixture_types

        env = {**os.environ}
        env["PYTHONPATH"] = os.pathsep.join(filter(None, [str(tmp), env.get("PYTHONPATH")]))

        sample = fixture_types.Sample(
            count=42,
            flag=True,
            bits=fixture_types.Bits(data=[True, False, True]),
            inner=fixture_types.Inner(slot=7, root=fixture_types.Root(b"\xab" * 32)),
            slots=fixture_types.Slots(data=[1, 2, 3]),
        )

        ssz_path = tmp / "sample.ssz"
        json_path = tmp / "sample.json"
        ssz_path.write_bytes(sample.encode_bytes())

        subprocess.run(
            [sys.executable, str(SCRIPT),
             "--type-module", "fixture_types", "--type", "Sample",
             "--in", str(ssz_path), "--out", str(json_path)],
            check=True, capture_output=True, text=True,
            env=env,
        )

        got = json.loads(json_path.read_text())
        assert got == EXPECTED, f"\nexpected {EXPECTED}\ngot      {got}"

        bad = subprocess.run(
            [sys.executable, str(SCRIPT),
             "--type-module", "fixture_types", "--type", "NoSuchType",
             "--in", str(ssz_path), "--out", str(tmp / "bad.json")],
            capture_output=True, text=True,
            env=env,
        )
        assert bad.returncode != 0, "unknown --type should exit non-zero"

    print("ok")


if __name__ == "__main__":
    main()
