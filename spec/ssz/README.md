# SSZ schemas

The executor's `hash_tree_root` builtins merkleize with the [`ssz`](../../ssz) library,
using one schema per fork and preset (mainnet only, so far):

| File | Source |
|---|---|
| `<fork>-<preset>.json` | every container of `eth_consensus_specs.<fork>.<preset>`, generated |
| `generate.py` | writes the schemas; fails if a SpecTec struct's fields differ from its container's |
| `build_static.py` | flattens `ssz_static` vectors for the `ssz_static` CI job |

The schemas are embedded in `spectec/targets/ethereum/builtins` at build time.
The fork is chosen when the executor runs; the preset is mainnet:

```sh
./spectecx ethereum run state-transition --spec-dir spec/spec_deneb \
  --fork deneb --pre pre.json --block block.json --output post.json
```

`x-spectec.types` in each schema maps SpecTec struct names to SSZ containers.
`SszImpl.to_ssz` turns SpecTec values into `ssz` values. It is the only code
that knows how those values are shaped.

## Regenerate

In the pyspec environment (`make -C consensus-specs build`):

```sh
uv run --project consensus-specs --no-sync python spec/ssz/generate.py
```

## Check

The `ssz_static` job in `.github/workflows/spec-tests.yml` checks every `ssz_static` type
with the schema and library alone. Each type SpecTec defines is also checked through the
builtins, from the same JSON the executor reads. To run the check locally, run the
commands of its last step, with `$RUNNER_TEMP` set to a scratch directory.

## Adding a fork

1. Add the fork to `FORKS` in `generate.py` and regenerate.
2. Embed the new files in the rule in `spectec/targets/ethereum/builtins/dune`, and list them in `SszImpl.schemas`.
3. Point new `$hash_tree_root_*` builtins at their containers in `SszImpl.builtins`.
