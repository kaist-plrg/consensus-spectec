#!/usr/bin/env python3
"""Check SSZ byte preservation and JSON rejection without consensus-specs."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

JSON_TO_SSZ = Path(__file__).parent / "JsonToSSZ.py"
SSZ_TO_JSON = Path(__file__).parent.parent / "SSZToJson" / "SSZToJson.py"

FIXTURE_MODULE = '''
from remerkleable.basic import boolean, uint64
from remerkleable.bitfields import Bitlist
from remerkleable.byte_arrays import ByteVector
from remerkleable.complex import Container, List

Root = ByteVector[32]


class Inner(Container):
    slot: uint64
    root: Root


class Sample(Container):
    count: uint64
    flag: boolean
    bits: Bitlist[8]
    inner: Inner
    slots: List[uint64, 4]
'''


def run(script, tmp, env, *args):
    return subprocess.run(
        [sys.executable, str(script), "--type-module", "fixture_types", *args],
        capture_output=True, text=True, env=env,
    )


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
            bits=fixture_types.Bitlist[8](True, False, True),
            inner=fixture_types.Inner(slot=7, root=fixture_types.Root(b"\xab" * 32)),
            slots=fixture_types.List[fixture_types.uint64, 4](1, 2, 3),
        )

        original = tmp / "original.ssz"
        as_json = tmp / "sample.json"
        roundtripped = tmp / "roundtripped.ssz"
        original.write_bytes(sample.encode_bytes())

        r = run(SSZ_TO_JSON, tmp, env, "--type", "Sample", "--in", str(original), "--out", str(as_json))
        assert r.returncode == 0, f"SSZToJson failed:\n{r.stderr}"
        r = run(JSON_TO_SSZ, tmp, env, "--type", "Sample", "--in", str(as_json), "--out", str(roundtripped))
        assert r.returncode == 0, f"JsonToSSZ failed:\n{r.stderr}"

        assert roundtripped.read_bytes() == original.read_bytes(), (
            f"round-trip changed the bytes\n"
            f"  before {original.read_bytes().hex()}\n"
            f"  after  {roundtripped.read_bytes().hex()}"
        )

        # SpecTec represents bitfields as lists of booleans.
        assert json.loads(as_json.read_text())["bits"] == [True, False, True]

        # remerkleable's to_obj() represents bitfields as hex strings.
        hex_bits = json.loads(as_json.read_text())
        hex_bits["bits"] = "0x0d"
        bad_json = tmp / "hex_bits.json"
        bad_json.write_text(json.dumps(hex_bits))
        r = run(JSON_TO_SSZ, tmp, env, "--type", "Sample", "--in", str(bad_json), "--out", str(tmp / "bad.ssz"))
        assert r.returncode != 0, "hex-spelled bitfield should be rejected"

        r = run(JSON_TO_SSZ, tmp, env, "--type", "NoSuchType", "--in", str(as_json), "--out", str(tmp / "bad2.ssz"))
        assert r.returncode != 0, "unknown --type should exit non-zero"

    print("ok")


if __name__ == "__main__":
    main()
