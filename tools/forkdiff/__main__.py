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


def main():
    p = argparse.ArgumentParser(
        description=DOC, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("diff", help="diff two forks' effective upstream definitions")
    sub.add_parser("plan", help="copy previous fork's SpecTec, stub out changed definitions")
    a = p.parse_args()

    # TODO: Implement the actual diff and plan functionality.
    sys.exit(f"forkdiff {a.cmd}: not implemented yet")


if __name__ == "__main__":
    main()
