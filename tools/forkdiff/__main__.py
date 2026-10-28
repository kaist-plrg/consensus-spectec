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
from .plan import cmd_plan  # noqa: E402


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
    q.add_argument("diff", help="JSON from `diff`")
    q.add_argument("--from", dest="from_dir", required=True, help="previous fork's spec dir")
    q.add_argument("--to", required=True, help="output dir (only *.spectec + PLAN.md are written)")
    q.add_argument(
        "--docs",
        nargs="+",
        default=["beacon-chain.md"],
        help="upstream doc basenames in scope, or `all` (default: beacon-chain.md)",
    )
    q.add_argument("--tag", help="fork tag for TODO comments (default: diff's `to`)")
    q.add_argument("--force", action="store_true")
    q.set_defaults(fn=cmd_plan)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
