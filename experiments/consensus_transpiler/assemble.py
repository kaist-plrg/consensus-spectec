import hashlib
import importlib
import subprocess
import sys
from contextlib import chdir
from importlib.metadata import version
from pathlib import Path

REVISION = "477321355d48d527e7e1e4d572f6a40a0b41072a"


def assemble(source, preset):
    source = source.resolve()
    actual = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True
    ).strip()
    if actual != REVISION:
        raise ValueError(f"Expected consensus-specs {REVISION}, found {actual}")
    subprocess.run(
        ["git", "-C", str(source), "diff", "--exit-code", "HEAD"],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    sys.path.insert(0, str(source))
    sys.path.insert(0, str(source / "tests/core/pyspec"))
    from pysetup.generate_specs import generate_fork_specs, parse_build_targets
    from pysetup.md_doc_paths import PREVIOUS_FORK_OF, get_md_doc_paths

    with chdir(source):
        chain = []
        fork = "gloas"
        while fork is not None:
            chain.insert(0, fork)
            fork = PREVIOUS_FORK_OF[fork]
        targets = parse_build_targets(
            "minimal:presets/minimal:configs/minimal.yaml "
            "mainnet:presets/mainnet:configs/mainnet.yaml"
        )
        for fork in chain:
            generate_fork_specs(
                fork, Path("tests/core/pyspec/eth_consensus_specs") / fork, targets
            )
        markdown = get_md_doc_paths("gloas").split()
    inputs = set(markdown) | {"uv.lock", "pyproject.toml"}
    for directory, pattern in [
        ("pysetup", "*.py"),
        ("presets", "*"),
        ("configs", "*.yaml"),
    ]:
        inputs.update(
            path.relative_to(source).as_posix()
            for path in (source / directory).rglob(pattern)
            if path.is_file()
        )
    inputs = {path for path in inputs if "__pycache__" not in path}
    manifest = {
        "revision": actual,
        "fork": "gloas",
        "preset": preset,
        "fork_chain": chain,
        "markdown_order": markdown,
        "input_sha256": {
            path: hashlib.sha256((source / path).read_bytes()).hexdigest()
            for path in sorted(inputs)
        },
        "python_version": sys.version,
        "ssz_version": version("eth-ssz-specs"),
    }
    module = importlib.import_module(f"eth_consensus_specs.gloas.{preset}")
    manifest["generated_sha256"] = hashlib.sha256(
        Path(module.__file__).read_bytes()
    ).hexdigest()
    return module, manifest
