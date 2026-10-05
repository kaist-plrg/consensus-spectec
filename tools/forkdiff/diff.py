"""`diff`: effective upstream definitions per fork, via consensus-specs' own pysetup."""

import argparse
import ast
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import textwrap
from collections import defaultdict
from pathlib import Path
from typing import Literal, TypedDict, cast, get_args

CATEGORIES = (
    "functions",
    "protocols",
    "custom_types",
    "constant_vars",
    "preset_dep_constant_vars",
    "preset_vars",
    "config_vars",
    "ssz_dep_constants",
    "func_dep_presets",
    "ssz_objects",
    "dataclasses",
)
CODE = {"functions", "protocols", "ssz_objects", "dataclasses"}
CONTAINERS = {"ssz_objects", "dataclasses"}
FUNCS = {"functions", "protocols"}
VARS = {
    "constant_vars",
    "preset_dep_constant_vars",
    "preset_vars",
    "config_vars",
    "ssz_dep_constants",
    "func_dep_presets",
}

# Re-exec target that works however we were started (console script, -m, or by path).
MAIN = str(Path(__file__).with_name("__main__.py"))

Kind = Literal["added", "changed", "removed", "doc_only"]


class Var(TypedDict):
    """A constant / preset / config entry as pysetup reports it."""

    type: str | None
    value: str


Source = str | Var  # Python source for code categories, type + value for VARS


class Symbol(TypedDict):
    src: Source
    doc: str  # markdown doc the effective definition came from


class Change(TypedDict):
    category: str
    name: str
    kind: Kind
    doc: str
    old: Source | None  # None when added
    new: Source | None  # None when removed


SymbolTable = dict[tuple[str, str], Symbol]  # (category, name) -> effective definition

Diff = TypedDict(
    "Diff",
    {
        "specs": str,
        "rev": str,  # consensus-specs commit
        "preset": str,
        "from": str,
        "to": str,
        "changes": list[Change],
    },
)


def load_diff(path: Path) -> Diff:
    """Read a `diff` JSON; raise ValueError on anything not shaped like Diff."""
    d = json.loads(path.read_text())
    if not isinstance(d, dict):
        raise ValueError("top level is not an object")
    for k in ("specs", "rev", "preset", "from", "to"):
        if not isinstance(d.get(k), str):
            raise ValueError(f"`{k}` is not a string")
    if not isinstance(d.get("changes"), list):
        raise ValueError("`changes` is not a list")
    for i, c in enumerate(d["changes"]):
        where = f"changes[{i}]"
        if not isinstance(c, dict):
            raise ValueError(f"{where} is not an object")
        for k in ("category", "name", "doc"):
            if not isinstance(c.get(k), str):
                raise ValueError(f"{where}.{k} is not a string")
        if c["category"] not in CATEGORIES:
            raise ValueError(f"{where}.category {c['category']!r} is unknown")
        if c.get("kind") not in get_args(Kind):
            raise ValueError(f"{where}.kind {c.get('kind')!r} is unknown")
        # added has no old, removed has no new, the rest have both
        for k, absent in (("old", "added"), ("new", "removed")):
            if c["kind"] == absent:
                if c.get(k) is not None:
                    raise ValueError(f"{where}.{k} must be null for {absent}")
                continue
            v = c.get(k)
            if not isinstance(v, str) and not (
                isinstance(v, dict)
                and isinstance(v.get("type"), str | None)
                and isinstance(v.get("value"), str)
            ):
                raise ValueError(f"{where}.{k} is not source text or {{type, value}}")
    return cast(Diff, d)  # shape checked above


def normalize(cat: str, src: Source) -> str:
    """
    Comparison key: the AST for code (drops comments and docstrings), the value otherwise.
    """
    if cat not in CODE or not isinstance(src, str):
        return json.dumps(src, sort_keys=True)
    try:
        tree = ast.parse(textwrap.dedent(src))
    except SyntaxError:
        return " ".join(src.split())
    for node in ast.walk(tree):
        body = getattr(node, "body", None)
        if (
            isinstance(body, list)
            and body
            and isinstance(body[0], ast.Expr)
            and isinstance(getattr(body[0].value, "value", None), str)
        ):
            del body[0]
    return ast.dump(tree)


