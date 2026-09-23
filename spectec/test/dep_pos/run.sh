#!/bin/sh
# Dependency mutation-report golden, invoked by `make test-dep`.
set -eu

dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../../.." && pwd)
cd "$root" # so the default spec dir (spec/spec_capella) resolves

log=$(mktemp "${TMPDIR:-/tmp}/spectec-dep.XXXXXX")
trap 'rm -f "$dir/pre.json" "$log"' EXIT
gunzip -c "$dir/pre.json.gz" > "$dir/pre.json"

if ! ./spectecx ethereum run state-transition \
  --fork capella \
  --pre "$dir/pre.json" \
  --block "$dir/block.json" \
  --dep-pos.output "$dir/dep_pos.actual" \
  --dep-pos.level summary \
  --dep-pos.targets-file "$dir/targets.txt" \
  --no-validate >"$log" 2>&1; then
  cat "$log" >&2
  exit 1
fi

if diff "$dir/dep_pos.expected" "$dir/dep_pos.actual"; then
  echo OK
  rm -f "$dir/dep_pos.actual"
else
  echo "MISMATCH: review the diff above, then run 'make promote' to accept"
  exit 1
fi
