import argparse
import ast
import hashlib
import importlib
import importlib.metadata
import inspect
import json
import re
import subprocess
import sys
from contextlib import chdir
from dataclasses import dataclass, field
from pathlib import Path

from capella_interfaces import (
    REVIEWED_EFFECTS,
    Unsupported,
    interfaces,
    read_overrides,
    type_name,
)
from inventory import python_blocks

REVISION = "f96d3e7acf35125295d234da4b0c67591fdef49c"
READ_ONLY_CALLS = {
    name for name, state in REVIEWED_EFFECTS.items() if state is None
} | {"compute_epoch_at_slot", "get_current_epoch"}


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
    fork = "capella"
    while fork is not None:
        chain.insert(0, fork)
        fork = PREVIOUS_FORK_OF[fork]
    with chdir(source):
        targets = parse_build_targets("mainnet:presets/mainnet:configs/mainnet.yaml")
        for fork in chain:
            generate_fork_specs(
                fork, Path("tests/core/pyspec/eth2spec") / fork, targets
            )
        documents = get_md_doc_paths("capella").split()
    module = importlib.import_module("eth2spec.capella.mainnet")
    return module, documents


def width(kind):
    from remerkleable.basic import uint

    return (
        kind.type_byte_length() * 8
        if isinstance(kind, type) and issubclass(kind, uint)
        else None
    )


def calc(text):
    return text[1:] if text.startswith("$(") else text


def index_text(text):
    return text[2:-1] if text.startswith("$(") else text


@dataclass(frozen=True)
class Term:
    text: str
    kind: type


@dataclass
class PathState:
    environment: dict
    premises: list = field(default_factory=list)
    reads: dict = field(default_factory=dict)

    def copy(self):
        return PathState(dict(self.environment), list(self.premises), dict(self.reads))

    def require(self, text, node, reason):
        if not any(premise["condition"] == text for premise in self.premises):
            self.premises.append(
                {"condition": text, "source_line": node.lineno, "reason": reason}
            )


