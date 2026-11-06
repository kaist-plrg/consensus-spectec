"""Extracts source documents for the Dune translation fixtures."""

import argparse
import ast
import hashlib
import json
from pathlib import Path

from export.document import export_function
from export.load import assemble
from export.metadata.capella import REVIEWED_EFFECTS
from export.provenance import select_sources


def fixture(module, path, mutators):
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
    effects = REVIEWED_EFFECTS.copy()
    REVIEWED_EFFECTS.update(
        {node.name: "state" if node.name in mutators else None for node in nodes}
    )
    try:
        return [
            export_function(
                module, node, str(path), hashlib.sha256(text.encode()).hexdigest()
            )
            for node in nodes
        ]
    finally:
        REVIEWED_EFFECTS.clear()
        REVIEWED_EFFECTS.update(effects)
        for node in nodes:
            delattr(module, node.name)


def write_documents(name, documents):
    directory = Path(f"{name}.sources")
    directory.mkdir(exist_ok=True)
    for path in directory.glob("*.json"):
        path.unlink()
    for document in documents:
        name = document["function"]["name"]
        (directory / f"{name}.json").write_text(json.dumps(document))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("fixtures", type=Path, nargs="+")
    parser.add_argument("--mutator", action="append", default=[])
    args = parser.parse_args()
    source = args.source.resolve()
    if not source.is_dir():
        parser.error("source must be the pinned consensus-specs checkout")
    module, markdown = assemble(source)
    selected = select_sources(
        source, module, markdown, ["compute_epoch_at_slot", "increase_balance"]
    )
    documents = [
        export_function(
            module,
            body.node,
            body.filename,
            body.sha256,
            markdown=(source, markdown),
        )
        for body in selected.values()
    ]
    write_documents("capella", documents)
    for path in args.fixtures:
        write_documents(path.stem, fixture(module, path, args.mutator))


if __name__ == "__main__":
    main()
