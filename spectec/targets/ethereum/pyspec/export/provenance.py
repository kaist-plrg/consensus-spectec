"""Selects reviewed source bodies and their provenance from an assembled fork."""

import ast
import copy
import hashlib
from dataclasses import dataclass
from pathlib import Path

from .error import Unsupported
from .load import python_blocks
from .pyspec import configuration_fields


def configuration_bindings(module, original, assembled):
    if ast.dump(original) == ast.dump(assembled):
        return []
    fields = configuration_fields(module)
    used = {
        item.id
        for item in ast.walk(original)
        if isinstance(item, ast.Name) and isinstance(item.ctx, ast.Load)
    } & fields
    bound = {
        item.id
        for item in ast.walk(original)
        if isinstance(item, ast.Name) and isinstance(item.ctx, ast.Store)
    } | {item.arg for item in ast.walk(original) if isinstance(item, ast.arg)}
    if not used or used & bound or "config" in bound:
        return None

    class Qualify(ast.NodeTransformer):
        def visit_Name(self, node):
            if node.id in used and isinstance(node.ctx, ast.Load):
                return ast.copy_location(
                    ast.Attribute(
                        value=ast.Name(id="config", ctx=ast.Load()),
                        attr=node.id,
                        ctx=ast.Load(),
                    ),
                    node,
                )
            return node

    qualified = Qualify().visit(copy.deepcopy(original))
    return sorted(used) if ast.dump(qualified) == ast.dump(assembled) else None


def optimized_bls_source(source, module, node):
    if node.name != "eth_aggregate_pubkeys":
        raise Unsupported(f"Unreviewed optimized source body {node.name}")
    constants = source / "pysetup/constants.py"
    tree = ast.parse(constants.read_text())
    replacement = next(
        item.value.value
        for item in tree.body
        if isinstance(item, ast.Assign)
        and any(
            isinstance(target, ast.Name)
            and target.id == "OPTIMIZED_BLS_AGGREGATE_PUBKEYS"
            for target in item.targets
        )
    )
    if ast.dump(node) != ast.dump(ast.parse(replacement.strip()).body[0]):
        raise Unsupported(
            "BLS source body does not match the pinned builder replacement"
        )
    builder = source / "pysetup/spec_builders/altair.py"
    original = source / "specs/altair/bls.md"
    filename = str(Path(module.__file__).resolve().relative_to(source.resolve()))
    provenance = {
        str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [constants, builder, original]
    }
    return (
        filename,
        hashlib.sha256(Path(module.__file__).read_bytes()).hexdigest(),
        provenance,
    )



@dataclass(frozen=True)
class SourceBody:
    node: ast.FunctionDef
    filename: str
    sha256: str
    configuration: list[str]
    optimization: dict[str, str] | None = None


def select_sources(source, module, documents, names):
    assembled = {
        node.name: node
        for node in ast.parse(Path(module.__file__).read_text()).body
        if isinstance(node, ast.FunctionDef)
    }
    names = tuple(dict.fromkeys(names))
    missing = set(names) - assembled.keys()
    if missing:
        raise Unsupported(f"Missing assembled source functions: {sorted(missing)}")
    selected = {}
    for document in documents:
        raw = (source / document).read_bytes()
        for start, block in python_blocks(raw.decode()):
            for node in ast.parse(block).body:
                if (
                    not isinstance(node, ast.FunctionDef)
                    or node.name not in names
                    or node.name in selected
                ):
                    continue
                bindings = configuration_bindings(module, node, assembled[node.name])
                if bindings is not None:
                    ast.increment_lineno(node, start - 1)
                    selected[node.name] = SourceBody(
                        node, document, hashlib.sha256(raw).hexdigest(), bindings
                    )
    for name in names:
        if name in selected:
            continue
        if name != "eth_aggregate_pubkeys":
            raise Unsupported(f"No reviewed Markdown provenance for {name}")
        filename, digest, provenance = optimized_bls_source(
            source, module, assembled[name]
        )
        selected[name] = SourceBody(assembled[name], filename, digest, [], provenance)
    return {name: selected[name] for name in names}
