# forkdiff

Fork-porting helper for the SpecTec translation.

- `diff` reports what changed upstream between two consensus-specs forks.
- `plan` copies the previous fork's SpecTec and stubs every definition whose upstream
  source changed, leaving a TODO with the Python diff.

## Usage

```sh
git submodule update --init consensus-specs        # once; the default upstream source
uv tool install -e tools                           # once; puts `forkdiff` on PATH
forkdiff diff capella deneb -o build/forkdiff/capella-deneb.json
forkdiff plan build/forkdiff/capella-deneb.json --from spec/spec_capella --to build/spec_deneb
./spectec-core elab build/spec_deneb/*.spectec     # warnings = remaining TODOs
```

- Without installing: `uv run --project tools forkdiff ...`. Needs Python >= 3.10,
  which `uv` provides.
- `diff` re-executes itself under the checkout's `.venv` if it has one, otherwise
  under `uv run` with the checkout's pinned `marko` and `ruamel.yaml`.
- `diff --specs <dir>` uses another checkout. Removals are only reported by
  checkouts newer than the submodule pin (v1.6.0), which lacks the `deprecate_*` hooks.
- `plan --docs` limits the work to upstream docs by basename (default
  `beacon-chain.md`, or `all`). `plan --force` overwrites a non-empty `--to`.

## diff

- Builds each fork's effective definitions the way pysetup does: every doc from
  `md_doc_paths`, later docs overriding earlier ones, deprecated symbols dropped.
- Compares code by AST without docstrings, so a comment-only edit is `doc_only`.
- Writes the upstream commit and preset, plus each change's category, name, kind,
  source doc and old/new source.

## plan

Maps upstream symbols to SpecTec declarations by name: `process_x` ->
`relation ProcessX` or `dec $process_x` (plus helpers such as `ProcessSlots_loop`),
`BeaconState` -> `syntax beaconState`, `MAX_X` -> `dec $MAX_X`, engine methods ->
`builtin dec $ee_<method>`. Then, per change:

- Changed function: the `def` / `rule` blocks are replaced by `;; TODO(<fork>)`
  holding the Python diff and the old body commented out.
- Removed function: the same, without the old body.
- A bodiless `dec` / `relation` elaborates with only a warning, so, as with Lean's
  `sorry`, the `elab` warnings are the list of stubs left.
- Changed container, type alias or builtin: a TODO comment, since these cannot be stubbed.
- Changed integer constant: rewritten in place.
- Added type alias or integer constant: generated into `99-<fork>-todo.spectec`;
  other additions go there as TODOs with the Python source.
- `doc_only`: a `;; REVIEW(<fork>)` comment.

`PLAN.md` indexes all of this, plus callers of touched declarations and the
SpecTec-only helpers that only the stubbed bodies use (they often need the same change).

## Limits

- Never translates Python, and does not propose translation-only helpers or builtins
  (such as Deneb's `$make_versioned_hash`).
- Cannot show that an unchanged upstream function needs no SpecTec change. Check the
  callers table, `elab` and the official vectors.
- The block splitter is line-based (a block starts at a non-indented line). All
  current Capella and Deneb files round-trip byte for byte.

## Check

```sh
uv run --directory tools ruff check .
uv run --directory tools ruff format --check .
```

## Layout

| file | role |
|---|---|
| `__main__.py` | CLI (also `python -m forkdiff` from `tools/`) |
| `diff.py` | upstream symbol tables via pysetup, change classification, interpreter bootstrap |
| `spectec.py` | `.spectec` block model: parse, index, owner lookup, strip, insert, references |
| `plan.py` | apply the diff to a copy of the previous fork, render `PLAN.md` |
