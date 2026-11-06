import importlib
import re
import subprocess
import sys
from contextlib import chdir
from pathlib import Path

from .metadata.capella import FORK, PRESET, REVISION


def assemble(source):
    revision = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True
    ).strip()
    if revision != REVISION:
        raise ValueError(
            f"Expected the repository's consensus-specs pin {REVISION}, found {revision}"
        )
    subprocess.run(
        ["git", "-C", str(source), "diff", "--exit-code", "HEAD"],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    sys.path[:0] = [str(source), str(source / "tests/core/pyspec")]
    from pysetup.generate_specs import generate_fork_specs, parse_build_targets
    from pysetup.md_doc_paths import PREVIOUS_FORK_OF, get_md_doc_paths

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
        documents = get_md_doc_paths(FORK).split()
    module = importlib.import_module(f"eth2spec.{FORK}.{PRESET}")
    return module, documents


def python_blocks(text):
    marker = None
    language = None
    start = None
    contents = []
    for line_number, line in enumerate(text.splitlines(), 1):
        fence = re.fullmatch(r" {0,3}(`{3,}|~{3,})(.*)", line)
        if marker is None:
            if fence:
                marker = fence[1]
                language = fence[2].strip()
                start = line_number + 1
                contents = []
        elif (
            fence
            and fence[1][0] == marker[0]
            and len(fence[1]) >= len(marker)
            and not fence[2].strip()
        ):
            if language == "python":
                yield start, "\n".join(contents) + "\n"
            marker = None
        else:
            contents.append(line)
    if marker is not None and language == "python":
        raise ValueError(f"Unterminated Python fence at line {start - 1}")
