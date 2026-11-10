"""Writes one module document for each Dune translation case."""

import argparse
import ast
import hashlib
import json
from pathlib import Path

from export.document import assembled_document, module_document
from export.load import assemble
from export.selection import translated_functions
from export.forks.capella import ENTRY


def fixture(module, path):
    text = path.read_text()
    nodes = ast.parse(text, filename=str(path)).body
    if not nodes or any(not isinstance(node, ast.FunctionDef) for node in nodes):
        raise ValueError(f"{path}: expected function definitions")
    if any(hasattr(module, node.name) for node in nodes):
        raise ValueError(f"{path}: fixture names must not shadow the specification")
    namespace = vars(module).copy()
    exec(compile(text, str(path), "exec"), namespace)
    for node in nodes:
        setattr(module, node.name, namespace[node.name])
    try:
        return module_document(
            module,
            str(path),
            hashlib.sha256(text.encode()).hexdigest(),
            nodes,
        )
    finally:
        for node in nodes:
            delattr(module, node.name)


def write_document(name, document):
    Path(f"{name}.json").write_text(json.dumps(document))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("fixtures", type=Path, nargs="+")
    args = parser.parse_args()
    source = args.source.resolve()
    if not source.is_dir():
        parser.error("source must be the pinned consensus-specs checkout")
    module = assemble(source)
    write_document(
        "capella",
        assembled_document(
            source, module, ["compute_epoch_at_slot", "increase_balance"]
        ),
    )
    write_document(
        "state-transition",
        assembled_document(source, module, translated_functions(module, [ENTRY])),
    )
    for path in args.fixtures:
        write_document(path.stem, fixture(module, path))


if __name__ == "__main__":
    main()
