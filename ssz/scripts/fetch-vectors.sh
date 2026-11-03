#!/bin/sh
# Download the ssz-specs test vectors, check their digest, export the types they
# name, and flatten them into _vectors/ for test/run_vectors.exe. Needs gh, git,
# uv and python3.
set -eu
cd "$(dirname "$0")/.."
cache=${SSZ_VECTORS_CACHE:-_vectors/cache}
mkdir -p "$cache"

fetch() { # repo tag asset sha256
  f="$cache/$2-$3"
  [ -f "$f" ] || gh release download "$2" -R "$1" -p "$3" -O "$f"
  echo "$4  $f" | shasum -a 256 -c - >/dev/null || { echo "digest mismatch: $f" >&2; exit 1; }
  echo "$f"
}

specs=$(fetch ethereum/ssz-specs v0.1.0 ssz-test-vectors-v0.1.0.tar.gz \
  e2a65f032b59835c26127295293ea1bc07d7ca0ea1fe0e4f1128dffed333f878)

tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
tar xzf "$specs" -C "$tmp"

# The vectors name their types only; the definitions are the fillers' Python classes.
git clone -q --depth 1 --branch v0.1.0 https://github.com/ethereum/ssz-specs "$tmp/src" 2>/dev/null
[ "$(git -C "$tmp/src" rev-parse HEAD)" = 7bce07ff7d51b1a3c66ff4e2bd3233ac248ede70 ] ||
  { echo "ssz-specs v0.1.0 moved" >&2; exit 1; }
uv run -q --project "$tmp/src" python scripts/ssz_specs_schema.py --fillers "$tmp/src" > _vectors/ssz_specs.json

python3 scripts/build_vectors.py --ssz-specs "$tmp/fixtures/ssz/ssz" --out _vectors