class Lowerer:
    def __init__(self, module, target_text, overrides=None):
        self.module = module
        self.interfaces = interfaces(module, target_text, overrides)
        self.target_text = target_text
        self.constants = {}
        self.dependencies = set()
        self.next_variable = 0
        self.reserved_variables = set()
        self.local_names = set()

    def bind(self, term, path, node, hint=None):
        target = type_name(term.kind)
        prefix = target.rstrip("*")
        iteration = target[len(prefix) :]
        while True:
            name = f"{hint or prefix}_transpiled{self.next_variable}"
            self.next_variable += 1
            if name not in self.reserved_variables:
                self.reserved_variables.add(name)
                break
        name += iteration
        path.require(f"{term.text} = {name}", node, "binding")
        return Term(name, term.kind)

    def constant(self, name):
        value = getattr(self.module, name)
        match = re.search(rf"^def \${name} = (\d+)\s*$", self.target_text, re.MULTILINE)
        if not match or int(match[1]) != int(value):
            raise Unsupported(
                f"Constant {name} does not have a matching literal in the reference"
            )
        self.constants[name] = int(value)
        return Term("$" + name, type(value))

    def arithmetic(self, operator, left, right, path, node):
        bits = width(left.kind) or width(right.kind)
        kind = left.kind if width(left.kind) else right.kind
        if bits and bits != 64:
            raise Unsupported(f"Inline guard policy for uint{bits} is not established")
        if isinstance(operator, ast.Add):
            if bits:
                path.require(
                    f"$({calc(left.text)} <= $UINT64_MAX - {calc(right.text)})",
                    node,
                    "overflow",
                )
            symbol = "+"
        elif isinstance(operator, ast.Sub):
            if bits:
                path.require(
                    f"$({calc(right.text)} <= {calc(left.text)})", node, "underflow"
                )
            symbol = "-"
        elif isinstance(operator, (ast.Mod, ast.FloorDiv)):
            if right.text not in {
                "$" + name for name, value in self.constants.items() if value > 0
            }:
                path.require(f"{right.text} =/= 0", node, "zero_divisor")
            symbol = "\\" if isinstance(operator, ast.Mod) else "/"
        else:
            raise Unsupported(f"Arithmetic {type(operator).__name__}")
        return Term(f"$({calc(left.text)} {symbol} {calc(right.text)})", kind)

    def expression(self, node, path):
        if isinstance(node, ast.IfExp):
            return [
                (branch, term)
                for truth, expression in [(True, node.body), (False, node.orelse)]
                for branch in self.condition(node.test, truth, path.copy())
                for branch, term in self.expression(expression, branch)
            ]
        if (
            isinstance(node, (ast.Compare, ast.BoolOp))
            or isinstance(node, ast.UnaryOp)
            and isinstance(node.op, ast.Not)
        ):
            return [
                (branch, Term(str(truth).lower(), bool))
                for truth in [True, False]
                for branch in self.condition(node, truth, path.copy())
            ]
        if isinstance(node, ast.Name):
            if node.id in path.environment:
                return [(path, path.environment[node.id])]
            if node.id in self.local_names:
                raise Unsupported(f"Read before local assignment: {node.id}")
            return [(path, self.constant(node.id))]
        if isinstance(node, ast.Constant) and type(node.value) in (int, bool):
            return [(path, Term(str(node.value).lower(), type(node.value)))]
        if isinstance(node, ast.List) and not node.elts:
            return [(path, Term("eps", list))]
        if isinstance(node, ast.Attribute):
            result = []
            for branch, base in self.expression(node.value, path):
                if (
                    not hasattr(base.kind, "fields")
                    or node.attr not in base.kind.fields()
                ):
                    raise Unsupported(f"Unknown field {node.attr}")
                result.append(
                    (
                        branch,
                        Term(
                            f"{base.text}.{node.attr.upper()}",
                            base.kind.fields()[node.attr],
                        ),
                    )
                )
            return result
        if isinstance(node, ast.Subscript):
            result = []
            for sequence_path, sequence in self.expression(node.value, path):
                for branch, index in self.expression(node.slice, sequence_path):
                    if not hasattr(sequence.kind, "element_cls"):
                        raise Unsupported("Indexing a non-SSZ sequence")
                    key = f"{sequence.text}[{index_text(index.text)}]"
                    if key not in branch.reads:
                        branch.require(
                            f"$({calc(index.text)} < |{sequence.text}|)",
                            node,
                            "index_bounds",
                        )
                        element = Term(key, sequence.kind.element_cls())
                        branch.reads[key] = self.bind(
                            element,
                            branch,
                            node,
                            "balance" if element.kind is self.module.Gwei else None,
                        )
                    result.append((branch, branch.reads[key]))
            return result
        if isinstance(node, ast.BinOp):
            return [
                (branch, self.arithmetic(node.op, left, right, branch, node))
                for branch, left in self.expression(node.left, path)
                for branch, right in self.expression(node.right, branch)
            ]
        if (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and not node.keywords
        ):
            if node.func.id in self.local_names:
                raise Unsupported(f"Calls through locally bound names: {node.func.id}")
            function = getattr(self.module, node.func.id, None)
            if isinstance(function, type) and width(function):
                if len(node.args) != 1:
                    raise Unsupported("Numeric cast arity")
                values = self.expression(node.args[0], path)
                if any(width(value.kind) != width(function) for _, value in values):
                    raise Unsupported(
                        "Narrowing or unbounded casts need explicit contracts"
                    )
                return [
                    (branch, Term(value.text, function)) for branch, value in values
                ]
            if not inspect.isfunction(function):
                raise Unsupported(f"Unresolved call {node.func.id}")
            if node.func.id not in READ_ONLY_CALLS:
                raise Unsupported(f"Call effects are not reviewed for {node.func.id}")
            if not re.search(
                rf"^dec \${node.func.id}\(", self.target_text, re.MULTILINE
            ):
                raise Unsupported(
                    f"No handwritten function interface for {node.func.id}"
                )
            self.dependencies.add(node.func.id)
            combinations = [(path, [])]
            for arg in node.args:
                combinations = [
                    (branch, values + [value])
                    for branch, values in combinations
                    for branch, value in self.expression(arg, branch)
                ]
            kind = inspect.signature(function).return_annotation
            return [
                (
                    branch,
                    Term(
                        f"${node.func.id}({', '.join(value.text for value in values)})",
                        kind,
                    ),
                )
                for branch, values in combinations
            ]
        raise Unsupported(
            f"Expression {type(node).__name__} at line {getattr(node, 'lineno', 0)}"
        )

    def condition(self, node, desired, path):
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            return self.condition(node.operand, not desired, path)
        if isinstance(node, ast.BoolOp):
            all_required = desired == isinstance(node.op, ast.And)
            live, done = [path], []
            for value in node.values:
                if not all_required:
                    done += [
                        branch
                        for live_path in live
                        for branch in self.condition(value, desired, live_path.copy())
                    ]
                live = [
                    branch
                    for live_path in live
                    for branch in self.condition(
                        value,
                        desired if all_required else not desired,
                        live_path.copy(),
                    )
                ]
            return live if all_required else done
        if isinstance(node, ast.Compare):
            operators = {
                ast.Eq: ("=", "=/="),
                ast.NotEq: ("=/=", "="),
                ast.Lt: ("<", ">="),
                ast.LtE: ("<=", ">"),
                ast.Gt: (">", "<="),
                ast.GtE: (">=", "<"),
            }
            live = self.expression(node.left, path)
            done = []
            for operator, other in zip(node.ops, node.comparators):
                if type(operator) not in operators:
                    raise Unsupported("Membership and identity comparisons")
                following = []
                for live_path, left in live:
                    for branch, right in self.expression(other, live_path):
                        for truth in [True] if desired else [False, True]:
                            item = branch.copy()
                            symbol = operators[type(operator)][0 if truth else 1]
                            text = f"{left.text} {symbol} {right.text}"
                            if symbol not in ("=", "=/="):
                                text = (
                                    f"$({calc(left.text)} {symbol} {calc(right.text)})"
                                )
                            item.require(text, node, "path_condition")
                            if truth:
                                following.append((item, right))
                            else:
                                done.append(item)
                live = following
            return [branch for branch, _ in live] if desired else done
        result = []
        for branch, value in self.expression(node, path):
            if value.kind not in (bool, self.module.boolean):
                raise Unsupported("Non-boolean truthiness")
            branch.require(
                value.text if desired else f"~{value.text}", node, "path_condition"
            )
            result.append(branch)
        return result

    def store(self, node, value, path):
        if isinstance(node, ast.Name):
            if node.id == "state" or value.kind is self.module.BeaconState:
                raise Unsupported("Saving or rebinding the mutable root state")
            path.environment[node.id] = self.bind(value, path, node)
            return path
        if (
            isinstance(node, ast.Attribute)
            and isinstance(node.value, ast.Name)
            and node.value.id == "state"
        ):
            suffix = f".{node.attr.upper()}"
        elif (
            isinstance(node, ast.Subscript)
            and isinstance(node.value, ast.Attribute)
            and isinstance(node.value.value, ast.Name)
            and node.value.value.id == "state"
        ):
            indices = self.expression(node.slice, path)
            if len(indices) != 1:
                raise Unsupported("Branching assignment index")
            path, index = indices[0]
            sequence = path.environment["state"].text + "." + node.value.attr.upper()
            path.require(f"$({index.text} < |{sequence}|)", node, "index_bounds")
            suffix = f".{node.value.attr.upper()}[{index_text(index.text)}]"
        else:
            raise Unsupported("Mutation through an alias or nested record")
        state = path.environment["state"]
        path.environment["state"] = Term(
            f"{state.text}[{suffix} = {value.text}]", state.kind
        )
        path.reads.clear()
        return path

    def statements(self, nodes, path, mutator):
        if not nodes:
            if mutator:
                return [(path, path.environment["state"])]
            raise Unsupported("Implicit None return in a function")
        node, *rest = nodes
        if (
            isinstance(node, ast.Expr)
            and isinstance(node.value, ast.Constant)
            and isinstance(node.value.value, str)
        ):
            return self.statements(rest, path, mutator)
        if isinstance(node, ast.Return):
            if node.value is None and mutator:
                return [(path, path.environment["state"])]
            return self.expression(node.value, path)
        if isinstance(node, ast.If):
            return [
                result
                for desired, body in [(True, node.body), (False, node.orelse)]
                for branch in self.condition(node.test, desired, path.copy())
                for result in self.statements(body + rest, branch, mutator)
            ]
        if isinstance(node, ast.Assert):
            prefix_length = len(path.premises)
            results = []
            for branch in self.condition(node.test, True, path):
                branch.premises = [dict(premise) for premise in branch.premises]
                for premise in branch.premises[prefix_length:]:
                    if premise["reason"] == "path_condition":
                        premise["reason"] = "assertion"
                results.extend(self.statements(rest, branch, mutator))
            return results
        if isinstance(node, ast.Assign) and len(node.targets) == 1:
            return [
                result
                for branch, value in self.expression(node.value, path)
                for result in self.statements(
                    rest, self.store(node.targets[0], value, branch), mutator
                )
            ]
        if isinstance(node, ast.AugAssign):
            return [
                result
                for branch, left in self.expression(node.target, path)
                for branch, right in self.expression(node.value, branch)
                for result in self.statements(
                    rest,
                    self.store(
                        node.target,
                        self.arithmetic(node.op, left, right, branch, node),
                        branch,
                    ),
                    mutator,
                )
            ]
        raise Unsupported(f"Statement {type(node).__name__} at line {node.lineno}")

    def lower(self, name, node):
        if name not in self.interfaces:
            raise Unsupported(f"Unreviewed source definition {name}")
        interface = self.interfaces[name]
        self.reserved_variables = set(interface.arguments.values())
        signature = inspect.signature(getattr(self.module, name))
        if (
            node.name != name
            or node.args.posonlyargs
            or node.args.kwonlyargs
            or node.args.vararg
            or node.args.kwarg
            or node.args.defaults
            or [arg.arg for arg in node.args.args] != list(signature.parameters)
        ):
            raise Unsupported(f"Unsupported source AST signature for {name}")
        environment = {
            source: Term(target, signature.parameters[source].annotation)
            for source, target in interface.arguments.items()
        }
        self.local_names = set(environment) | {
            item.id
            for item in ast.walk(node)
            if isinstance(item, ast.Name) and isinstance(item.ctx, ast.Store)
        }
        clauses = self.statements(
            node.body, PathState(environment), REVIEWED_EFFECTS[name] is not None
        )
        text = interface.declaration() + "\n\n"
        for index, (path, value) in enumerate(clauses):
            if interface.relation:
                text += (
                    f"rule {interface.relation}/path{index}:\n  "
                    + interface.conclusion(interface.arguments, value.text)
                    + "\n"
                )
            else:
                text += f"def ${name}({', '.join(interface.arguments.values())}) = {value.text}\n"
            text += (
                "".join(
                    f"  -- if {premise['condition']}\n" for premise in path.premises
                )
                + "\n"
            )
        return text, [
            {"result": value.text, "premises": path.premises} for path, value in clauses
        ]


