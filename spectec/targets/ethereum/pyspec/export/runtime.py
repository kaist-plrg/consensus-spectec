import inspect

from .error import Unsupported
from .forks.capella import REVIEWED_CACHE_KEYS


def configuration_fields(module):
    config = getattr(module, "config", None)
    if type(config) is not getattr(module, "Configuration", None):
        raise Unsupported("Unreviewed configuration namespace")
    return set(config._fields)


def constant_value(module, name):
    if name in configuration_fields(module):
        return getattr(module.config, name)
    return getattr(module, name, None)


def source_function(module, name):
    function = getattr(module, name)
    if not inspect.isfunction(function):
        raise Unsupported(f"Unsupported source definition {name}")
    if function.__name__ != "wrapper":
        return function
    if name not in REVIEWED_CACHE_KEYS:
        raise Unsupported(f"Unreviewed source wrapper {name}")
    factory = getattr(module, "cache_this", None)
    original = getattr(module, "_" + name, None)
    if not inspect.isfunction(factory) or not inspect.isfunction(original):
        raise Unsupported(f"Missing cache provenance for {name}")
    codes = [value for value in factory.__code__.co_consts if inspect.iscode(value)]
    closure = dict(zip(function.__code__.co_freevars, function.__closure__ or ()))
    key = closure.get("key_fn")
    key_function = key.cell_contents if key is not None else None
    expected_code = compile(REVIEWED_CACHE_KEYS[name], "<cache-key>", "eval").co_consts[0]
    code_fields = ("co_code", "co_consts", "co_names", "co_varnames", "co_freevars")
    valid_key = inspect.isfunction(key_function) and all(
        getattr(key_function.__code__, field) == getattr(expected_code, field)
        for field in code_fields
    )
    if (
        not valid_key
        or not any(function.__code__ is code for code in codes)
        or set(closure) != {"cache_dict", "key_fn", "value_fn"}
        or closure["value_fn"].cell_contents is not original
        or original.__name__ != name
        or function.__globals__ is not vars(module)
        or original.__globals__ is not vars(module)
    ):
        raise Unsupported(f"Unreviewed cache provenance for {name}")
    return original


def literal_default(parameter):
    """Returns a boolean parameter's literal default, or None when absent.

    An omitted argument takes the boolean default without changing its type.
    A None default marks an optional parameter and reports None here. The
    exporter rejects other defaults.
    """
    default = parameter.default
    if default is inspect.Parameter.empty or default is None:
        return None
    if default is not True and default is not False:
        raise Unsupported(f"Unsupported parameter default for {parameter.name}")
    if parameter.annotation is not bool:
        raise Unsupported(f"Boolean default on a non-boolean {parameter.name}")
    return default
