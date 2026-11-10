# Pyspec translator

Pyspec is the executable Python consensus specification. This library translates its exported functions into SpecTec EL definitions.

The exporter writes function syntax, signatures and runtime type metadata into one JSON module document. The translator reads that document and builds SpecTec declarations and bodies.

## Semantics

Python from the pinned consensus-specs source defines the semantics. A generated definition has one clause per Python path, and each clause carries the premises under which Python takes that path. An assertion, bound check, overflow or division by zero that a path reaches becomes a premise of every clause on that path. An input that fails such a check therefore matches no clause, and the call rejects where Python raises. Clause order and `otherwise` never stand in for Python control flow, so a failing check cannot fall through to a later clause.

Translation preserves results and the complete post-state on success, and rejection on failure. It does not preserve exception classes, messages or partial state after a failure. Translation rejects a construct outside the subset below with a source-located diagnostic.

## Supported subset

- **Source.** The translator accepts consensus-specs v1.6.0 at `f96d3e7acf35125295d234da4b0c67591fdef49c`, with the Capella fork and mainnet preset. The exporter reads bodies from the assembled module `tests/core/pyspec/eth2spec/capella/mainnet.py`, which contains the executable specification. It checks that each runtime definition starts at the corresponding source line and unwraps `cache_this` wrappers whose provenance passes the exporter's checks. It exports `config.X` as the constant `X`.
- **Functions and effects.** The exporter follows global names in bytecode to find the functions reached by `state_transition`. A `None` return annotation marks a state mutator, whose first parameter must be `state: BeaconState`. Other functions are pure.

  A state mutator passes the updated state to later statements. A pure helper called inside a set loop must list the state fields it reads in `REVIEWED_STATE_READS`.
- **Types.** `Names` maps Python type names to SpecTec built-in types and types defined in the handwritten specification.

  The module document records each type's SSZ element type, length and limit once.

  Translation rejects an unknown type. Target naturals and sequences do not encode SSZ widths or limits, so each reached operation emits its bound as a premise.
- **Arithmetic.** Addition, subtraction, multiplication, floor division and modulo are checked at the operand's unsigned width. A plain-integer operand is coerced with explicit bounds, and translation rejects two unsigned operands of different widths. Plain-integer division and modulo need syntactically nonnegative operands, because Python floors where the target truncates. Exponentiation needs an exponent known to be nonnegative. Right shifts yield zero at or above the operand width. Bitwise operations take two uint8 values or two nonnegative plain integers. Floats are unsupported.
- **Records and bytes.** Only types listed in `REVIEWED_RECORD_CONSTRUCTORS` construct by name, with every field written once as a keyword. The translator accepts field conversions only when they preserve the value's representation, and a fixed vector field emits an exact-length premise. `Bytes32`, `Root`, `Domain`, `ExecutionAddress` and `BLSPubkey` construct with no argument or one byte string of the declared width. `Bytes32` also accepts a generator or sequence of 32 integers, as in `xor`.
- **Sequences.** Indexing emits bound premises. Fixed bitvector slices and byte slices need nonnegative literal or constant bounds. Stored lists support prefix slices with nonnegative literal bounds or dynamic uint64 bounds. Translation rejects negative and stepped slices and other list slice forms. Comprehensions with one generator, `sum`, `all`, `min`, `max`, `sorted` with numeric or tuple keys, `zip`, `enumerate`, `range`, `count` and `index` are supported over stored sequences. `all` expands inline for a fixed sequence of at most four elements and uses a recursive helper otherwise.
- **Sets.** A set is a duplicate-free sequence. Its supported consumers are membership, sums, sorting, intersection and statement loops whose iterations commute: writes at the loop element, accumulation by addition and fresh locals. Translation rejects any consumer that could observe Python's iteration order.
- **Control flow.** When used as expressions, `and` and `or` preserve the selected numeric or boolean operand and skip later operands when its truth value determines the result. Early returns, `if` branches, assertions, `for` loops over ranges, sequences, sets, `zip` and `enumerate`, and `while` loops are supported. Each loop becomes a recursive helper. It takes every binding at loop entry and carries the state, local lists and previously bound locals assigned in its body. It returns these carried values unless the loop returns from the function.

  `break` returns the current carried values. A carried plain integer that the loop adds unsigned values to is a promoted accumulator. Its Python type changes at the first addition, so translation restricts its uses inside and after the loop.
- **Parameters.** A `None` default makes a parameter optional, and only an identity test against `None` may read it. A `True` or `False` default on a `bool` parameter keeps the parameter boolean and supplies its value when a call omits the argument.
- **Local helpers.** One nested mutator helper shape is supported. The helper must loop once over a sequence, apply a mutator to the root state and each element, and return `None`. It becomes one shared generic definition with a forwarding adapter for each mutator.
- **External engine.** The target represents `ExecutionEngine` as an empty tuple and supports its new-payload check. The check returns a boolean supplied in the Ethereum runner's request. It models no execution-layer validation. One invocation may reach only one engine.