def comparison_replacements(replacements, generated_interfaces, reference, target_text):
    result, adapters = {}, {}
    for name, generated in replacements.items():
        interface = generated_interfaces[name]
        oracle = reference[name]
        if list(oracle["arguments"]) != list(interface.arguments):
            raise Unsupported(f"Oracle parameter mapping does not match {name}")
        if bool(oracle.get("relation")) != bool(interface.relation):
            raise Unsupported(f"Oracle effect classification does not match {name}")
        if not interface.relation:
            result[name] = generated
            continue
        relation = "Generated" + interface.relation
        if re.search(rf"^relation {relation}:", target_text, re.MULTILINE):
            raise Unsupported(f"Comparison relation name collision: {relation}")
        declaration = re.search(
            rf"^relation {oracle['relation']}:.*?hint\(input[^\n]*\)",
            target_text,
            re.MULTILINE | re.DOTALL,
        )
        if not declaration:
            raise Unsupported(f"Missing oracle relation declaration for {name}")
        result_name = interface.result_type + "_comparisonResult"
        forwarded = interface.conclusion(oracle["arguments"], result_name)
        adapter = (
            declaration[0]
            + f"\n\nrule {oracle['relation']}/generated:\n  "
            + oracle["conclusion"].format(result=result_name)
            + f"\n  -- {relation}: {forwarded}\n"
        )
        result[name] = (
            re.sub(
                rf"^(relation|rule) {interface.relation}(?=[:/])",
                rf"\1 {relation}",
                generated,
                flags=re.MULTILINE,
            )
            + "\n"
            + adapter
        )
        adapters[name] = {
            "oracle_relation": oracle["relation"],
            "generated_relation": relation,
            "forwarding_rule": adapter,
        }
    return result, adapters


