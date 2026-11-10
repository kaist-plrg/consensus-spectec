import inspect

from .runtime import source_function


def referenced_global_names(function):
    import types

    names, pending = set(), [function.__code__]
    while pending:
        code = pending.pop()
        names |= set(code.co_names)
        pending += [
            value for value in code.co_consts if isinstance(value, types.CodeType)
        ]
    return names


# The prelude supplies set_or_append_list. Other functions defined by pyspec are
# translated. Imported library functions, including hash_tree_root, need builtin
# support.
def is_translated_function(module, name):
    value = getattr(module, name, None)
    return (
        name != "set_or_append_list"
        and inspect.isfunction(value)
        and value.__module__ == module.__name__
    )


# A None return annotation marks a state mutator. The translator requires its
# first parameter to be state of type BeaconState.
def effect(module, name):
    signature = inspect.signature(source_function(module, name))
    return "state" if signature.return_annotation is None else None


# Each reached function, including root, is paired with its referenced global
# names. Attribute names in bytecode can conservatively widen the reached set.
def reached_functions(module, root):
    pending, seen = [root], set()
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)
        names = referenced_global_names(source_function(module, current))
        yield current, names
        pending += sorted(
            name
            for name in names - seen
            if is_translated_function(module, name)
        )


def translated_functions(module, roots):
    return sorted(
        {name for root in roots for name, _ in reached_functions(module, root)}
    )


def reaches_external_engine_global(module, name):
    return any(
        "EXECUTION_ENGINE" in names for _, names in reached_functions(module, name)
    )