## Known gaps

- **Default vector construction.** remerkleable fills a fixed vector from an empty list with default elements, so `SyncCommittee(pubkeys=[], ...)` holds 512 zero keys in Python. Translation rejects an untyped empty list, and a typed empty list fails in IL on the length premise.
- **Optional comprehension captures.** Translation rejects comprehensions and sort keys that read an optional parameter. Unused optional parameters do not become helper arguments.
- **Empty prefixes of saved bitvector slices.** For `saved = state.justification_bits[:2]`, both `all(saved[:0])` and `len(saved[:0])` fail target elaboration, because the saved bound has an integer type where slicing needs a natural.
- **Redundant paths.** Independent conditions on one value can produce clauses with contradictory premises. Such clauses never match, but increase output size and evaluation time.

## Responsibilities

The OCaml implementation is organized by responsibility. `pyspec.ml` exposes the public API, and `Error` supplies source-located rejection across the areas.

| Area | Modules and responsibility |
| --- | --- |
| `input/` | `Syntax` describes accepted Python. `Names` supplies SpecTec type and builtin names for recognized source names. `Typed` validates declaration types and module metadata, infers Python-list results and assigns name roles. Function bodies remain `Syntax` until translation. |
| `values/` | `Value.t` pairs an evaluated EL expression with its source kind. `Value` retains source widths, sequence bounds and mutability, maps kinds to EL types and supplies EL constructors. |
| `context/` | `Ctx` looks up declarations and shares a fixed source and fresh-name counter across a function's paths. `Ctx.Registry` records definitions for the whole translation in emission order. `Branch` holds path premises and decisions. `Store` tracks bindings, aliases, origins, cached reads and reference lifetimes. |
| `operations/` | `Numeric_ops`, `Byte_ops`, `Sequence_ops` and `Ssz_ops` operate on evaluated values. `Call` prepares function calls. `Loop` plans loops and builds recursive helpers. `Library` resolves supported Python builtins and library functions. `Prelude` builds calls to the target builtins declared in `prelude.spectec`. |
| `translation/` | `Expr` evaluates expressions, dispatches operators and resolves call names for expressions and statements. `Write` handles assignments, appends and `set_or_append_list`, propagating updates through aliases. `Stmt` sequences statements and orchestrates loops. `Translate` builds declarations and entry clauses and orders the output. |

`Typed` uses `Names` for recognized identifiers, `Syntax` for bodies and `Error` for rejections. Operation modules take evaluated values and update premises and storage through `Branch` and `Store`. `Loop` takes callbacks from syntax traversal, so both `Call` and `Expr` can use its builders.

`Translate.translate` builds and parses each signature's declaration once, then translates functions with bodies in name order. All translated functions share one registry, which emits each shared helper once. The result is a `Lang.El.spec` with declarations before bodies and emission order preserved within each group. A function's clauses and helper names depend on other functions only through shared signatures and Python-list result inference.

`prelude.spectec` declares the target builtins and defines helpers whose text is independent of the translated body, including `$translated_set_or_append_list`. Generated definitions call the prelude, which must accompany the output.

## Python source and type extraction

The Python package in [export](export) writes the document that `Typed` decodes. Its schema is the contract between the exporter and translator, so the writer and decoder change together.

`export.load` assembles and imports the pinned module. `export.runtime` reads configuration, constants, cached functions and parameter defaults. `export.ssz` records runtime SSZ types. `export.syntax` emits reduced Python syntax. `export.uses` indexes each body's calls, names and bindings. `export.selection` follows calls from `state_transition` to derive the function set and effects and supplies the traversal used by state-read and engine checks. `export.checks` validates local helpers, state reads and execution-engine use. `export.document` assembles one JSON document.

The document contains Python names and metadata. The translator assigns SpecTec names. The exporter checks that library names refer to the expected objects.

`export.forks.capella` lists the pin, entry function, state reads, allowed constructors, fresh tuple results, cache keys and `set_or_append_list` source.

The exporter checks `set_or_append_list` against its listed source before admitting calls, because the prelude implements that body.

With `spectec/targets/ethereum/pyspec` on `PYTHONPATH`, `python -m export SOURCE OUTPUT` writes a module document to `OUTPUT`. It contains the pin, source filename, types, constants, library bindings, metadata tables and function entries. Each entry with a body carries its source span. An entry without a body supplies a callable signature without generating a definition. The type table records every unsigned class under its module binding name, so calls to these names resolve as casts.

Python fixtures and pinned translation outputs live in `spectec/test/pyspec`. Neither the library nor source extraction depends on that directory.

## Commands

```bash
make pyspec-capella
```

The target uses `CAPELLA_PYTHON` to export functions reached by `state_transition` from `CAPELLA_SOURCE`, then translates `_build/pyspec-capella/module.json`. It prints the output directory, `_build/pyspec-capella`. By default, the source is a v1.6.0 checkout at `consensus-specs-capella` and Python is that checkout's `.venv/bin/python`.

