# Pyspec translator

`spectec.targets.ethereum.pyspec` translates exported consensus-spec Python into SpecTec EL definitions. It requires reviewed source signatures, runtime type metadata, effects and target presentation declarations. The sections below state the semantics it preserves, the Python subset it accepts and the known gaps.

## Semantics

Python from the pinned consensus-specs source defines the semantics. A generated definition has one clause per Python path, and each clause carries the premises under which Python takes that path. An assertion, bound check, overflow or division by zero that a path reaches becomes a premise of every clause on that path. An input that fails such a check therefore matches no clause, and the call rejects where Python raises. Clause order and `otherwise` never stand in for Python control flow, so a failing check cannot fall through to a later clause.

Translation preserves results and the complete post-state on success, and rejection on failure. It does not preserve exception classes, messages or partial state after a failure. Translation rejects a construct outside the subset below with a source-located diagnostic.

## Supported subset

- **Source.** One pinned consensus-specs revision, v1.6.0 at `f96d3e7acf35125295d234da4b0c67591fdef49c`, with the Capella fork composition and the mainnet preset. A translated body must match its Markdown source exactly, apart from the reviewed qualification of configuration constants and the builder's replacement of BLS public-key aggregation.
- **Functions and effects.** `REVIEWED_EFFECTS` lists the translatable functions as pure functions or root-state mutators. A call needs a reviewed effect, and effects are never inferred. A state mutator passes the updated state to later statements. A pure helper called inside a set loop needs a read footprint in `REVIEWED_STATE_READS`.
- **Types.** `TYPE_NAMES` maps source types to the handwritten target types, and SSZ element, length and limit metadata travels with each document. Translation rejects an unknown type. Target naturals and sequences do not encode SSZ widths or limits, so each reached operation emits its bound as a premise.
- **Arithmetic.** Addition, subtraction, multiplication, floor division and modulo are checked at the operand's unsigned width. A plain-integer operand is coerced with explicit bounds, and translation rejects two unsigned operands of different widths. Plain-integer division and modulo need syntactically nonnegative operands, because Python floors where the target truncates. Exponentiation needs an exponent known to be nonnegative. Right shifts yield zero at or above the operand width. Bitwise operations take two uint8 values or two nonnegative plain integers. Floats are unsupported.
- **Records and bytes.** Only the types in `REVIEWED_RECORD_CONSTRUCTORS` construct by name, with every field written once as a keyword. Field values convert only through reviewed representation-preserving conversions, and a fixed vector field emits an exact-length premise. `Bytes32`, `Root`, `Domain`, `ExecutionAddress` and `BLSPubkey` construct with no argument or one byte string of the declared width.
- **Sequences.** Indexing emits bound premises. Fixed bitvector slices and byte slices need nonnegative literal or constant bounds. Translation rejects dynamic, negative and stepped slices and general list slicing. Comprehensions with one generator, `sum`, `all`, `min`, `max`, `sorted` with numeric or tuple keys, `zip`, `enumerate`, `range`, `count` and `index` are supported over materialized sequences. A fixed-length `all` up to the document's expansion limit expands inline, and longer or unknown lengths use a recursive helper.
- **Sets.** A set is a duplicate-free sequence. Its reviewed consumers are membership, sums, sorting, intersection and statement loops whose iterations commute: writes at the loop element, accumulation by addition and fresh locals. Translation rejects any consumer that could observe Python's iteration order.
- **Control flow.** Early returns, `if` branches, assertions, `for` loops over ranges, sequences, sets, `zip` and `enumerate`, and `while` loops are supported. A loop becomes a recursive helper whose arguments are its carried values, the locals that the loop body assigns and later code reads. `break` returns the current carried values. A carried plain integer that the loop adds unsigned values to is a promoted accumulator. Its Python type changes at the first addition, so translation restricts its uses inside and after the loop.
- **Parameters.** A `None` default makes a parameter optional, and only an identity test against `None` may read it. A `True` or `False` default on a `bool` parameter keeps the present type and is bound at a call site that omits it.
- **Local helpers.** One nested mutator helper shape is supported. The helper must loop once over a sequence, apply a mutator to the root state and each element, and return `None`. It becomes one shared generic definition with a forwarding adapter for each mutator.
- **External engine.** `ExecutionEngine` is a unit handle with one operation, the new-payload check. Its boolean response is a request input, not a model of execution-layer validation. One invocation may reach only one engine.

## Known gaps

- **Default vector construction.** remerkleable fills a fixed vector from an empty list with default elements, so `SyncCommittee(pubkeys=[], ...)` holds 512 zero keys in Python. Translation rejects an untyped empty list, and a typed empty list fails in IL on the length premise.
- **Optional comprehension captures.** Translation rejects comprehensions and sort keys that read an optional parameter. Unused optional parameters do not become helper arguments.
- **Empty prefixes of saved bitvector slices.** For `saved = state.justification_bits[:2]`, both `all(saved[:0])` and `len(saved[:0])` fail target elaboration, because the saved bound has an integer type where slicing needs a natural.
- **Redundant paths.** Independent conditions on one value can produce clauses with contradictory premises. They never match, so they cost size but not soundness.

