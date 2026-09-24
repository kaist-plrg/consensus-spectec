import argparse
import ast
import inspect
import itertools
import json
from dataclasses import dataclass
from pathlib import Path

from assemble import assemble
from inventory import python_blocks
from ssz.uint import BaseUint


class Unsupported(Exception):
    def __init__(self, node, reason):
        self.line = getattr(node, "lineno", 0)
        self.reason = reason
        super().__init__(reason)


def scalar_type(kind):
    return kind in (int, bool) or (
        isinstance(kind, type) and issubclass(kind, BaseUint) and hasattr(kind, "BITS")
    )


def target_type(kind):
    return "bool" if kind is bool else "int"


def numeric_type(left, right, node):
    if left is bool or right is bool:
        raise Unsupported(
            node, "Boolean arithmetic requires a separate Python type model"
        )
    if left is int:
        return right
    if right is int or issubclass(left, right):
        return left
    if issubclass(right, left):
        return right
    raise Unsupported(
        node, "Arithmetic or comparison between unrelated SSZ integer types"
    )


@dataclass
class Value:
    text: str
    kind: type
    premises: tuple = ()


@dataclass
class Function:
    node: ast.FunctionDef
    parameters: list
    arguments: list
    returns: type
    clauses: list


def truth(value):
    return value.text if value.kind is bool else f"({value.text} =/= 0)"


