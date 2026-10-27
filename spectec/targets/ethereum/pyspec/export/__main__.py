import argparse
import json
from pathlib import Path

from .document import export

parser = argparse.ArgumentParser(
    description="Export the supported Capella source subset for OCaml"
)
parser.add_argument("source", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--function", required=True)
args = parser.parse_args()
document = export(args.source.resolve(), args.function)
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(document, indent=2) + "\n")