## Responsibilities

| Module | Contract |
| --- | --- |
| `Pyspec.Syntax` | Python-subset expressions and statements, and their structural traversals. |
| `Pyspec.Source` | SSZ descriptors, signatures, effects, presentation metadata and the source function, with no JSON or file-loading dependency. |
| `Pyspec.Error` | Translation rejection carrying a source region and message. Decoding, translation and assembly all reject through it. |
| `Pyspec.Source_json` | Export schema validation and JSON decoding. Produces `Source.t` values. |
| `Pyspec.Bundle` | A validated, nonempty set of source documents with unique functions that agree on shared call signatures and generic helpers, and the functions it infers to return Python lists. |
| `Kind` (private) | Source value categories, nominal type lookup, widths, sequence contracts and mutability. Its queries accept source type metadata and have no target AST or generation-context dependency. |
| `Store` (private) | Immutable local bindings, reference identity, read caches, origins and reference lifetime across writes and body entry. |
| `Loop_plan` (private) | Checks on source loops, ordered carried values and captures, restrictions on promoted accumulators, and independent, snapshot or live iterator access. It consumes generic storage facts and constructs no target syntax. |
| `List_results` (private) | Source analysis that identifies sequence-valued results across a bundle. |
| `Operand` (private) | Operands, which pair an EL expression with its source kind, the kind-to-EL type mapping and EL term constructors. |
| `Ctx` (private) | The context of one function's translation: its source document, fresh-name allocation, definition registry, and target declaration lookup. |
| `Branch` (private) | One execution branch: storage, premises, optional-parameter decisions, promoted accumulators and reached local helpers. Each finished branch becomes one clause. |
| `Spec_names` (private) | Consensus-spec names that translation recognizes. |
| `Python_builtins` (private) | The builtins a source document may call, and their resolution into operations and primitive contracts. |
| `Target_builtins` (private) | The Ethereum target's builtins that generated definitions call: their declarations, call builders and the SSZ hashing dispatch. |
| `Numeric_ops` (private) | Integer and unsigned arithmetic, bitwise operations, shifts, casts, extrema and index naturalization over evaluated operands. |
| `Byte_ops` (private) | Byte-string representation, concatenation, indexing, iteration, decoding and hashing. |
| `Sequence_ops` (private) | Sequence indexing, slicing, shape guards, concatenation, list literals and set construction. |
| `Ssz_ops` (private) | SSZ input validity, hashing, unsigned serialization and record construction. |
| `Call_ops` (private) | Reviewed call invocation with SSZ type arguments, primitive contracts and the execution engine. |
| `Operators` (private) | Python binary operators, dispatched by operand kind to the operation modules. |
| `Expr` (private) | Expression and condition translation: source evaluation order, short-circuiting, call argument binding and comprehensions. |
| `Write` (private) | Assignment destinations, state and reference writes, and their propagation through aliases. |
| `Effect` (private) | State-mutating calls, appends, local mutator helpers and the generic sequence helper. |
| `Loop` (private) | How a statement sequence finishes on each branch, and the recursive helpers built from loop bodies. |
| `Stmt` (private) | Statement translation, including the checks on `for` and `while` loops. |
| `Pyspec.Translate` | Bundle translation, signature checks and the generated entry definitions. |
| `Registry` (private) | Definitions grouped by explicit ownership during one translation, registration and declaration lookup. |
| `Pyspec.Assembly` | Bundle sharing, declaration ordering, target-context insertion of registered groups, and elaboration and structuring of the result. |

`Translate.bundle` translates every function of a bundle. It returns an abstract `Assembly.t` containing target definitions and source replacement symbols. A function's translation does not depend on the other functions in the bundle beyond the shared signatures and list-result inference. `Assembly.definitions` exposes the target definitions. `Bundle.make` validates source uniqueness and shared contracts before inference, so translation receives a validated bundle. `Assembly.replace` inserts generated definitions into a target context, replacing declarations and bodies owned by generated source functions.

## Python source and type extraction

The Python package in [export](export) writes the source documents that `Source_json` decodes, so the two change together. `export.load` builds the pinned pyspec module from its Markdown sources. `export.provenance` selects source bodies and verifies Markdown, configuration and optimized-BLS provenance for both single-function export and batch consumers. `export.document` exports a function's syntax, runtime SSZ metadata, constants and state reads. `export.interface` derives presentation declarations from source signatures. `export.metadata.capella` holds the reviewed per-fork facts: the pinned revision, type names, effects, state reads, record constructors, fresh results and cache keys. `python -m export SOURCE OUTPUT --function NAME` exports one function, with `spectec/targets/ethereum/pyspec` on `PYTHONPATH`.