def replace_definitions(text, replacements, reference):
    pattern = r"^(?=(?:syntax|var|dec|def|relation|rule|builtin)\b)"
    chunks = re.split(pattern, text, flags=re.MULTILINE)
    inserted = set()
    result = []
    for chunk in chunks:
        owner = next(
            (
                name
                for name, mapping in reference.items()
                if re.match(rf"(?:dec|def) \${name}\(", chunk)
                or mapping.get("relation")
                and re.match(rf"(?:relation|rule) {mapping['relation']}(?=[:/])", chunk)
            ),
            None,
        )
        if owner is None:
            result.append(chunk)
        elif owner not in inserted:
            result.append(replacements[owner] + "\n")
            inserted.add(owner)
    if inserted != set(replacements):
        raise ValueError(
            f"Missing reference definitions: {set(replacements) - inserted}"
        )
    return "".join(result)


def dependency_slice(text, reference):
    chunks = re.split(
        r"^(?=(?:syntax|var|dec|def|relation|rule|builtin)\b)", text, flags=re.MULTILINE
    )

    def owner(chunk):
        match = re.match(r"(?:builtin )?(?:dec|def) \$(\w+)", chunk)
        if match:
            return "$" + match[1]
        match = re.match(r"(?:relation|rule) (\w+)", chunk)
        return match[1] if match else None

    definitions = {}
    for chunk in chunks:
        if owner(chunk):
            definitions.setdefault(owner(chunk), []).append(chunk)
    selected = {
        mapping.get("relation", "$" + name) for name, mapping in reference.items()
    }
    pending = list(selected)
    while pending:
        name = pending.pop()
        if name not in definitions:
            raise Unsupported(f"Unresolved reference dependency {name}")
        body = re.sub(r";;[^\n]*", "", "\n".join(definitions[name]))
        dependencies = set(re.findall(r"\$\w+", body)) | set(
            re.findall(r"--\s+(\w+):", body)
        )
        for dependency in dependencies - selected:
            selected.add(dependency)
            pending.append(dependency)
    return "".join(
        chunk for chunk in chunks if owner(chunk) is None or owner(chunk) in selected
    ), sorted(selected)


