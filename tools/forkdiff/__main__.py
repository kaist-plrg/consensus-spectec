"""
CLI entry point: the `forkdiff` console script.
"""

import argparse
import sys
from pathlib import Path

# Run as `python tools/forkdiff`: make relative imports work.
if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    __package__ = "forkdiff"

from . import __doc__ as DOC  # noqa: E402
from .diff import cmd_diff  # noqa: E402


def default_specs():
    """
    The repo's consensus-specs submodule: next to this package in a checkout, otherwise
    found upward from the cwd (the package may be installed elsewhere by uv).
    """

    here = Path(__file__).resolve().parents[2] / "consensus-specs"
    if (here / "pysetup").is_dir():
        return here
    for d in (Path.cwd(), *Path.cwd().parents):
        if (d / "consensus-specs" / "pysetup").is_dir():
            return d / "consensus-specs"
    return here


def main():
    p = argparse.ArgumentParser(
        description=DOC, formatter_class=argparse.RawDescriptionHelpFormatter
    )

    sub = p.add_subparsers(dest="cmd", required=True)

    # Subcommand 1: diff.
    d = sub.add_parser("diff", help="diff two forks' effective upstream definitions")
    d.add_argument("from_fork")
    d.add_argument("to_fork")
    d.add_argument(
        "--specs",
        default=str(default_specs()),
        help="consensus-specs checkout (default: the repo's submodule)",
    )
    d.add_argument("--preset", default="mainnet")
    d.add_argument("-o", "--output")
    d.set_defaults(fn=cmd_diff)

    # Subcommand 2: plan.
    q = sub.add_parser("plan", help="copy previous fork's SpecTec, stub out changed definitions")
    q.set_defaults(fn=lambda a: sys.exit("forkdiff plan: not implemented yet"))

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