def ensure_pysetup_python(specs: Path) -> None:
    """
    Re-exec under an interpreter that can import pysetup: the checkout's own .venv if it1
    has one, otherwise an ephemeral `uv run` env with the deps pinned in its pyproject.
    """

    if os.environ.get("FORKDIFF_BOOTSTRAPPED"):
        return
    venv = specs / ".venv" / "bin" / "python"
    if venv.exists():
        # compare prefixes, not executables: every uv venv symlinks the same managed CPython
        if Path(sys.prefix).resolve() != venv.parents[1].resolve():
            os.execv(venv, [str(venv), MAIN, *sys.argv[1:]])
        return

    def importable(name):
        try:
            return importlib.util.find_spec(name) is not None
        except ModuleNotFoundError:
            return False

    if importable("marko") and importable("ruamel.yaml"):
        return
    uv = shutil.which("uv")
    if not uv:
        sys.exit(
            "pysetup needs marko + ruamel.yaml on Python >= 3.10; "
            f"create {specs}/.venv or install uv"
        )
    meta = "".join(
        p.read_text() for p in (specs / "pyproject.toml", specs / "setup.py") if p.exists()
    )
    py = re.search(r'requires-python\s*=\s*"([^"]+)"', meta)
    deps = [m.group(0) for m in re.finditer(r"(?:marko|ruamel\.yaml)==[\d.]+", meta)] or [
        "marko",
        "ruamel.yaml",
    ]
    os.environ["FORKDIFF_BOOTSTRAPPED"] = "1"
    cmd = [
        uv,
        "run",
        "--no-project",
        "--python",
        py.group(1).replace(" ", "") if py else ">=3.10",
        *(a for d in deps for a in ("--with", d)),
        "python",
        MAIN,
        *sys.argv[1:],
    ]
    os.execv(uv, cmd)


def cmd_diff(a: argparse.Namespace) -> None:
    specs = Path(a.specs).expanduser().resolve()
    out = Path(a.output).resolve() if a.output else None

    # consensus-specs should be checked-out.
    if not (specs / "pysetup").is_dir():
        sys.exit(
            f"no pysetup in {specs}; "
            "run `git submodule update --init consensus-specs` or pass --specs"
        )

    # Prepare the Python environment for pysetup.
    ensure_pysetup_python(specs)

    # pysetup resolves specs/<fork> relative to cwd
    os.chdir(specs)
    sys.path.insert(0, str(specs))

    from pysetup.generate_specs import get_spec, load_config, load_preset
    from pysetup.helpers import collect_prev_forks
    from pysetup.md_doc_paths import get_md_doc_paths
    from pysetup.spec_builders import spec_builders

    preset = load_preset(tuple(sorted(Path("presets", a.preset).glob("*.yaml"))))
    config = load_config(Path("configs", f"{a.preset}.yaml"))

    def symbols(fork: str) -> SymbolTable:
        out: SymbolTable = {}  # later docs override earlier ones, like combine_spec_objects
        for doc in get_md_doc_paths(fork).split():
            so = get_spec(Path(doc), preset, config, a.preset)
            for cat in CATEGORIES:
                for name, val in getattr(so, cat).items():
                    if cat == "protocols":
                        for meth, src in val.functions.items():
                            out[(cat, f"{name}.{meth}")] = {"src": src, "doc": doc}
                    elif hasattr(val, "_fields"):  # VariableDefinition
                        out[(cat, name)] = {
                            "src": {"type": val.type_name, "value": val.value},
                            "doc": doc,
                        }
                    else:
                        out[(cat, name)] = {"src": val, "doc": doc}
        builders = [spec_builders[f] for f in collect_prev_forks(fork) if f in spec_builders]

        # deprecate_* hooks appeared after v1.6.0; older checkouts have none
        def hook(b, name):
            return getattr(b, name, lambda: set())()

        gone_fn = set().union(*(hook(b, "deprecate_functions") for b in builders))
        gone_ct = set().union(*(hook(b, "deprecate_containers") for b in builders))
        for cat, name in list(out):
            if (cat == "functions" and name in gone_fn) or (cat in CONTAINERS and name in gone_ct):
                del out[(cat, name)]
        return out

    # Compute symbols both for "from" and "to" forks.
    old, new = symbols(a.from_fork), symbols(a.to_fork)

    # Accumulate changes.
    changes: list[Change] = []
    for cat, name in sorted(set(old) | set(new)):
        o, n = old.get((cat, name)), new.get((cat, name))
        sym = n or o
        assert sym is not None  # every key came from old or new
        kind: Kind

        # New symbol added.
        if o is None:
            kind = "added"

        # Symbol removed.
        elif n is None:
            kind = "removed"

        # Symbol unchanged.
        elif o["src"] == n["src"]:
            continue

        # Symbol changed only in documentation.
        elif normalize(cat, o["src"]) == normalize(cat, n["src"]):
            kind = "doc_only"

        # Symbol changed in its definition.
        else:
            kind = "changed"
        changes.append(
            {
                "category": cat,
                "name": name,
                "kind": kind,
                "doc": sym["doc"],
                "old": o and o["src"],
                "new": n and n["src"],
            }
        )

    # Get the current Git revision.
    rev = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()

    # Construct the result dictionary.
    result: Diff = {
        "specs": str(specs),
        "rev": rev,
        "preset": a.preset,
        "from": a.from_fork,
        "to": a.to_fork,
        "changes": changes,
    }

    text = json.dumps(result, indent=1)
    if out:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
    else:
        print(text)

    counts = defaultdict(int)
    for c in changes:
        counts[c["kind"]] += 1

    # Print a summary of changes.
    print(
        f"{a.from_fork} -> {a.to_fork} @ {rev[:12]} ({a.preset}): "
        + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())),
        file=sys.stderr,
    )