The directory holds `module.json`, generated `state-transition.spectec` and links to `prelude.spectec` and the handwritten `00-types` through `01-variables` files. `spectec ethereum run --spec-dir _build/pyspec-capella` uses it as a complete specification.

`spectec ethereum translate FILE` prints definitions from one module document. Those definitions need the prelude and handwritten type files to elaborate. The command exits with status 1 for unsupported source, an unreadable file or invalid JSON, and status 2 for an internal fault. `spectec/bin/targets/eth_translate.ml` implements the command.

## Compiler reuse

The translator uses `Common.Location` for source locations and `Lang.El` for target syntax.

Presentation declarations use `Spectec.parse_spec_source`. Consumers elaborate generated EL through `Spectec.elaborate`, structure the IL through `Spectec.structure` and execute it through the existing interpreters. Target text uses `Lang.El.Unparse`. Generated primitive calls use the existing Ethereum builtins.

| Concern | Existing functionality | Boundary |
| --- | --- | --- |
| Source decoding | `spectec.interface.json` decodes runtime values. | `Typed` decodes a separate schema for source syntax and metadata. |
| Source value kinds | EL and IL define target types. | Source kinds additionally retain widths, capacities, ownership and the nominal types each operation accepts. Equal target representations do not establish equal source behavior. |
| Statement control | `Spectec.structure` structures IL. | Python evaluation order, mutation, break and return require source translation before elaboration. Statement translation returns a completion for each branch, which the loop builders use. |
| Target equality | `Lang.El.Eq` provides structural equality that ignores source positions. | Premise deduplication and path-condition lookup use it. Type comparisons, read caches and reference identities use rendered text as keys, and target-name metadata is string-valued. |
| Free identifiers | `Lang.El.Free` analyzes EL syntax. | Source capture and mutation analyses operate on Python syntax and storage identities. They cannot use EL free identifiers as a substitute. |
| Diagnostics | `Spectec.Diagnostic` collects source-located compiler errors. | Decoding and translation raise `Error.Rejected` with a location and message. The command renders the rejection through `Spectec.Diagnostic`. Parsing and elaboration use compiler diagnostics. |
| Fresh variables | `Lang.Il.Fresh` allocates typed IL variables. | The translator allocates EL patterns before elaboration, including tuple and iteration patterns under SpecTec's variable conventions. |

## Translation tests

`make test-pyspec` runs Dune output comparisons in `spectec/test/pyspec`. Each fixture case extracts Python syntax and runtime type annotations, invokes `spectec ethereum translate`, and compares its output with a checked-in `.expected` file.

The checks use the dedicated `pyspec` Dune alias, so `dune test` omits them.

`extract.py` writes one module document per case.

The tests do not execute the source functions or generated definitions.

| Case | Pinned behavior |
| --- | --- |
| `arithmetic` | Unsigned bounds, signed division guards, optional parameters, boolean defaults and keyword calls. |
| `sequences` | Comprehension captures with an unused optional parameter, list alias updates, loop-carried values and `break`. |
| `state` | Checked field and element assignment, borrowed state-field updates, mutator calls and nested record writes. |
| `bytes` | Fixed-byte slicing, record construction, SSZ hashing and BLS call emission. |
| `rejected` | Diagnostics and exit status 1 for unsupported arithmetic, bitvector slices, optional loop reads, number-class changes, SSZ store conversions, missing files and invalid JSON. |
| `capella` | Production source selection and translation of `compute_epoch_at_slot` and `increase_balance`. |

The `capella` case exports bodies for `compute_epoch_at_slot` and `increase_balance`, which call no other functions. Fixture documents give fixture functions bodies and reached pyspec functions signatures only. Their spans refer to the fixture file.

The state-transition case exports every function reached by `state_transition`. It checks that `spectec struct` accepts the generated definitions with the handwritten Capella files and `prelude.spectec`.

Run from the repository root with OCaml 5.1.0 and the pinned source's locked Python 3.12 environment:

```sh
export CAPELLA_SOURCE=/absolute/path/to/consensus-specs-capella
git clone --depth 1 --branch v1.6.0 https://github.com/ethereum/consensus-specs.git "$CAPELLA_SOURCE"
uv sync --project "$CAPELLA_SOURCE" --python 3.12 --frozen --no-install-project
export CAPELLA_PYTHON="$CAPELLA_SOURCE/.venv/bin/python"
make test-pyspec SWITCH=5.1.0
```

Dune builds the translator and runs the extraction once per invocation. Extraction requires the exact source revision above and clean tracked files. It writes generated Python modules inside that checkout, so concurrent runs need separate checkouts.

Module documents and actual output files stay under `_build`.

Review any output diff before running `opam exec --switch=5.1.0 -- dune promote`, then rerun the tests.

The Capella translation CI workflow runs this target on pull requests, main-branch pushes and manual runs. `make test-quick` excludes these tests because they require the external checkout and Python environment.
