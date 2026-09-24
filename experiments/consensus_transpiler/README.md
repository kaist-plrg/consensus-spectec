# Consensus specification transpilation experiment

This experiment generates SpecTec bodies from consensus-spec Python using the handwritten Capella specification as the target reference. It translates Python paths into declarative rules, preserves fallthrough and short-circuit evaluation, and expresses reachable exception sites as explicit premises.

The executable slice contains eight selected definitions inherited by Capella from Phase0. It generates 16 paths and passes 352 three-way comparisons between pinned Python, handwritten SpecTec, and generated SpecTec across the IL and SL interpreters. These are bounded tests of selected definitions. Capella-specific withdrawals and BLS changes are outside this slice.

## Translation

The source is consensus-specs v1.6.0 at `f96d3e7acf35125295d234da4b0c67591fdef49c`, matching this repository's submodule pin. Mainnet matches the handwritten constants. The upstream builder composes Capella and its ancestors. Each translated body must match an original Markdown AST exactly. The report records source locations, source and reference hashes, the assembled Python hash, and runtime versions.

`capella.py` generates bodies from Python ASTs. `capella_interfaces.py` generates uniform declarations from source signatures and the existing type mapping. State-mutator relations take positional inputs followed by `~>` and the resulting state. Pure functions retain their source names. Argument names use typed prefixes, such as `validatorIndex_index`, so they resolve under SpecTec's variable conventions. Effect contracts cover the eight selected definitions and the read-only dependencies `get_current_epoch` and `compute_epoch_at_slot`. Function calls require a reviewed read-only contract and a handwritten target interface. Types, containers, and helper dependencies remain handwritten.

`capella_reference.json` describes the handwritten oracle interfaces. The comparison harness adapts those interfaces to the generated ones through forwarding rules. These adapters contain no copied guards or state computations. They only connect positional arguments and results, so handwritten callers can keep their notation. They do not extract computational helpers from source branches.

The lowerer carries an environment and premises for each source path. An early return ends its path. A continuation after an `if` is translated under both branch conditions and remains inline on each path. Boolean expressions and chained comparisons split along paths that Python evaluates. Exception guards belong to each path that reaches the operation. A failed guard cannot select the complementary source branch. State assignments produce updated record values. Redundant guards are permitted. Shared implication analysis and optional output simplification are future work.

Local assignments capture scalar, record, and sequence values in fresh SpecTec variables. Saved child values retain their contents when a state field or sequence element is independently replaced. This matches the pinned SSZ runtime's read-only child views. Copying a local binding and reading it after either branch are supported. Capturing the mutable root state, writing through a saved local, and calling a helper with unreviewed effects raise errors.

Loops, narrowing casts, nested record mutation, and unsupported expressions also raise errors. The lowering rules are experimental and validated only for the selected bodies and regression fixtures. Extending the selection requires reviewing the relevant operations and their SSZ behavior.

## Observation boundary

The translation contract preserves returned values and final state on success, and rejection on failure. Failed premises produce no successful output state. Python's partially modified state after an exception is outside the observation boundary. This contract does not imply rollback of Python mutations. Exception classes and messages are diagnostic information, not equality criteria.

Exception recovery is outside the supported fragment. A caller that catches an exception and reads the partially modified state requires a different observation boundary. Failure guards still apply only to operations reached on the source path, and failure cannot fall through to a successful alternative.

## Results

| Python definition | Generated paths | Comparisons across IL and SL | Expected rejections |
| --- | ---: | ---: | ---: |
| `increase_balance` | 1 | 24 | 10 |
| `decrease_balance` | 2 | 24 | 4 |
| `get_previous_epoch` | 2 | 18 | 0 |
| `get_finality_delay` | 1 | 90 | 42 |
| `get_block_root_at_slot` | 1 | 20 | 10 |
| `is_active_validator` | 3 | 80 | 0 |
| `is_slashable_validator` | 4 | 80 | 0 |
| `process_eth1_data_reset` | 2 | 16 | 0 |
| Total | 16 | 352 | 66 |

The 176 test rows contain 163 distinct function/input combinations. Finality-delay boundary values produce 13 repeated rows. Cases include invalid indices, intermediate overflow, underflow, epoch boundaries, predicate boundaries, and both reset outcomes. Every row runs in both interpreters against the handwritten and direct generated entry points, yielding 352 three-way comparison records. Complete handwritten and generated SpecTec outputs are compared. Python comparisons check returned values or all supplied state fields, including sentinel fields that should remain unchanged. Expected exceptions are compared as rejection, without requiring matching exception classes or messages.

The 64 adapter checks reuse the 32 input rows for the three mutators in both interpreters. They compare calls through the forwarding adapters with direct generated calls and add no new source-function coverage. The default and custom-presentation runs both pass all checks.

Python inputs use real SSZ objects. The SpecTec fixture reader uses handwritten types and fills omitted fields with zero, false, or empty sequences. Untouched vectors therefore need not have their SSZ lengths. This harness does not validate complete SSZ states or execute official state-transition vectors.

