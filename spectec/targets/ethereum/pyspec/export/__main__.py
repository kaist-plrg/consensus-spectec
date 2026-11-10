import argparse
import json
from pathlib import Path

from .document import export
from .error import Unsupported

parser = argparse.ArgumentParser(
    description="Export the reviewed Capella functions as one module document"
)
parser.add_argument("source", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
args.output.parent.mkdir(parents=True, exist_ok=True)
try:
    document = export(args.source.resolve())
except Unsupported as error:
    raise SystemExit(f"{args.source}: {error}")
args.output.write_text(json.dumps(document, indent=2) + "\n")
