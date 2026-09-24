import inspect
import json
import re
from dataclasses import dataclass
from string import Formatter

TYPE_NAMES = {
    "BeaconState": "beaconState",
    "Validator": "validator",
    "Checkpoint": "checkpoint",
    "Epoch": "epoch",
    "Slot": "slot",
    "Gwei": "gwei",
    "ValidatorIndex": "validatorIndex",
    "Root": "root",
    "uint64": "uint64",
    "boolean": "bool",
    "bool": "boolean",
    "int": "int",
}
REVIEWED_EFFECTS = {
    "increase_balance": "state",
    "decrease_balance": "state",
    "get_previous_epoch": None,
    "get_block_root_at_slot": None,
    "get_finality_delay": None,
    "is_active_validator": None,
    "is_slashable_validator": None,
    "process_eth1_data_reset": "state",
}


class Unsupported(Exception):
    pass


def type_name(kind):
    if hasattr(kind, "element_cls"):
        return type_name(kind.element_cls()) + "*"
    name = getattr(kind, "__name__", None)
    if name not in TYPE_NAMES:
        raise Unsupported(f"Unmapped source type {kind}")
    return TYPE_NAMES[name]


@dataclass(frozen=True)
class Interface:
    name: str
    arguments: dict
    parameter_types: dict
    result_type: str
    relation: str | None
    notation: str | None

    def conclusion(self, arguments, result):
        return self.notation.format(**arguments, result=result)

    def declaration(self):
        if self.relation:
            types = self.conclusion(self.parameter_types, self.result_type)
            hints = " ".join(f"%{index}" for index in range(len(self.arguments)))
            return f"relation {self.relation}: {types}\n  hint(input {hints})"
        return f"dec ${self.name}({', '.join(self.parameter_types.values())}) : {self.result_type}"

    def metadata(self):
        return {
            "arguments": self.arguments,
            "parameter_types": self.parameter_types,
            "result_type": self.result_type,
            "relation": self.relation,
            "notation": self.notation,
            "declaration": self.declaration(),
        }


def validate_notation(notation, names):
    if not isinstance(notation, str) or "\n" in notation or "\r" in notation:
        raise Unsupported("Notation must be one line")
    try:
        parts = list(Formatter().parse(notation))
    except ValueError as error:
        raise Unsupported(f"Invalid notation: {error}") from error
    placeholders = []
    for literal, field, spec, conversion in parts:
        for atom in literal.split():
            if not re.fullmatch(
                r"[A-Z][A-Z0-9_]*|'[.+*/<>=!|&:-]+'|`[\[\]()]|~>|\|-", atom
            ):
                raise Unsupported(f"Unsupported notation atom {atom!r}")
        if field is not None:
            if spec or conversion:
                raise Unsupported("Notation placeholders cannot use formatting")
            placeholders.append(field)
    if placeholders != [*names, "result"]:
        raise Unsupported(
            "Notation must contain each input in source order, then {result}, exactly once"
        )


def read_overrides(path):
    def unique_keys(pairs):
        result = {}
        for name, value in pairs:
            if name in result:
                raise Unsupported(f"Duplicate presentation override key {name}")
            result[name] = value
        return result

    raw = path.read_bytes()
    try:
        overrides = json.loads(raw, object_pairs_hook=unique_keys)
    except (ValueError, UnicodeDecodeError) as error:
        raise Unsupported(f"Invalid presentation overrides JSON: {error}") from error
    if not isinstance(overrides, dict):
        raise Unsupported("Presentation overrides must be a JSON object")
    return raw, overrides


def interfaces(module, target_text, overrides=None):
    overrides = {} if overrides is None else overrides
    if not isinstance(overrides, dict) or set(overrides) - REVIEWED_EFFECTS.keys():
        raise Unsupported(
            "Presentation overrides must name reviewed source definitions"
        )
    result = {}
    for name, state in REVIEWED_EFFECTS.items():
        function = getattr(module, name)
        if not inspect.isfunction(function) or inspect.iscoroutinefunction(function):
            raise Unsupported(f"Unsupported source definition {name}")
        signature = inspect.signature(function)
        parameters = list(signature.parameters.values())
        if not parameters or any(
            parameter.kind != inspect.Parameter.POSITIONAL_OR_KEYWORD
            or parameter.default != inspect.Parameter.empty
            for parameter in parameters
        ):
            raise Unsupported(f"Unsupported source signature for {name}")
        kinds = {
            parameter.name: type_name(parameter.annotation) for parameter in parameters
        }
        if any(kind.endswith("*") for kind in kinds.values()):
            raise Unsupported(f"Sequence interfaces are not reviewed for {name}")
        if state:
            if (
                parameters[0].name != state
                or parameters[0].annotation is not module.BeaconState
                or signature.return_annotation is not None
            ):
                raise Unsupported(f"Unsupported state-mutator signature for {name}")
            output = kinds[state]
            relation = "".join(word.capitalize() for word in name.split("_"))
        else:
            output = type_name(signature.return_annotation)
            relation = None
        override = overrides.get(name, {})
        allowed = {"arguments", "relation", "notation"} if state else {"arguments"}
        if not isinstance(override, dict) or set(override) - allowed:
            raise Unsupported(f"Unsupported presentation override for {name}")
        arguments = override.get(
            "arguments", {source: f"{kind}_{source}" for source, kind in kinds.items()}
        )
        if not isinstance(arguments, dict) or set(arguments) != set(kinds):
            raise Unsupported(f"Presentation arguments do not match {name}")
        arguments = {source: arguments[source] for source in kinds}
        for source, variable in arguments.items():
            if not isinstance(variable, str) or not re.fullmatch(
                r"[a-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)*", variable
            ):
                raise Unsupported(f"Invalid argument variable for {name}.{source}")
            base = variable.split("_")[0]
            kind = kinds[source]
            if base != kind and not re.search(
                rf"^var\s+{base}\s*:\s*{kind}\s*$", target_text, re.MULTILINE
            ):
                raise Unsupported(
                    f"Argument {variable} needs a base prefix typed as {kind}"
                )
        if len(set(arguments.values())) != len(arguments):
            raise Unsupported(f"Argument variables must be distinct for {name}")
        notation = None
        if state:
            default_relation = relation
            relation = override.get("relation", relation)
            if not isinstance(relation, str) or not re.fullmatch(
                r"[A-Z][A-Za-z0-9]*", relation
            ):
                raise Unsupported(f"Invalid relation name for {name}")
            if relation != default_relation and re.search(
                rf"^relation {relation}:", target_text, re.MULTILINE
            ):
                raise Unsupported(f"Generated relation name collision: {relation}")
            notation = override.get(
                "notation",
                " ".join("{" + source + "}" for source in kinds) + " ~> {result}",
            )
            validate_notation(notation, kinds)
        result[name] = Interface(name, arguments, kinds, output, relation, notation)
    relations = [
        interface.relation for interface in result.values() if interface.relation
    ]
    if len(relations) != len(set(relations)):
        raise Unsupported("Generated relation names must be distinct")
    return result