class Compiler:
    def __init__(self, module):
        self.module = module
        self.source = Path(module.__file__).read_text()
        self.tree = ast.parse(self.source)
        self.nodes = {
            node.name: node
            for node in self.tree.body
            if isinstance(node, ast.FunctionDef)
        }
        self.functions = {}
        self.active = set()
        self.variables = {}
        self.global_values = {}
        self.widths = set()
        self.source_functions = None

    def fresh(self, kind):
        name = f"pyv{len(self.variables)}"
        self.variables[name] = target_type(kind)
        return name

    def bind(self, text, kind, premises=()):
        name = self.fresh(kind)
        if isinstance(kind, type) and issubclass(kind, BaseUint):
            self.widths.add(kind.BITS)
            text = f"$py_check{kind.BITS}({text})"
        return Value(name, kind, premises + (f"{text} = {name}",))

    def literal(self, value, node):
        kind = type(value)
        if not scalar_type(kind):
            raise Unsupported(node, f"Non-scalar value of type {kind.__name__}")
        text = str(value).lower() if kind is bool else str(int(value))
        return Value(text, kind)

    def function(self, name):
        if name in self.functions:
            return self.functions[name]
        if name not in self.nodes:
            raise Unsupported(self.tree, f"Unresolved function dependency: {name}")
        node = self.nodes[name]
        if self.source_functions is not None and name not in self.source_functions:
            raise Unsupported(
                node,
                "No unchanged Markdown definition. Upstream builder code requires review",
            )
        if name in self.active:
            raise Unsupported(
                node, "Recursive source functions require a termination strategy"
            )
        function = getattr(self.module, name, None)
        if (
            not inspect.isfunction(function)
            or function.__code__.co_firstlineno != node.lineno
            or node.decorator_list
        ):
            raise Unsupported(
                node, "Function is decorated or rebound by the upstream builder"
            )
        if (
            Path(function.__code__.co_filename).resolve()
            != Path(self.module.__file__).resolve()
        ):
            raise Unsupported(node, "Function binding is outside the assembled module")
        signature = inspect.signature(function)
        parameters = []
        for parameter in signature.parameters.values():
            if (
                parameter.kind
                not in (parameter.POSITIONAL_ONLY, parameter.POSITIONAL_OR_KEYWORD)
                or parameter.default is not parameter.empty
            ):
                raise Unsupported(node, "Default, keyword-only, or variadic parameters")
            if not scalar_type(parameter.annotation):
                raise Unsupported(
                    node,
                    f"Non-scalar parameter {parameter.name}: {parameter.annotation}",
                )
            parameters.append((parameter.name, parameter.annotation))
        self.active.add(name)
        try:
            inputs = [self.fresh(kind) for _, kind in parameters]
            arguments = [
                self.bind(name, kind) for name, (_, kind) in zip(inputs, parameters)
            ]
            environment = {
                param: Value(value.text, kind)
                for (param, kind), value in zip(parameters, arguments)
            }
            premises = tuple(
                premise for value in arguments for premise in value.premises
            )
            clauses = self.statements(node.body, environment, premises)
            kinds = {value.kind for value in clauses}
            if len(kinds) != 1:
                raise Unsupported(node, "Return paths have different runtime types")
            result = Function(node, parameters, inputs, kinds.pop(), clauses)
            self.functions[name] = result
            return result
        finally:
            self.active.remove(name)

    def statements(self, statements, environment, premises):
        if not statements:
            raise Unsupported(self.tree, "Implicit None return")
        node, *rest = statements
        if (
            isinstance(node, ast.Expr)
            and isinstance(node.value, ast.Constant)
            and isinstance(node.value.value, str)
        ):
            return self.statements(rest, environment, premises)
        if isinstance(node, ast.Return):
            return [
                Value(value.text, value.kind, premises + value.premises)
                for value in self.expression(node.value, environment)
            ]
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            if node.value is None or any(
                not isinstance(target, ast.Name) for target in targets
            ):
                raise Unsupported(
                    node, "Object mutation, destructuring, or declaration without value"
                )
            results = []
            for value in self.expression(node.value, environment):
                next_environment = dict(environment)
                for target in targets:
                    next_environment[target.id] = Value(value.text, value.kind)
                results.extend(
                    self.statements(rest, next_environment, premises + value.premises)
                )
            return results
        if isinstance(node, ast.If):
            results = []
            for value in self.expression(node.test, environment):
                for branch, guard in [
                    (node.body, truth(value)),
                    (node.orelse, f"~({truth(value)})"),
                ]:
                    results.extend(
                        self.statements(
                            branch + rest,
                            dict(environment),
                            premises + value.premises + (guard,),
                        )
                    )
            return results
        if isinstance(node, ast.Assert):
            results = []
            for value in self.expression(node.test, environment):
                results.extend(
                    self.statements(
                        rest, environment, premises + value.premises + (truth(value),)
                    )
                )
            return results
        raise Unsupported(node, f"Statement {type(node).__name__}")

    def expression(self, node, environment):
        if isinstance(node, ast.Constant):
            return [self.literal(node.value, node)]
        if isinstance(node, ast.Name):
            if node.id in environment:
                return [environment[node.id]]
            if not hasattr(self.module, node.id):
                raise Unsupported(node, f"Unresolved name {node.id}")
            value = self.literal(getattr(self.module, node.id), node)
            self.global_values[node.id] = {
                "value": value.text,
                "type": value.kind.__name__,
            }
            return [value]
        if isinstance(node, ast.UnaryOp):
            values = self.expression(node.operand, environment)
            if isinstance(node.op, ast.Not):
                return [
                    self.bind(f"~({truth(value)})", bool, value.premises)
                    for value in values
                ]
            if any(value.kind is bool for value in values):
                raise Unsupported(node, "Boolean arithmetic")
            operators = {ast.USub: "-", ast.UAdd: "+", ast.Invert: "~"}
            if type(node.op) not in operators:
                raise Unsupported(node, "Unary operator")
            return [
                self.bind(
                    f"$(-{value.text} - 1)"
                    if isinstance(node.op, ast.Invert)
                    else f"$({operators[type(node.op)]}{value.text})",
                    int,
                    value.premises,
                )
                for value in values
            ]
        if isinstance(node, ast.BinOp):
            values = []
            for left, right in itertools.product(
                self.expression(node.left, environment),
                self.expression(node.right, environment),
            ):
                kind = numeric_type(left.kind, right.kind, node)
                arithmetic = {ast.Add: "+", ast.Sub: "-", ast.Mult: "*"}
                helpers = {
                    ast.FloorDiv: "py_floor_div",
                    ast.Mod: "py_mod",
                    ast.BitAnd: "py_bitand",
                    ast.BitOr: "py_bitor",
                    ast.BitXor: "py_bitxor",
                }
                if type(node.op) in arithmetic:
                    text = f"$({left.text} {arithmetic[type(node.op)]} {right.text})"
                elif type(node.op) in helpers:
                    text = f"${helpers[type(node.op)]}({left.text}, {right.text})"
                elif (
                    isinstance(node.op, ast.Pow)
                    and isinstance(node.right, ast.Constant)
                    and type(node.right.value) is int
                    and node.right.value >= 0
                ):
                    text = f"$({left.text} ^ {right.text})"
                else:
                    raise Unsupported(
                        node, f"Numeric operator {type(node.op).__name__}"
                    )
                values.append(self.bind(text, kind, left.premises + right.premises))
            return values
        if isinstance(node, ast.Compare):
            if len(node.ops) != 1:
                raise Unsupported(
                    node, "Chained comparisons require short-circuit lowering"
                )
            operators = {
                ast.Eq: "=",
                ast.NotEq: "=/=",
                ast.Lt: "<",
                ast.LtE: "<=",
                ast.Gt: ">",
                ast.GtE: ">=",
            }
            if type(node.ops[0]) not in operators:
                raise Unsupported(node, "Identity or membership comparison")
            values = []
            for left, right in itertools.product(
                self.expression(node.left, environment),
                self.expression(node.comparators[0], environment),
            ):
                if left.kind is not bool or right.kind is not bool:
                    numeric_type(left.kind, right.kind, node)
                elif not isinstance(node.ops[0], (ast.Eq, ast.NotEq)):
                    raise Unsupported(node, "Boolean ordering")
                text = f"({left.text} {operators[type(node.ops[0])]} {right.text})"
                if not isinstance(node.ops[0], (ast.Eq, ast.NotEq)):
                    text = "$" + text
                values.append(self.bind(text, bool, left.premises + right.premises))
            return values
        if isinstance(node, ast.IfExp):
            values = []
            for condition in self.expression(node.test, environment):
                for branch, guard in [
                    (node.body, truth(condition)),
                    (node.orelse, f"~({truth(condition)})"),
                ]:
                    for value in self.expression(branch, environment):
                        values.append(
                            Value(
                                value.text,
                                value.kind,
                                condition.premises + (guard,) + value.premises,
                            )
                        )
            return values
        if isinstance(node, ast.BoolOp):

            def descend(index):
                result = []
                for value in self.expression(node.values[index], environment):
                    if index == len(node.values) - 1:
                        result.append(value)
                        continue
                    positive = truth(value)
                    negative = f"~({positive})"
                    stop, proceed = (
                        (negative, positive)
                        if isinstance(node.op, ast.And)
                        else (positive, negative)
                    )
                    result.append(
                        Value(value.text, value.kind, value.premises + (stop,))
                    )
                    for tail in descend(index + 1):
                        result.append(
                            Value(
                                tail.text,
                                tail.kind,
                                value.premises + (proceed,) + tail.premises,
                            )
                        )
                return result

            return descend(0)
        if isinstance(node, ast.Call):
            if not isinstance(node.func, ast.Name) or node.keywords:
                raise Unsupported(node, "Method or keyword call")
            name = node.func.id
            binding = getattr(self.module, name, None)
            if name in ("int", "bool"):
                binding = {"int": int, "bool": bool}[name]
            arguments = [self.expression(arg, environment) for arg in node.args]
            if scalar_type(binding):
                if len(arguments) != 1:
                    raise Unsupported(node, "Scalar constructor arity")
                values = []
                for value in arguments[0]:
                    if value.kind is bool and binding is not bool:
                        raise Unsupported(node, "Boolean to integer conversion")
                    text = truth(value) if binding is bool else value.text
                    values.append(self.bind(text, binding, value.premises))
                return values
            dependency = self.function(name)
            if len(arguments) != len(dependency.parameters):
                raise Unsupported(node, "Function arity mismatch")
            values = []
            for combination in itertools.product(*arguments):
                if any(
                    value.kind is not kind
                    for value, (_, kind) in zip(combination, dependency.parameters)
                ):
                    raise Unsupported(
                        node,
                        "Call argument runtime type differs from its annotated type",
                    )
                text = f"${name}({', '.join(value.text for value in combination)})"
                premises = tuple(
                    premise for value in combination for premise in value.premises
                )
                values.append(self.bind(text, dependency.returns, premises))
            return values
        raise Unsupported(node, f"Expression {type(node).__name__}")

    def render(self):
        parts = [Path(__file__).with_name("scalar_runtime.spectec").read_text()]
        for bits in sorted(self.widths):
            parts.append(
                f"dec $py_check{bits}(int) : int\ndef $py_check{bits}(pyx) = pyx\n  -- if $(pyx >= 0)\n  -- if $(pyx < {2**bits})\n"
            )
        parts.extend(f"var {name} : {kind}\n" for name, kind in self.variables.items())
        for name, function in self.functions.items():
            signature = ", ".join(target_type(kind) for _, kind in function.parameters)
            parts.append(
                f"dec ${name}({signature}) : {target_type(function.returns)}\n"
            )
            for clause in function.clauses:
                parts.append(
                    f"def ${name}({', '.join(function.arguments)}) = {clause.text}\n"
                    + "".join(f"  -- if {premise}\n" for premise in clause.premises)
                )
            types = " ".join(target_type(kind) for _, kind in function.parameters)
            args = " ".join(function.arguments)
            hints = " ".join(f"%{index}" for index in range(len(function.parameters)))
            parts.append(
                f"relation Py_{name}: {types} |- {target_type(function.returns)}\n  hint(input {hints})\nrule Py_{name}: {args} |- ${name}({', '.join(function.arguments)})\n"
            )
        return "\n".join(parts)