Python fixtures and pinned translation outputs live in `spectec/test/pyspec`. Neither the library nor source extraction depends on that directory.

## Commands

`spectec ethereum translate SOURCES [--context FILE]...` translates a source bundle and prints the generated definitions. With `--context`, the command also inserts the generated definitions into the given spec, replacing the declarations they define, then elaborates and structures the result as a check. It exits with status 1 when a source is rejected or the check fails, and with status 2 on an internal fault. Its implementation is `spectec/bin/targets/eth_translate.ml`, in the Ethereum target's command group.

## Compiler reuse

The translator uses `Common.Source` for source regions and `Lang.El` for target syntax. Presentation declarations use `Spectec.parse_spec_source`. Consumers elaborate generated EL through `Spectec.elaborate`, structure the IL through `Spectec.structure` and execute it through the existing interpreters. Target text uses `Lang.El.Unparse`. Generated primitive calls use the existing Ethereum builtins.

| Concern | Existing functionality | Boundary |
| --- | --- | --- |
| Source decoding | `spectec.interface.json` decodes runtime values. | Python source documents have their own syntax and metadata schema. `Source_json` owns that schema. |
| Source value kinds | EL and IL define target types. | Source kinds additionally retain widths, capacities, ownership and the nominal types each operation accepts. Equal target representations do not establish equal source behavior. |
| Statement control | `Spectec.structure` structures IL. | Python evaluation order, mutation, break and return require source translation before elaboration. Statement translation returns a completion for each branch, which the loop builders use. |
| Target equality | `Lang.El.Eq` provides structural equality that ignores source positions. | Premise deduplication, path-condition lookup and context replacement use it. Type comparisons, read caches and reference identities use rendered text as keys, and target-name metadata is string-valued. |
| Free identifiers | `Lang.El.Free` analyzes EL syntax. | Source capture and mutation analyses operate on Python syntax and storage identities. They cannot use EL free identifiers as a substitute. |
| Diagnostics | `Spectec.Diagnostic` collects source-located compiler errors. | Source decoding and translation raise `Error.Rejected` with a region and a message. Parsing and elaboration use compiler diagnostics. |
| Fresh variables | `Lang.Il.Fresh` allocates typed IL variables. | The translator allocates EL patterns before elaboration, including tuple and iteration patterns under SpecTec's variable conventions. |

`Kind` classifies source values and their representations, and `Operand` maps those kinds to EL. The operation modules check evaluated operands and construct their target terms. `Expr`, `Stmt`, `Write`, `Effect` and `Loop` traverse source syntax and control evaluation order, effects and storage origins. Expression translation produces values, statement translation returns branch completions, and `Loop` uses them to construct helper clauses.

## Translation tests

`make test-pyspec` runs Dune output comparisons in `spectec/test/pyspec`. Each case extracts Python syntax and runtime type annotations, invokes `spectec ethereum translate`, and compares its output with a checked-in `.expected` file. `extract.py` only prepares source documents. The tests do not execute the source functions or generated definitions.

| Case | Pinned behavior |
| --- | --- |
| `arithmetic` | Unsigned bounds, signed division guards, optional parameters, boolean defaults and keyword calls. |
| `sequences` | Comprehension captures with an unused optional parameter, list alias updates, loop-carried values and `break`. |
| `state` | Checked field and element assignment, borrowed state-field updates, mutator calls and nested record writes. |
| `bytes` | Fixed-byte slicing, record construction, SSZ hashing and BLS call emission. |
| `rejected` | Source-located rejection of plain-integer division without nonnegative operands, with exit status 1. |
| `capella` | Production source selection and translation of `compute_epoch_at_slot` and `increase_balance`. |

Run from the repository root with OCaml 5.1.0 and the pinned source's locked Python 3.12 environment:

```sh
export CAPELLA_SOURCE=/absolute/path/to/consensus-specs-capella
git clone --depth 1 --branch v1.6.0 https://github.com/ethereum/consensus-specs.git "$CAPELLA_SOURCE"
uv sync --project "$CAPELLA_SOURCE" --python 3.12 --frozen --no-install-project
export CAPELLA_PYTHON="$CAPELLA_SOURCE/.venv/bin/python"
make test-pyspec SWITCH=5.1.0
```

Dune builds the translator and runs the extraction once per invocation. Extraction requires the exact source revision above and clean tracked files. It writes generated Python modules inside that checkout, so concurrent runs need separate checkouts. Intermediate source documents and actual output stay under `_build`. Review any output diff before running `opam exec --switch=5.1.0 -- dune promote`, then rerun the tests.

The Capella translation CI workflow runs this target on pull requests, main-branch pushes and manual runs. `make test-quick` excludes these tests because they require the external checkout and Python environment.