The mechanically selected dependency slices contain eight selected definitions, two handwritten helpers, and five constants. The adapted variant additionally includes three forwarding relations. All target type declarations remain present. The complete handwritten corpus parses and elaborates but first fails structuring in `$get_domain`, which has two final `otherwise` clauses. Further structuring limitations remain behind that failure. Full-corpus SL integration remains unverified.

Twenty Capella regression test methods cover uniform interfaces, presentation overrides, adapter forwarding, variable-name collisions, malformed overrides, unsupported signatures, early returns, branch continuations, failure without fallthrough, saved values, and unsupported effects. Synthetic fixtures compare actual Python execution with generated IL and SL results for overflow after an earlier state update, saved checkpoints across field replacements and branches, saved sequences across element updates, saved records across element replacements, and read-only calls using saved records. Each method may contain several cases or assertions, so its count is separate from comparison records. Writes through local references, mutable root capture, unreviewed calls, locally shadowed helpers or casts, reads before local assignment, and loops are rejected. These fixtures do not establish translation of the full `weigh_justification_and_finalization` function. The inventory has six tests. The separate scalar prototype has four tests, including 1,252 Python/interpreter comparisons on numeric boundaries.

## Reproduce

Use this repository's OCaml dependencies with opam switch `5.1.0`. Python 3.12 and the pinned upstream dependency lock were used for the recorded run. Run these commands from the worktree root.

```sh
export CAPELLA_SOURCE=/absolute/path/to/consensus-specs-capella
git clone --depth 1 --branch v1.6.0 https://github.com/ethereum/consensus-specs.git "$CAPELLA_SOURCE"
uv sync --project "$CAPELLA_SOURCE" --python 3.12 --frozen --no-install-project

opam exec --switch=5.1.0 -- dune build --profile=release experiments/consensus_transpiler/runner.exe

"$CAPELLA_SOURCE/.venv/bin/python" experiments/consensus_transpiler/verify_capella.py \
  "$CAPELLA_SOURCE" \
  --reference spec/spec_capella \
  --output experiments/consensus_transpiler/output/capella \
  --runner _build/default/experiments/consensus_transpiler/runner.exe

"$CAPELLA_SOURCE/.venv/bin/python" -m unittest discover \
  -s experiments/consensus_transpiler -p test_capella.py -v
python3 -m unittest discover -s experiments/consensus_transpiler -p test_inventory.py -v
```

The revision must match exactly and tracked source files must be clean. Assembly writes generated Python modules inside the source checkout. Run generation sequentially for a given checkout.

Optional presentation overrides are supplied explicitly with `--presentation-overrides /path/to/overrides.json` to generation or verification. Each key names a selected source function. An `arguments` object can replace its complete source-to-target argument-name mapping. For mutators, `relation` can replace the public relation name and `notation` can specify custom tokens around positional placeholders. For example:

```json
{
  "increase_balance": {
    "arguments": {"state": "state", "index": "vid", "delta": "delta"},
    "notation": "{state} '.' BALANCES `[ {index} `] '+' {delta} ~> {result}"
  }
}
```

Notation must contain each input in source order followed by `{result}`, exactly once, and use supported notation tokens. Overrides cannot supply bodies, guards, types, or a new effect classification. Unknown keys, unsupported notation, invalid variable prefixes, and name collisions are rejected. The report records override contents and their file hash separately from the oracle mapping.

The ignored `output/capella/` directory contains:

- `generated.spectec`: eight generated definitions with the chosen public interfaces for review.
- `report.json`: provenance, interface metadata, comparison adapters, and each path's premises, locations, and reasons.
- `manual.spectec` and `replaced.spectec`: complete reference text and replacements with forwarding adapters rendered to a separate file.
- `manual_test.spectec` and `replaced_test.spectec`: dependency slices with test wrappers.
- `validation.json`: comparison results, entry points, and dependency closures.
- `cases.jsonl`, `generated_cases.jsonl`, and `adapter_cases.jsonl`: handwritten, direct generated, and mutator-forwarding interpreter inputs respectively.

The original `spec/spec_capella/` files are not edited. Review the open choices in [DECISIONS.md](DECISIONS.md).

## Separate Gloas scalar prototype

`inventory.py`, `assemble.py`, `scalar.py`, `scalar_runtime.spectec`, and `verify.py` support a separate experiment pinned to Gloas v1.7.0-beta.1 at `477321355d48d527e7e1e4d572f6a40a0b41072a`. Its integer helper representation does not establish reproduction of the handwritten Capella translation style.

It emits 17 of 417 assembled functions and reports 400 blocked definitions. Four emitted functions originate in Gloas. Recorded scalar comparisons pass for minimal (1,676) and mainnet (1,872). Its environment uses `eth_consensus_specs` and `ssz.uint`, whereas Capella uses `eth2spec` and `remerkleable`. Keep the environments separate. These counts are independent of the Capella results.