def run(source, target, output, presentation_overrides=None):
    module, documents = assemble(source)
    reference = json.loads(
        Path(__file__).with_name("capella_reference.json").read_text()
    )
    target_files = sorted(target.glob("*.spectec"))
    target_text = "\n".join(path.read_text() for path in target_files)
    override_bytes, overrides = (
        read_overrides(presentation_overrides)
        if presentation_overrides
        else (None, None)
    )
    lowerer = Lowerer(module, target_text, overrides)
    lowerer.constant("UINT64_MAX")
    generated = ast.parse(Path(module.__file__).read_text())
    nodes = {
        node.name: node for node in generated.body if isinstance(node, ast.FunctionDef)
    }
    originals = {}
    for document in documents:
        for start, block in python_blocks((source / document).read_text()):
            for node in ast.parse(block).body:
                if (
                    isinstance(node, ast.FunctionDef)
                    and node.name in REVIEWED_EFFECTS
                    and ast.dump(node) == ast.dump(nodes[node.name])
                ):
                    ast.increment_lineno(node, start - 1)
                    originals[node.name] = (document, node)
    replacements, report = {}, {}
    for name in REVIEWED_EFFECTS:
        if name not in originals:
            raise Unsupported(f"No unchanged Markdown provenance for {name}")
        document, node = originals[name]
        try:
            replacements[name], paths = lowerer.lower(name, node)
        except Unsupported as error:
            raise Unsupported(f"{document}:{node.lineno}: {name}: {error}") from error
        report[name] = {
            "source": document,
            "line": node.lineno,
            "oracle_reference": reference[name],
            "interface": lowerer.interfaces[name].metadata(),
            "paths": paths,
        }
    adapted, adapters = comparison_replacements(
        replacements, lowerer.interfaces, reference, target_text
    )
    replaced = replace_definitions(target_text, adapted, reference)
    _, closure = dependency_slice(replaced, reference)
    for symbol in closure:
        if symbol.startswith("$") and symbol[1:].isupper():
            lowerer.constant(symbol[1:])
    source_files = sorted(
        {source / document for document in documents}
        | set((source / "pysetup").rglob("*.py"))
        | set((source / "presets/mainnet").rglob("*.yaml"))
        | {
            source / name
            for name in ["configs/mainnet.yaml", "pyproject.toml", "uv.lock"]
        }
    )
    output.mkdir(parents=True, exist_ok=True)
    (output / "generated.spectec").write_text("\n".join(replacements.values()))
    (output / "manual.spectec").write_text(target_text)
    (output / "replaced.spectec").write_text(replaced)
    result = {
        "fork": "capella",
        "preset": "mainnet",
        "revision": REVISION,
        "definitions": report,
        "dependencies": sorted(lowerer.dependencies - set(reference)),
        "dependency_closure": closure,
        "comparison_adapters": adapters,
        "presentation": {
            "default": "source_signature",
            "overrides": overrides,
            "overrides_path": str(presentation_overrides)
            if presentation_overrides
            else None,
            "overrides_sha256": hashlib.sha256(override_bytes).hexdigest()
            if override_bytes is not None
            else None,
        },
        "constants": lowerer.constants,
        "python_version": sys.version,
        "ssz_library": {"remerkleable": importlib.metadata.version("remerkleable")},
        "source_sha256": {
            str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in source_files
        },
        "assembled_python_sha256": hashlib.sha256(
            Path(module.__file__).read_bytes()
        ).hexdigest(),
        "oracle_mapping_sha256": hashlib.sha256(
            Path(__file__).with_name("capella_reference.json").read_bytes()
        ).hexdigest(),
        "reference_sha256": {
            path.name: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in target_files
        },
        "scope": "Eight source-derived interfaces and bodies. The combined comparison artifact namespaces generated mutators and adds positional forwarding adapters for handwritten callers. Other definitions and all target types are handwritten dependencies.",
    }
    (output / "report.json").write_text(json.dumps(result, indent=2) + "\n")
    print(
        json.dumps(
            {
                "definitions": len(report),
                "paths": sum(len(item["paths"]) for item in report.values()),
            }
        )
    )
    return module, reference, result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Generate Capella rules with source-derived interfaces"
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--presentation-overrides", type=Path)
    args = parser.parse_args()
    run(
        args.source.resolve(),
        args.reference.resolve(),
        args.output.resolve(),
        args.presentation_overrides.resolve() if args.presentation_overrides else None,
    )
