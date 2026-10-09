#!/usr/bin/env python3
"""
Check SpecTec against the official consensus-spec test vectors.

  python3 check_spec_tests.py [--jobs N] DIR...

The checker requires the Python packages in requirements.txt and ./spectecx
built by make exe. DIR selects unpacked vectors under Converter/OfficialTestSuite,
for example Converter/OfficialTestSuite/deneb/operations.

Cases with post.ssz_snappy must be accepted with a byte-identical post state.
Cases without a post state must be rejected by failed premises. Interpreter
faults, CLI errors, and input errors fail the check.

Block cases in sanity/blocks, random, and finality apply blocks in order with
full validation. The script exits with status 1 if any case fails. It writes
a summary when GITHUB_STEP_SUMMARY is set.
"""

import argparse
import importlib
import json
import os
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path[:0] = [str(ROOT / "consensus-specs/tests/core/pyspec"),
                str(ROOT / "Converter/SSZToJson"), str(ROOT / "Converter/JsonToSSZ")]
import snappy  # noqa: E402
from JsonToSSZ import json_to_view  # noqa: E402
from SSZToJson import view_to_jsonable  # noqa: E402
from ruamel.yaml import YAML  # noqa: E402

# handler -> (SpecTec task, input file, input SSZ type, SpecTec flag)
OPERATIONS = {
    "attestation": ("attestation", "attestation", "Attestation", "--attestation"),
    "attester_slashing": ("attester-slashing", "attester_slashing", "AttesterSlashing", "--slashing"),
    "proposer_slashing": ("proposer-slashing", "proposer_slashing", "ProposerSlashing", "--slashing"),
    "block_header": ("block-header", "block", "BeaconBlock", "--block"),
    "deposit": ("deposit", "deposit", "Deposit", "--deposit"),
    "voluntary_exit": ("voluntary-exit", "voluntary_exit", "SignedVoluntaryExit", "--exit"),
    "sync_aggregate": ("sync-aggregate", "sync_aggregate", "SyncAggregate", "--aggregate"),
    "execution_payload": ("execution-payload", "body", "BeaconBlockBody", "--payload"),
    "withdrawals": ("withdrawals", "execution_payload", "ExecutionPayload", "--payload"),
    "bls_to_execution_change": ("bls-to-execution-change", "address_change", "SignedBLSToExecutionChange", "--change"),
}
EPOCH = {"justification_and_finalization": "justification", "rewards_and_penalties": "rewards"}
FORKS = ("capella", "deneb")


def yaml(path):
    return YAML(typ="safe").load(path)


def ssz(path):
    return snappy.decompress(path.read_bytes())


def check(case):
    """Return (verdict, detail) for one case directory."""

    fork = next((p for p in case.parts if p in FORKS), None)
    if fork is None:
        raise ValueError(f"no fork ({', '.join(FORKS)}) in the path")
    runner = next((p for p in case.parts if p in ("operations", "epoch_processing")), "blocks")
    handler = case.parts[case.parts.index(runner) + 1] if runner != "blocks" else None

    post = case / "post.ssz_snappy"

    spec = importlib.import_module(f"eth2spec.{fork}.mainnet")

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)

        def to_json(name, typ, data):
            """Write the decoded SSZ input as JSON and return its file path."""
            (tmp / name).write_text(json.dumps(view_to_jsonable(getattr(spec, typ).decode_bytes(data))))
            return str(tmp / name)

        def spectec(*args):
            """Return (post-state SSZ, detail), with None as the state on rejection."""
            out = tmp / "out.json"
            out.unlink(missing_ok=True)

            p = subprocess.run([str(ROOT / "spectecx"), "ethereum", "run", *args,
                                "--spec-dir", str(ROOT / f"spec/spec_{fork}"), "--output", str(out)],
                               capture_output=True, text=True)

            log = p.stderr + p.stdout
            if p.returncode != 0:
                # Failed premises count as rejection. Interpreter faults fail the check.
                if p.returncode != 1 or "source: il-interp" not in log or "il-interp/fault" in log:
                    raise RuntimeError(" ".join(log.split())[-300:])
                return None, " ".join(log.split())[:300]

            return json_to_view(json.loads(out.read_text()), spec.BeaconState).encode_bytes(), ""

        pre = to_json("pre.json", "BeaconState", ssz(case / "pre.ssz_snappy"))
        if runner == "epoch_processing":
            state, err = spectec("epoch", EPOCH.get(handler, handler.replace("_", "-")), "--pre", pre)
        elif runner == "operations":
            task, name, typ, flag = OPERATIONS[handler]
            extra = []
            if handler == "execution_payload":
                valid = yaml(case / "execution.yaml")["execution_valid"]
                (tmp / "execution.json").write_text(json.dumps({"execution_valid": valid}))
                extra = ["--execution", str(tmp / "execution.json")]
            op = to_json(f"{name}.json", typ, ssz(case / f"{name}.ssz_snappy"))
            state, err = spectec("operations", task, "--pre", pre, flag, op, *extra)
        else:
            n = yaml(case / "meta.yaml")["blocks_count"]
            for i in range(n):
                block = to_json("block.json", "SignedBeaconBlock", ssz(case / f"blocks_{i}.ssz_snappy"))
                state, err = spectec("state-transition", "--pre", pre, "--block", block)
                if state is None:
                    err = f"blocks_{i}: {err}"
                    break
                # SpecTec output requires an SSZ roundtrip before use as JSON input.
                pre = to_json("pre.json", "BeaconState", state)

    if not post.exists():
        return ("ok", f"rejected: {err}") if state is None else ("FAIL", "accepted a case without post")
    if state is None:
        return "FAIL", f"rejected: {err}"
    return ("ok", "post matches") if state == ssz(post) else ("FAIL", "post differs")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dirs", nargs="+", type=Path)
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    args = ap.parse_args()
    cases = sorted({p.parent for d in args.dirs for p in d.glob("**/pre.ssz_snappy")})
    if not cases:
        sys.exit(f"no cases under {' '.join(map(str, args.dirs))}; run `make download-fixture` first")

    def run(case):
        t0 = time.time()
        try:
            verdict, detail = check(case)
        except Exception as e:  # a broken case must not stop the others
            verdict, detail = "FAIL", f"{type(e).__name__}: {e}"
        name = str(case)
        print(f"{verdict:4} {time.time() - t0:6.0f}s  {name}: {detail}", flush=True)
        return name, verdict, detail

    t0 = time.time()
    with ThreadPoolExecutor(args.jobs) as ex:
        results = list(ex.map(run, cases))
    fails = [r for r in results if r[1] != "ok"]
    summary = f"{len(results) - len(fails)}/{len(results)} cases pass ({time.time() - t0:.0f}s)"
    print(summary)

    # GitHub Actions displays this Markdown on the workflow run page.
    # Ref: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#adding-a-job-summary
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(f"**{summary}**\n\n")
            if fails:
                f.write("| case | result |\n|---|---|\n")
                f.writelines(f"| `{name}` | {detail} |\n" for name, _, detail in fails)

    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