def run(source, preset, output):
    module, manifest = assemble(source, preset)
    compiler = Compiler(module)
    provenance = {}
    for path in manifest["markdown_order"]:
        for start, block in python_blocks((source / path).read_text()):
            for node in ast.parse(block).body:
                if isinstance(node, ast.FunctionDef):
                    provenance.setdefault(ast.dump(node), []).append(
                        {"path": path, "line": start + node.lineno - 1}
                    )
    definitions = []
    compiler.source_functions = {
        name for name, node in compiler.nodes.items() if ast.dump(node) in provenance
    }
    for name, node in compiler.nodes.items():
        entry = {
            "name": name,
            "generated_line": node.lineno,
            "markdown": provenance.get(ast.dump(node), []),
        }
        try:
            function = compiler.function(name)
            entry.update(
                status="emitted",
                parameters={key: kind.__name__ for key, kind in function.parameters},
                returns=function.returns.__name__,
            )
        except Unsupported as error:
            entry.update(
                status="blocked",
                reason=error.reason,
                evidence_generated_line=error.line,
            )
        definitions.append(entry)
    output.mkdir(parents=True, exist_ok=True)
    (output / "scalar.spectec").write_text(compiler.render())
    manifest["numeric_model"] = (
        "Experimental checked mathematical integers with SSZ runtime type tracking"
    )
    manifest["global_values"] = compiler.global_values
    report = {
        "manifest": manifest,
        "definitions": definitions,
        "summary": {
            "functions": len(definitions),
            "emitted": len(compiler.functions),
            "blocked": sum(entry["status"] == "blocked" for entry in definitions),
        },
        "limitations": [
            "Scalar parameters and results only",
            "No state transition or SSZ serialization support",
            "No official vector validation",
            "Rejection equivalence does not preserve exception classes or messages",
        ],
    }
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["summary"]))
    return compiler, report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Transpile supported scalar functions from pinned Gloas"
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("--preset", required=True, choices=["minimal", "mainnet"])
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    run(args.source.resolve(), args.preset, args.output.resolve())
