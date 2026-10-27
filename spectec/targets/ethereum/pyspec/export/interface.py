import inspect
import re
from dataclasses import dataclass

from .error import Unsupported
from .metadata.capella import REVIEWED_EFFECTS
from .pyspec import literal_default, source_function
from .ssz import nested_type_parameter, ssz_parameter, type_name


@dataclass(frozen=True)
class Interface:
    name: str
    arguments: dict
    parameter_types: dict
    result_type: str
    relation: str | None
    notation: str | None
    type_parameters: tuple = ()

    def conclusion(self, arguments, result):
        return self.notation.format(**arguments, result=result)

    def declaration(self):
        if self.relation:
            types = self.conclusion(self.parameter_types, self.result_type)
            hints = " ".join(f"%{index}" for index in range(len(self.arguments)))
            return f"relation {self.relation}: {types}\n  hint(input {hints})"
        parameters = (
            "<" + ", ".join(self.type_parameters) + ">" if self.type_parameters else ""
        )
        return f"dec ${self.name}{parameters}({', '.join(self.parameter_types.values())}) : {self.result_type}"

    def metadata(self):
        return {
            "arguments": self.arguments,
            "parameter_types": self.parameter_types,
            "result_type": self.result_type,
            "relation": self.relation,
            "notation": self.notation,
            "declaration": self.declaration(),
        }


def interfaces(module):
    result = {}
    for name, state in REVIEWED_EFFECTS.items():
        function = source_function(module, name)
        if not inspect.isfunction(function) or inspect.iscoroutinefunction(function):
            raise Unsupported(f"Unsupported source definition {name}")
        signature = inspect.signature(function)
        parameters = list(signature.parameters.values())
        if any(
            nested_type_parameter(kind)
            for kind in [
                signature.return_annotation,
                *(p.annotation for p in parameters),
            ]
        ):
            raise Unsupported(
                "Nested SSZ type parameters are outside the source subset"
            )
        type_parameters = tuple(
            dict.fromkeys(
                parameter
                for p in parameters
                if (parameter := ssz_parameter(p.annotation)) is not None
            )
        )
        if ssz_parameter(signature.return_annotation) is not None:
            raise Unsupported("Generic return types are outside the source subset")
        if state and type_parameters:
            raise Unsupported("Generic state-mutator signatures are unsupported")
        # The target models an execution engine as a unit handle, which stands
        # for one external service per request.
        if (
            sum(
                parameter.annotation is getattr(module, "ExecutionEngine", None)
                for parameter in parameters
            )
            > 1
        ):
            raise Unsupported(f"More than one execution engine for {name}")
        if any(
            p.default is None and ssz_parameter(p.annotation) is not None
            for p in parameters
        ):
            raise Unsupported(
                "Optional SSZ type parameters are outside the source subset"
            )
        if not parameters or any(
            parameter.kind != inspect.Parameter.POSITIONAL_OR_KEYWORD
            for parameter in parameters
        ):
            raise Unsupported(f"Unsupported source signature for {name}")
        # A literal default keeps the parameter's present type. It is bound at a
        # call site that omits the argument, not by a second implementation.
        for parameter in parameters:
            literal_default(parameter)
        # A None default makes the parameter optional even though the Python
        # annotation names only the present type.
        optional = {
            parameter.name for parameter in parameters if parameter.default is None
        }
        kinds = {
            parameter.name: type_name(parameter.annotation)
            + ("?" if parameter.name in optional else "")
            for parameter in parameters
        }
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
        arguments = {
            source: f"{kind.rstrip('*?')}_{source}" for source, kind in kinds.items()
        }
        for source, variable in arguments.items():
            if not isinstance(variable, str) or not re.fullmatch(
                r"[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)*", variable
            ):
                raise Unsupported(f"Invalid argument variable for {name}.{source}")
        if len(set(arguments.values())) != len(arguments):
            raise Unsupported(f"Argument variables must be distinct for {name}")
        notation = None
        if state:
            if not isinstance(relation, str) or not re.fullmatch(
                r"[A-Z][A-Za-z0-9]*", relation
            ):
                raise Unsupported(f"Invalid relation name for {name}")
            notation = " ".join("{" + source + "}" for source in kinds) + " ~> {result}"
        result[name] = Interface(
            name, arguments, kinds, output, relation, notation, type_parameters
        )
    relations = [
        interface.relation for interface in result.values() if interface.relation
    ]
    if len(relations) != len(set(relations)):
        raise Unsupported("Generated relation names must be distinct")
    return result
