import importlib
import subprocess
import sys
from contextlib import chdir
from pathlib import Path

from .forks.capella import FORK, PRESET, REVISION


def assemble(source):
    expected = f"CAPELLA_SOURCE must be a consensus-specs checkout at v1.6.0 ({REVISION})."
    revision = subprocess.run(
        ["git", "-C", str(source), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
    )
    if revision.returncode:
        raise SystemExit(f"{expected} {source} is not a git checkout.")
    if revision.stdout.strip() != REVISION:
        raise SystemExit(f"{expected} {source} is at {revision.stdout.strip()}.")
    if subprocess.run(["git", "-C", str(source), "diff", "--quiet", "HEAD"]).returncode:
        raise SystemExit(f"{source} has local changes. Use a clean checkout.")
    sys.path[:0] = [str(source), str(source / "tests/core/pyspec")]
    from pysetup.generate_specs import generate_fork_specs, parse_build_targets
    from pysetup.md_doc_paths import PREVIOUS_FORK_OF

    chain = []
    fork = FORK
    while fork is not None:
        chain.insert(0, fork)
        fork = PREVIOUS_FORK_OF[fork]
    with chdir(source):
        targets = parse_build_targets(f"{PRESET}:presets/{PRESET}:configs/{PRESET}.yaml")
        for fork in chain:
            generate_fork_specs(
                fork, Path("tests/core/pyspec/eth2spec") / fork, targets
            )
    return importlib.import_module(f"eth2spec.{FORK}.{PRESET}")
