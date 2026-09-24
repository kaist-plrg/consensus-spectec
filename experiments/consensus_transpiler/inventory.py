import argparse
import ast
import hashlib
import json
import re
import subprocess
from collections import Counter
from pathlib import Path

DECISIONS = {
    "source_assembly": "Choose the source revision and resolve inherited fork definitions, overrides, removals, and presets.",
    "numeric_semantics": "Preserve integer widths, overflow, underflow, casts, and bitwise operations.",
    "collection_semantics": "Preserve collection capacity, ordering, uniqueness, slicing, and invalid indexing.",
    "mutation": "Choose the representation of state updates, object aliasing, and mutation through calls.",
    "control_flow": "Choose lowering for loops, early returns, break, and continue.",
    "failure": "Preserve assertions and exceptions as invalid transitions.",
    "external_calls": "Resolve function dependencies and define contracts for cryptography, SSZ, and the execution engine.",
    "type_mapping": "Define target representations for annotations, containers, protocols, and optional values.",
    "evaluation_order": "Preserve short-circuit evaluation and the order of potentially failing expressions.",
}


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


def node_decisions(node):
    decisions = set()
    if isinstance(node, (ast.BinOp, ast.AugAssign)):
        decisions.add("numeric_semantics")
    if isinstance(node, ast.UnaryOp) and isinstance(
        node.op, (ast.Invert, ast.USub, ast.UAdd)
    ):
        decisions.add("numeric_semantics")
    if isinstance(
        node,
        (
            ast.Subscript,
            ast.List,
            ast.Set,
            ast.Dict,
            ast.ListComp,
            ast.SetComp,
            ast.DictComp,
            ast.GeneratorExp,
        ),
    ):
        decisions.add("collection_semantics")
    if isinstance(
        node,
        (ast.For, ast.While, ast.Break, ast.Continue, ast.If, ast.IfExp, ast.Match),
    ):
        decisions.add("control_flow")
    if isinstance(node, (ast.Assert, ast.Raise, ast.Try)):
        decisions.add("failure")
    if isinstance(node, ast.Call):
        decisions.add("external_calls")
    if isinstance(node, (ast.ClassDef, ast.AnnAssign)):
        decisions.add("type_mapping")
    if (
        isinstance(node, ast.BoolOp)
        or isinstance(node, ast.Compare)
        and len(node.ops) > 1
    ):
        decisions.add("evaluation_order")
    targets = []
    if isinstance(node, ast.Assign):
        targets = node.targets
    elif isinstance(node, (ast.AnnAssign, ast.AugAssign)):
        targets = [node.target]
    elif isinstance(node, ast.Delete):
        targets = node.targets
    if any(
        isinstance(part, (ast.Attribute, ast.Subscript))
        for target in targets
        for part in ast.walk(target)
    ):
        decisions.add("mutation")
    return decisions


def describe_definition(node, path, block_start, source):
    counts = Counter(type(part).__name__ for part in ast.walk(node))
    decisions = {"source_assembly", "type_mapping"}
    evidence = {}
    for part in ast.walk(node):
        for decision in node_decisions(part):
            decisions.add(decision)
            evidence.setdefault(decision, block_start + part.lineno - 1)
    calls = sorted(
        {
            ast.unparse(part.func)
            for part in ast.walk(node)
            if isinstance(part, ast.Call)
        }
    )
    annotations = sorted(
        {
            ast.unparse(part.annotation)
            for part in ast.walk(node)
            if isinstance(part, (ast.arg, ast.AnnAssign))
            and part.annotation is not None
        }
    )
    if (
        isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        and node.returns is not None
    ):
        annotations = sorted(set(annotations) | {ast.unparse(node.returns)})
    return {
        "name": node.name,
        "kind": type(node).__name__,
        "path": path,
        "line": block_start + node.lineno - 1,
        "end_line": block_start + node.end_lineno - 1,
        "source_sha256": hashlib.sha256(
            ast.get_source_segment(source, node).encode()
        ).hexdigest(),
        "annotations": annotations,
        "calls": calls,
        "ast_nodes": dict(sorted(counts.items())),
        "decision_points": sorted(decisions),
        "evidence_lines": evidence,
        "translation_status": "not_attempted",
    }


def inspect_files(root, paths):
    definitions = []
    files = []
    errors = []
    other_statements = []
    for path in paths:
        relative = path.relative_to(root).as_posix()
        raw = path.read_bytes()
        count = 0
        try:
            for start, source in python_blocks(raw.decode()):
                count += 1
                try:
                    tree = ast.parse(source, filename=relative)
                except SyntaxError as error:
                    errors.append(
                        {
                            "path": relative,
                            "line": start + (error.lineno or 1) - 1,
                            "message": error.msg,
                        }
                    )
                    continue
                for node in tree.body:
                    if isinstance(
                        node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)
                    ):
                        definitions.append(
                            describe_definition(node, relative, start, source)
                        )
                    else:
                        other_statements.append(
                            {
                                "path": relative,
                                "line": start + node.lineno - 1,
                                "kind": type(node).__name__,
                            }
                        )
        except (ValueError, UnicodeDecodeError) as error:
            errors.append({"path": relative, "message": str(error)})
        files.append(
            {
                "path": relative,
                "sha256": hashlib.sha256(raw).hexdigest(),
                "python_blocks": count,
            }
        )
    names = Counter(item["name"] for item in definitions)
    return {
        "scope": "Markdown Python blocks only. Fork inheritance is not resolved. Tables, presets, prose constraints, and builder transformations are not interpreted.",
        "files": files,
        "definitions": definitions,
        "duplicate_names": sorted(name for name, count in names.items() if count > 1),
        "other_top_level_statements": other_statements,
        "errors": errors,
        "decision_catalog": DECISIONS,
        "summary": {
            "files": len(files),
            "python_blocks": sum(item["python_blocks"] for item in files),
            "functions": sum(
                item["kind"] in {"FunctionDef", "AsyncFunctionDef"}
                for item in definitions
            ),
            "classes": sum(item["kind"] == "ClassDef" for item in definitions),
            "definitions_by_decision": {
                key: sum(key in item["decision_points"] for item in definitions)
                for key in DECISIONS
            },
            "translated": 0,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Inventory consensus-spec Python blocks and translation decision points."
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("--fork", required=True)
    parser.add_argument(
        "--revision", required=True, help="Expected exact source Git commit"
    )
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.source.resolve()
    revision = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()
    if revision != args.revision:
        parser.error(f"Source revision is {revision}, expected {args.revision}")
    if not re.fullmatch(r"[a-z0-9_-]+", args.fork):
        parser.error("Fork must be a directory name")
    paths = sorted((root / "specs" / args.fork).rglob("*.md"))
    if not paths:
        parser.error(f"No Markdown files for fork {args.fork}")
    report = inspect_files(root, paths)
    report["source"] = {
        "revision": revision,
        "fork": args.fork,
        "working_tree_status": subprocess.check_output(
            [
                "git",
                "-C",
                str(root),
                "status",
                "--porcelain",
                "--",
                "specs/" + args.fork,
            ],
            text=True,
        ).splitlines(),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report["summary"], indent=2))
    return 1 if report["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
