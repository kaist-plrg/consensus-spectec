# ssz

SSZ `hash_tree_root` for OCaml. Types and values follow the SSZ specification directly,
including EIP-7916 progressive lists and bitlists, EIP-7495 progressive containers and
EIP-8016 compatible unions. Serialization is out of scope.

- `ssz`: the merkleizer (depends on `digestif`; executables pick `digestif.c` or `digestif.ocaml`).
- `ssz.schema`: JSON type descriptors and values (adds `yojson`), format in `schema/ssz_schema.mli`.

```ocaml
let checkpoint = Ssz.Container [ ("epoch", Uint 8); ("root", Vector (Uint 1, 32)) ]
let root = Ssz.hash_tree_root_exn checkpoint (Fields [ Ssz.uint64 5L; Bytes (String.make 32 '\x01') ])
```

## Tests

The ssz-specs vectors are the oracle:

| Suite | Source | Cases |
|---|---|---|
| `ssz_specs` | ssz-specs `v0.1.0` test vectors | 109 valid |

```sh
scripts/fetch-vectors.sh   # gh, git, uv, python3; writes _vectors/ssz_specs.{json,jsonl}
dune test                  # SSZ_REQUIRE_VECTORS=1 fails instead of skipping without them
```

Invalid and decode-failure cases are skipped (they test deserialization).

The vectors name their types only. `fetch-vectors.sh` exports the type definitions from
the ssz-specs v0.1.0 fillers with `scripts/ssz_specs_schema.py`, the only code that reads
another SSZ implementation's type API.
