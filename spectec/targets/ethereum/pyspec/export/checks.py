import ast
import builtins
import inspect
from collections import Counter

from .error import Unsupported
from .forks.capella import REVIEWED_SET_OR_APPEND_LIST, REVIEWED_STATE_READS
from .runtime import source_function
from .selection import (
    effect,
    is_translated_function,
    reached_functions,
    reaches_external_engine_global,
)
from .syntax import LOCAL_HELPER_ANNOTATION_NAMES


def check_set_or_append_list(module):
    function = source_function(module, "set_or_append_list")
    if (
        inspect.getsource(function) != REVIEWED_SET_OR_APPEND_LIST
        or getattr(module, "len", builtins.len) is not builtins.len
    ):
        raise Unsupported("set_or_append_list differs from the prelude definition")


def reviewed_noop_engine(module):
    engine = getattr(module, "EXECUTION_ENGINE", None)
    noop = getattr(module, "NoopExecutionEngine", None)
    method = getattr(type(engine), "verify_and_notify_new_payload", None)
    if (
        not isinstance(noop, type)
        or type(engine) is not noop
        or getattr(method, "__qualname__", None)
        != "NoopExecutionEngine.verify_and_notify_new_payload"
        or getattr(method, "__module__", None) != module.__name__
        or not reviewed_payload_request(module)
    ):
        return False
    # The Ethereum request runner uses the default engine's noop response, so
    # the exporter observes that response here.
    request = module.NewPayloadRequest(execution_payload=module.ExecutionPayload())
    return engine.verify_and_notify_new_payload(request) is True


def reviewed_payload_request(module):
    from dataclasses import fields, is_dataclass

    request = getattr(module, "NewPayloadRequest", None)
    return is_dataclass(request) and [
        (field.name, field.type) for field in fields(request)
    ] == [("execution_payload", module.ExecutionPayload)]


def local_helper_contract(module, uses):
    """How a nested mutator helper and the mutators it receives may be used.

    The helper exists only to be called, and a mutator named at a call site may
    not also be read as a value, so neither can escape into a position the
    target has no function value for.
    """
    node = uses.node
    helpers = [item for item in uses.nodes if isinstance(item, ast.FunctionDef)][1:]
    if not helpers:
        return
    import typing

    if (
        getattr(module, "Sequence", None) is not typing.Sequence
        or getattr(module, "Callable", None) is not typing.Callable
        or getattr(module, "Any", None) is not typing.Any
        or not isinstance(getattr(module, "BeaconState", None), type)
    ):
        raise Unsupported("Unreviewed local helper annotation bindings")
    # Python evaluates a nested definition's annotations in the enclosing scope,
    # so a name bound there hides the module binding checked above. A name bound
    # inside a helper is not one of those lookups.
    inside = {id(item) for helper in helpers for item in ast.walk(helper)}
    enclosing = (
        {argument.arg for argument in node.args.args}
        | {
            item.id
            for item in uses.nodes
            if isinstance(item, ast.Name)
            and isinstance(item.ctx, ast.Store)
            and id(item) not in inside
        }
        | {
            item.name
            for item in uses.nodes
            if isinstance(item, (ast.FunctionDef, ast.ClassDef)) and item is not node
        }
    )
    shadowed = sorted(enclosing & set(LOCAL_HELPER_ANNOTATION_NAMES))
    if shadowed:
        raise Unsupported(
            f"A local helper annotation name is shadowed: {', '.join(shadowed)}"
        )
    names = [helper.name for helper in helpers]
    if len(set(names)) != len(names) or any(
        hasattr(module, name) for name in names
    ):
        raise Unsupported("A local helper name must be fresh")
    nested = [
        item
        for helper in helpers
        for item in ast.walk(helper)
        if isinstance(item, ast.FunctionDef) and item is not helper
    ]
    if nested:
        raise Unsupported("A local helper cannot define another helper")
    mutators = set()
    for name in names:
        calls = uses.named_calls.get(name, [])
        if uses.name_uses.get(name, 0) != len(calls):
            raise Unsupported(f"A local helper is only callable: {name}")
        for call in calls:
            if (
                call.keywords
                or len(call.args) != 2
                or not isinstance(call.args[1], ast.Name)
            ):
                raise Unsupported(
                    f"A local helper call passes one sequence and one mutator: {name}"
                )
            mutator = call.args[1].id
            if not is_translated_function(module, mutator) or effect(
                module, mutator
            ) != "state":
                raise Unsupported(f"A local helper mutator must mutate the state: {mutator}")
            mutators.add(mutator)
    arguments = Counter(
        call.args[1].id for name in names for call in uses.named_calls.get(name, [])
    )
    for mutator in sorted(mutators):
        if uses.name_uses.get(mutator, 0) != arguments[mutator]:
            raise Unsupported(
                f"A mutator passed to a local helper cannot escape: {mutator}"
            )


def checked_state_reads(module):
    """The reviewed read footprints, checked against the pinned source.

    Each declared footprint must cover every BeaconState field name reachable
    from that helper through the reviewed call graph. Attribute names widen
    the reachable set, so the check can only demand more.
    """
    fields = set(module.BeaconState.fields())
    result = {}
    for name, declared in REVIEWED_STATE_READS.items():
        reads = set().union(
            *(names & fields for _, names in reached_functions(module, name))
        )
        if not reads <= set(declared):
            raise Unsupported(
                f"Reviewed state reads for {name} miss {sorted(reads - set(declared))}"
            )
        result[name] = sorted(declared)
    return result


def check_engine_parameters(module, node, signature):
    engine_parameters = [
        name
        for name, parameter in signature.parameters.items()
        if parameter.annotation is module.ExecutionEngine
    ]
    if engine_parameters and reaches_external_engine_global(module, node.name):
        # One unit-typed handle stands for one external service per request, so
        # a supplied engine and the global cannot both be consulted.
        raise Unsupported(
            "A supplied execution engine cannot reach the execution-engine global"
        )
