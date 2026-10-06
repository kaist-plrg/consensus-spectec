# ETH2SpecTec

ETH2SpecTec is a SpecTec implementation of the official Ethereum 2.0 Consensus Spec. It extends [SpecTecX](https://github.com/kaist-plrg/spectecx) with support for large byte values, and includes Python scripts for conversion as well as a differential-testing framework for Ethereum 2.0 clients.

## Installation

Create an OCaml switch:

```bash
opam switch create eth-spectec 5.1.1
eval $(opam env)
```

Install the forked SpecTec package and any optional upstream target packages from the checkout:

```bash
opam install ./spectec.opam
opam install ./spectec-target-p4.opam
opam install ./spectec-target-miniml.opam
opam install ./spectec-target-impty.opam
```

The `spectec` package includes the Ethereum command plugin and the Capella and Deneb specifications. Each optional target package installs its own command plugin and default specification. The `spectec` executable discovers installed target plugins at startup.

For development, install every package's pinned dependency versions without installing the packages themselves:

```bash
opam install . --deps-only --locked
```

The lockfile (`spectec.opam.locked`) records the exact transitive dependency set CI uses. The unlocked constraints live in `dune-project` and surface in the generated opam files.

## Testing Scripts

### 1. Docker Setup

**Environment:**

- **Base Image:** Ubuntu 22.04 LTS
- **Requirements:** Docker installed on your system
- **Platform:** Linux (x86_64), macOS, or Windows with WSL2
- **Architecture:** the client images are `linux/amd64` only. The Go, Nim and JDK installs use amd64 paths, so on Apple Silicon pass `--platform=linux/amd64` and build under emulation.

The Dockerfile provides a reproducible, isolated environment for building and testing all Ethereum 2.0 client implementations (Lighthouse, Prysm, Nimbus, Teku, Lodestar) with coverage instrumentation support.

**What it does:**

1. Installs all required dependencies:
   - Rust (stable + nightly with llvm-tools-preview)
   - Go 1.25.1 (for Prysm)
   - Java 21 (OpenJDK for Teku)
   - Node.js 20 (for Lodestar)
   - Nim 1.6.20 (for Nimbus)
   - Python 3 with dependencies (including snappy for decompression)
   - Coverage tools: lcov, go-bcov, llvm-profdata, JaCoCo, c8
   - OCaml 5.1.1 and locked build dependencies (for the spectecx executable)
2. Sets up the environment for building spectecx executable:
   - Installs OCaml compiler and opam package manager
   - Configures build environment for spectecx
3. Clones and builds client implementations:
   - Lighthouse (v8.0.1)
   - Prysm (v7.0.0)
   - Nimbus (v25.11.1)
   - Teku (25.11.1)
   - Lodestar (v1.36.0 @state-transition)
4. Applies the client changes needed for differential testing:
   - `patches/<client>/*.patch`: edits to existing client source, applied
     with `git apply --3way`. This is the primary mechanism; each patch is a
     numbered, self-describing commit exported from the client repository.
   - `modified_code/<client>/`: whole new files copied into the client tree
     (the spectec subcommands for Lighthouse's `lcli` and Prysm's `pcli`, and
     the Lodestar driver scripts).
5. Builds both base binaries and coverage-instrumented binaries

**Build Docker Images:**

```bash
# Build base environment (clones and builds original clients)
docker build --platform=linux/amd64 -t eth2test:base --target base .

# Build with coverage binaries (recommended for coverage testing)
docker build --platform=linux/amd64 -t eth2test:coverage --target coverage .
```

On an x86_64 host `--platform=linux/amd64` is a no-op and may be omitted. The `ocaml` target builds only the system and OCaml dependency layers, without the client toolchains.

The Dockerfile leaves out the official test vectors. After building, start a container and run `make download-fixture` from `/workspace/spectec-core` before testing (see step 4). Downloaded vectors and cached archives disappear when the container is removed unless `/workspace/spectec-core/Converter` is stored in a persistent volume or bind mount.

### 2. Building the Project

**Use spectecx executable:**

```bash
# Inside the container:
cd /workspace/spectec-core

make exe
```

This creates an executable named `spectecx` in the project root. It runs the local build through the `eth-spectec` switch. Override the switch with `make exe SWITCH=<name>` when needed. The installed command is `spectec`.

```bash
# Print IL representation
./spectecx elab spec/spec_capella/*.spectec
```

### Structure

The SpecTec compiler consists of these main components.

* SpecTec EL is the surface language in which the spec is authored.
* SpecTec IL (internal language). EL -> IL conversion is called "elaboration". Elaboration makes the spec more algorithmic and unambiguous.
* SpecTec SL (structured language). IL -> SL conversion is called "structuring". Structuring groups related execution paths into explicit branching with over-approximation. This minimizes backtracking, making the SL interpreter much faster than the IL interpreter.
* Interpreter backends for IL, SL, and PL.
  * Needs to be coupled with a parser that converts an input file into a SpecTec IL value.

Repository layout:

```
spectec/lib/lang/        ASTs for EL, IL, SL, PL, and shared syntax
spectec/lib/pass/        parse, elaborate (EL→IL), structure (IL→SL)
spectec/lib/interp/      IL, SL, and PL interpreters, builtins, target interface
spectec/lib/cli/         reusable CLI machinery and target plugin loading
spectec/lib/spectec.ml   public facade (pipeline + eval + Error/Task/Target)
spectec/targets/<t>/     per-target code, builtins, and upstream target plugins
spectec/bin/targets/     Ethereum command modules and plugin registration
spectec/bin/main.ml      command-line entrypoint
spectec/test/            diff-based test drivers
spectec/testdata/        test inputs
```

### Commands

The P4, Mini-ML, and Impty examples require the corresponding target package. Ethereum support is included in this repository's `spectec` package.

```bash
# print out the IL representation of a SpecTec spec
./spectecx elab spec/spec_capella/*.spectec
# print the SL representation of a SpecTec spec
./spectecx struct spectec/specs/impty/base/spec.spectec

## P4-specific commands

# parse a P4 program to an IL value
p4_program=spectec/testdata/interp/p4/p4c/p4_16_samples/empty.p4
./spectecx p4 parse --spec-dir spectec/specs/p4 -i spectec/testdata/interp/p4/p4c/includes -p "$p4_program"

# run a P4 program based on SpecTec IL/SL
./spectecx p4 typecheck -i spectec/testdata/interp/p4/p4c/includes -p "$p4_program"
./spectecx p4 typecheck -i spectec/testdata/interp/p4/p4c/includes -p "$p4_program" --sl
```

Ethereum commands are grouped under `ethereum`:

```bash
# Run one state transition and export the validated post-state
./spectecx ethereum run state-transition --pre pre.json --block block.json --output post.json

# Collect premise coverage and save a resumable checkpoint
./spectecx ethereum coverage --batch-dir eth-tests --premise-coverage.level summary --checkpoint coverage.ckpt

# Generate mutations for selected uncovered premise UIDs
./spectecx ethereum testgen --coverage coverage.ckpt --premises-file targets.txt --test-dir eth-tests --output testgen_output
```

Ethereum commands use the packaged Capella specification by default. Pass `--spec-dir spec/spec_deneb` for Deneb, or repeat `--spec FILE` to select files explicitly. Target commands read `spectecx.config` in the current directory, with explicit flags taking precedence:

```text
ethereum.spec_dir = spec/spec_deneb
ethereum.batch_dir = eth-tests
```

`ethereum.spec` and `ethereum.spec_dir` are mutually exclusive. Test generation also uses `ethereum.batch_dir` as its seed directory unless `--test-dir` is given. Its `--verify` option is unsupported and returns an error.

The differential runner uses the same state-transition command. Its `--run-mode` accepts `il`, `sl`, or `pl`. Use `il` for the Capella and Deneb specifications. Structuring these specifications for SL or PL fails on definitions with multiple `otherwise` clauses.

```bash
python3 run_test_suite.py Converter/OfficialTestSuite/capella/sanity/blocks --converter-dir Converter --spectec-bin ./spectecx --fork capella --run-mode il
```

### Editor support

Integrations for `.spectec` files live in `editors/`:

- **Syntax highlighting** for VS Code, Emacs, and Vim/Neovim, one per subdirectory.
- **Diagnostics**: `make lsp` builds `spectecx-lsp`, a language server that reports parse and elaboration errors as you edit.

See [editors/README.md](editors/README.md) for installing a highlighter and turning on the language server.

### 3. Testing

```bash
make test
```

- `make test-quick` covers compiler fixtures, IL/SL/PL relation tests, CLI behavior, and a validated Capella state transition in IL.
- `make test` also runs the P4 interpreter corpus under `spectec/testdata/interp/p4`.
- `make test-dep` checks the Ethereum dependency-report fixture.
- `check_spec_tests.py` checks SpecTec against the official test vectors (see step 5).

### Adding a New Target

Targets live in `spectec/targets/<name>/`, separate from `spectec/lib/`. The reusable CLI infrastructure (`Target_cli`, `Task_cli`, `Subcommand` constructors) lives in `spectec/lib/cli/`. To add a target:

1. Implement `Spectec.Target.S` and one or more `Spectec.Task.S` in `spectec/targets/<name>/`.
2. Add target-specific built-ins under `spectec/targets/<name>/builtins/`.
3. For each task, implement a `Cli.Task_cli.S` module that parses command-line flags into the task's input.
4. Compose those task-CLIs into a `Cli : Cli.Target_cli.S` module using `Cli.Subcommand` constructors (`make_task`, `make_parse`, `make_batch`, `make_checkpoint`).
5. Add a plugin entry module that calls `Cli.Target_registry.register (module Your_target.Cli)` when loaded.
6. Declare a target package in `dune-project`, including any named installation directories for packaged specifications.
7. Add a Dune `plugin` stanza that installs the entry module in the core package's `target_plugins` directory. Use `generate_sites_module` when target code needs to locate packaged specifications.

Ethereum is bundled with the core package. P4, Mini-ML, and Impty have separate packages. Each target registers through a plugin, so adding a target does not require changing `spectec/bin/main.ml`.

Run the checkout commands from the repository root, where `Makefile` is located.

### 4. Fetch the official test vectors

The official consensus test vectors are release assets of
[ethereum/consensus-specs](https://github.com/ethereum/consensus-specs/releases/tag/v1.6.0),
not content of this repository. Pull them before running the converter or
`diff_testing.py`:

```bash
# Inside the container:
cd /workspace/spectec-core

make download-fixture
```

This downloads the pinned `mainnet.tar.gz` (v1.6.0, matching the `consensus-specs`
submodule) once into
`Converter/.fixture-cache/` and unpacks the Capella and Deneb `sanity`, `random`
and `finality` suites into `Converter/OfficialTestSuite/<fork>/<suite>/...`, the
layout the scripts below expect. Both directories are gitignored.

The SHA-256 digest pinned in the Makefile is checked on every run, including
cached downloads. Each run extracts the selected suites into a temporary
directory, then replaces the entire fixture tree after extraction succeeds.
The release URL, version, preset, checksum and selection are recorded in
`Converter/OfficialTestSuite/.fixture-info`. Existing directories are never
treated as proof of a complete extraction; suites outside the new selection
are removed. A failed download, checksum check or extraction leaves the
previous fixture tree intact and makes the target fail.

Narrow or widen the selection on the command line. For a different release or
an unpinned preset, supply its published SHA-256 digest with
`SPEC_TESTS_SHA256`; update the `consensus-specs` submodule to match the release.

```bash
make download-fixture SPEC_TESTS_FORKS=capella SPEC_TESTS_SUITES="sanity random"
make download-fixture SPEC_TESTS_PRESET=minimal      # also has a pinned digest
make clean-fixture                                  # drop vectors, keep the tarball
```

### 5. Check SpecTec against the official test vectors

`check_spec_tests.py` checks SpecTec against the unpacked official vectors. A case with `post.ssz_snappy` must be accepted with a byte-identical post state. A case without a post state must be rejected by failed premises. Interpreter faults, CLI errors, and input errors fail the check.

The checker requires `make exe`, the Python packages in `requirements.txt` (installed in the Docker image), and the mainnet pyspec fork modules generated by `make -C consensus-specs _pyspec`.

The `Spec tests` workflow in [`.github/workflows/spec-tests.yml`](.github/workflows/spec-tests.yml) checks the mainnet `operations`, `epoch_processing`, `sanity/blocks`, and `random` suites for Capella and Deneb on every pull request. Pushes to `main` and manual dispatches also run the slower `finality` suite.

```bash
make -C consensus-specs _pyspec
make download-fixture SPEC_TESTS_SUITES="operations epoch_processing sanity/blocks random finality"
python3 check_spec_tests.py --jobs 4 Converter/OfficialTestSuite/deneb/operations
# Outside Docker, use the environment built by make _pyspec.
uv run --project consensus-specs --no-sync python check_spec_tests.py --jobs 4 Converter/OfficialTestSuite/deneb/operations
```

### 6. Run Converter scripts (eth2spec integration)

```bash
# Inside the container:
cd /workspace/spectec-core

# Make the spectec inputs (Example)
python3 Converter/generate_json_test_cases.py   Converter/OfficialTestSuite/capella/sanity/blocks/pyspec_tests   --fork capella  --output-dir eth-tests   -v
```

### 7. diff_testing.py

Performs differential testing across multiple Ethereum 2.0 clients (Lighthouse, Prysm, Nimbus, Teku, Lodestar) by running state transitions and comparing results.

**Features:**
- Automatically decompresses `.ssz_snappy` files to `.ssz` (no manual conversion needed)
- Supports both `OfficialTestSuite` directories (with `.ssz_snappy` files) and already-decompressed directories (with `.ssz` files)
- Compares postState SSZ files across all successful clients
- Generates detailed reports (Markdown) and CSV files (execution time, status, differences)
- Supports two workflow modes: **independent** (default) and **sequential** (chained execution)

**Workflow Modes:**

- **independent** (default)  
  Each block is processed **independently** from the original `pre` state:
  - All blocks start from the same original `pre` state
  - Each block's postState is computed independently
  - Useful for testing individual block transitions

- **sequential**  
  Blocks are applied **sequentially**: `pre → blocks_0 → postState_0 → blocks_1 → postState_1 → ...`:
  - First block starts from original `pre` state
  - Subsequent blocks use the previous block's postState as their pre state
  - Useful for testing chained state transitions across multiple blocks

**Usage (Docker):**

All operations run entirely inside the Docker container.

**1. Run diff_testing.py (Differential Testing):**

Execute differential testing with all client implementations. All clients receive the same input and produce state-transition results and coverage data.

Note : All this command is example, if you want to change, then check your command.
**measure the baseline (official test suite):**
```bash
# Interactive shell - all operations run inside container
docker run -it --name eth2test-workspace eth2test:coverage

# Inside the container:
cd /workspace/spectec-core


python3 diff_testing.py \
  --test-suite Converter/OfficialTestSuite/capella/sanity/blocks/pyspec_tests \
  --test-type state-transition \
  --workflow sequential \
  --fork-version capella \
  --output-base ./results/coverage_sanity_block_test \
  --enable-coverage \
  --cleanup-after-report

python3 diff_testing.py \
  --test-suite Converter/OfficialTestSuite/capella/random/random/pyspec_tests \
  --test-type state-transition \
  --workflow sequential \
  --fork-version capella \
  --output-base ./results/coverage_random_test \
  --enable-coverage \
  --cleanup-after-report

python3 diff_testing.py \
  --test-suite Converter/OfficialTestSuite/capella/finality/finality/pyspec_tests \
  --test-type state-transition \
  --workflow sequential \
  --fork-version capella \
  --output-base ./results/coverage_finality_test \
  --enable-coverage \
  --cleanup-after-report

# Generate accumulated coverage report (after running multiple test suites)
python3 diff_testing.py \
  --generate-final-coverage \
  ./results/coverage_sanity_block_test \
  ./results/coverage_random_test \
  ./results/coverage_finality_test \
  --final-output-dir ./results/accumulated_coverage_report
```

**measure the ETH2SpecTec generated test cases:**

First, convert the ETH2SpecTec-generated JSON test cases to SSZ.

```bash
cd /workspace/spectec-core
python3 convert_testgen_json_to_ssz.py \
  --input-dir ./testgen_01280645 \
  --fork capella \
  --output-dir ./your_path
```

After conversion, run diff testing using the generated SSZ tests located at `./your_path/testgen/spectec-generated/...`.

```bash
cd /workspace/spectec-core
python3 diff_testing.py \
  --test-suite ./your_path/testgen/spectec-generated \
  --test-type state-transition \
  --fork-version capella \
  --output-base ./results/coverage_ETH2SpecTec \
  --enable-coverage \
  --cleanup-after-report


# Generate accumulated coverage report (baseline + ETH2SpecTec)
python3 diff_testing.py \
  --generate-final-coverage \
  ./results/coverage_sanity_block_test \
  ./results/coverage_random_test \
  ./results/coverage_finality_test \
  ./results/coverage_ETH2SpecTec \
  --final-output-dir ./results/accumulated_coverage_report_with_ETH2SpecTec
```
**2. Process results with analysis scripts:**

All results are stored in `/workspace/spectec-core/results/` inside the container. You can process them using the analysis scripts:

```bash
# Inside the container (continue from step 1):
cd /workspace/spectec-core

# Check results for mismatches
python3 check_results.py ./results/coverage_sanity_block_test
python3 check_results.py ./results/coverage_ETH2SpecTec
```


Contributions are welcome. Open an issue or pull request. See [CONTRIBUTING.md](CONTRIBUTING.md) for code conventions, commit and PR format, and rebase guidance.

### License

ETH2SpecTec is released under the [Apache 2.0 license](LICENSE).

### Credits

Most of the current codebase is derived from [P4-SpecTec](https://github.com/kaist-plrg/p4-spectec), which in turn is largely based on [Wasm-SpecTec](https://github.com/Wasm-DSL/spectec/tree/main).
