import concurrent.futures
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path


launcher = Path(sys.argv[1]).resolve()
generator = launcher.parent / "spectec/scripts/make-launcher.sh"
environment = dict(
    os.environ,
    DUNE_DIR_LOCATIONS="sites with a ' quote",
    DUNE_OCAML_STDLIB="stdlib",
    DUNE_OCAML_HARDCODED="runtime",
    DUNE_SOURCEROOT="source",
    OCAMLPATH="libraries with spaces",
    CAML_LD_LIBRARY_PATH="stubs",
)
script = subprocess.check_output(
    ["sh", str(generator), "switch with a ' quote", "/binary with spaces"],
    env=environment,
    text=True,
)
arguments = shlex.split(script.splitlines()[1])
assert arguments == [
    "exec", "opam", "exec", "--switch=switch with a ' quote", "--", "env",
    "DUNE_DIR_LOCATIONS=sites with a ' quote", "DUNE_OCAML_STDLIB=stdlib",
    "DUNE_OCAML_HARDCODED=runtime", "DUNE_SOURCEROOT=source",
    "OCAMLPATH=libraries with spaces",
    "CAML_LD_LIBRARY_PATH=stubs", "/binary with spaces", "$@",
]

with tempfile.TemporaryDirectory(prefix="spectec launcher ") as directory:
    def run(_):
        return subprocess.run(
            [str(launcher), "ethereum", "--help"],
            cwd=directory, text=True, capture_output=True, timeout=30,
        )

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for result in pool.map(run, range(8)):
            assert result.returncode == 0, result.stderr
            assert "Ethereum commands" in result.stdout + result.stderr

    (Path(directory) / "spectecx.config").write_text("ethereum.spec_dir = missing-spec\n")
    result = subprocess.run(
        [str(launcher), "ethereum", "run", "state-transition", "--fork", "capella", "--color", "never"],
        cwd=directory, text=True, capture_output=True, timeout=30,
    )
    assert result.returncode == 1
    assert "spec directory missing-spec does not exist" in result.stderr

print("Launcher quoting and concurrent plugin discovery passed")
