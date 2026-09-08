NAME = spectec-core

SWITCH ?= eth-spectec

OPAM_EXEC = opam exec --switch=$(SWITCH) --
DUNE = $(OPAM_EXEC) dune

# Compile & Format

.PHONY: exe lsp check fmt fmt-check promote clean

EXELSP = _build/default/spectec/bin/lsp_main.exe

exe:
	rm -f ./$(NAME)
	$(DUNE) build --promote-install-files=false @install --profile=release
	@echo
	@printf '%s\n' \
	  '#!/bin/sh' \
	  'exec opam exec --switch=$(SWITCH) -- dune exec --no-print-directory --root "$(abspath .)" --no-build spectec -- "$$@"' \
	  > ./$(NAME)
	chmod +x ./$(NAME)

lsp:
	rm -f ./$(NAME)-lsp
	$(DUNE) build spectec/bin/lsp_main.exe --profile=release
	@echo
	ln -f $(EXELSP) ./$(NAME)-lsp

check:
	$(DUNE) build @check

fmt:
	$(DUNE) fmt

fmt-check:
	$(DUNE) build @fmt

promote:
	$(DUNE) promote
	@cp -f spectec/test/dep_pos/dep_pos.actual spectec/test/dep_pos/dep_pos.expected 2>/dev/null && rm -f spectec/test/dep_pos/dep_pos.actual && echo "promoted dep_pos.expected" || true

clean:
	rm -f ./$(NAME) ./$(NAME)-lsp
	$(DUNE) clean

# Splice and render. `splice-html` requires `asciidoctor`; `splice-pdf`
# requires `asciidoctor-pdf`.

SPLICE_INPUT = spectec/examples/splice
SPLICE_BUILD = spectec/examples/splice/_build
IMPTY_SPEC = spectec/specs/impty/base/spec.spectec

.PHONY: splice splice-html splice-pdf splice-clean

splice: exe
	mkdir -p $(SPLICE_BUILD)
	./$(NAME) splice -i $(SPLICE_INPUT) -o $(SPLICE_BUILD) \
	  --missing $(SPLICE_BUILD)/splice.missing $(IMPTY_SPEC)

splice-html: splice
	asciidoctor -q \
	  -a docinfo=shared -a docinfodir=$(abspath $(SPLICE_INPUT)) \
	  -o $(SPLICE_BUILD)/impty.html $(SPLICE_BUILD)/impty.adoc

splice-pdf: splice
	asciidoctor-pdf -q \
	  -a docinfo=shared -a docinfodir=$(abspath $(SPLICE_INPUT)) \
	  -o $(SPLICE_BUILD)/impty.pdf $(SPLICE_BUILD)/impty.adoc

splice-clean:
	rm -rf $(SPLICE_BUILD)

# VS Code extension: package editors/vscode into a sideloadable .vsix
# (install with `code --install-extension spectecx.vsix`).

.PHONY: vsix

vsix:
	cd editors/vscode && npx -y @vscode/vsce package -o $(NAME).vsix
	@echo "#### extension written to editors/vscode/$(NAME).vsix"

# Differential-testing fixtures
#
# The official test vectors are release assets of ethereum/consensus-specs,
# not content of this repo. `make download-fixture` pulls the pinned tarball once
# into $(FIXTURE_CACHE) and unpacks the selected forks and suites into
# Converter/OfficialTestSuite/, the layout diff_testing.py, run_test_suite.py and
# Converter/generate_json_test_cases.py expect.
#
# Override the pin or the selection on the command line:
#   make download-fixture SPEC_TESTS_FORKS=capella SPEC_TESTS_SUITES=sanity
#
# `make clean-fixture` drops the unpacked vectors but keeps the cached tarball,
# so re-unpacking a different selection costs no download.

# Match the consensus-specs gitlink (f96d3e7, v1.6.0); update both pins together.
SPEC_TESTS_VERSION ?= v1.6.0
SPEC_TESTS_PRESET ?= mainnet
SPEC_TESTS_FORKS ?= capella deneb
SPEC_TESTS_SUITES ?= sanity random finality
# SHA-256 digests published with the ethereum/consensus-specs release assets.
SPEC_TESTS_SHA256_v1.6.0_mainnet = dbdda1dd6d857edb34604c600d3cb161ef4eb3b4746d9217b8068c3bc3fa925e
SPEC_TESTS_SHA256_v1.6.0_minimal = d491c81a0de054c8ef7066111d1e5cc1d0e03af5f8ee847f316a7a83201e65f0
SPEC_TESTS_SHA256 ?= $(SPEC_TESTS_SHA256_$(SPEC_TESTS_VERSION)_$(SPEC_TESTS_PRESET))
FIXTURE_SHA256 = $(shell command -v sha256sum 2>/dev/null || echo shasum -a 256)

FIXTURE_DIR = Converter/OfficialTestSuite
FIXTURE_CACHE = Converter/.fixture-cache
FIXTURE_TARBALL = $(FIXTURE_CACHE)/$(SPEC_TESTS_PRESET)-$(SPEC_TESTS_VERSION).tar.gz
FIXTURE_URL = https://github.com/ethereum/consensus-specs/releases/download/$(SPEC_TESTS_VERSION)/$(SPEC_TESTS_PRESET).tar.gz

.PHONY: download-fixture clean-fixture

download-fixture:
	@set -eu; \
	if [ -z "$(SPEC_TESTS_SHA256)" ]; then \
	  echo "Set SPEC_TESTS_SHA256 to the release asset digest for $(SPEC_TESTS_VERSION)/$(SPEC_TESTS_PRESET)." >&2; \
	  exit 1; \
	fi; \
	mkdir -p "$(FIXTURE_CACHE)" "$(dir $(FIXTURE_DIR))"; \
	tmp=$$(mktemp -d "$(FIXTURE_DIR).tmp.XXXXXX"); \
	trap 'rm -rf "$$tmp"' 0; \
	trap 'exit 1' 1 2 15; \
	archive="$(FIXTURE_TARBALL)"; \
	if [ ! -f "$$archive" ]; then \
	  archive="$$tmp/archive.tar.gz"; \
	  curl -fL --progress-bar -o "$$archive" "$(FIXTURE_URL)"; \
	fi; \
	printf '%s  %s\n' "$(SPEC_TESTS_SHA256)" "$$archive" | $(FIXTURE_SHA256) -c - || { \
	  echo "Fixture checksum mismatch; remove $(FIXTURE_TARBALL) if cached and retry." >&2; \
	  exit 1; \
	}; \
	if [ "$$archive" != "$(FIXTURE_TARBALL)" ]; then \
	  mv "$$archive" "$(FIXTURE_TARBALL)"; \
	fi; \
	set --; \
	for fork in $(SPEC_TESTS_FORKS); do \
	  for suite in $(SPEC_TESTS_SUITES); do \
	    set -- "$$@" "tests/$(SPEC_TESTS_PRESET)/$$fork/$$suite"; \
	  done; \
	done; \
	[ "$$#" -gt 0 ] || { echo "Select at least one fork and suite." >&2; exit 1; }; \
	mkdir "$$tmp/vectors"; \
	tar -xzf "$(FIXTURE_TARBALL)" -C "$$tmp/vectors" --strip-components=2 "$$@"; \
	rm -rf "$(FIXTURE_DIR)"; \
	mv "$$tmp/vectors" "$(FIXTURE_DIR)"; \
	printf '%s\n' "source=$(FIXTURE_URL)" "version=$(SPEC_TESTS_VERSION)" \
	  "preset=$(SPEC_TESTS_PRESET)" "sha256=$(SPEC_TESTS_SHA256)" \
	  "forks=$(SPEC_TESTS_FORKS)" "suites=$(SPEC_TESTS_SUITES)" > "$(FIXTURE_DIR)/.fixture-info"
	@echo "#### $(SPEC_TESTS_PRESET) $(SPEC_TESTS_VERSION) vectors ready in $(FIXTURE_DIR)"

clean-fixture:
	rm -rf "$(FIXTURE_DIR)"
	@echo "#### removed $(FIXTURE_DIR) (cached tarball kept in $(FIXTURE_CACHE))"

# Tests
#
# Individual tests:
#   make test-elab       - Elaboration test (both p4 and p4-old)
#   make test-struct     - Structuring test (both p4 and p4-old)
#   make test-bytesv     - BytesV hex / width test
#   make test-instrumentation - Instrumentation tests
#   make test-testgen-checkpoint - Testgen checkpoint compatibility
#   make test-annotate   - Annotate/prose render test (impty x3 + p4-old)
#   make test-roundtrip-il - EL<->IL premise roundtrip test (impty base + closure, p4)
#   make test-roundtrip-el - EL pretty-printer roundtrip test (mini-spec, p4-old, p4, impty)
#   make test-parsegen   - Grammar-driven parser differential test (impty expressions + programs)
#   make test-package    - Package ownership and plugin discovery tests
#   make test-il-pos     - IL interpreter positive tests (slow)
#   make test-il-neg     - IL interpreter negative tests
#   make test-sl-pos     - SL interpreter positive tests (slow)
#   make test-sl-neg     - SL interpreter negative tests
#   make test-pl-pos     - PL interpreter positive tests (slow)
#   make test-pl-neg     - PL interpreter negative tests
#
# p4-old interpreter tests:
#   make test-il-pos-old / test-il-neg-old / test-sl-pos-old / test-sl-neg-old
#   make test-pl-pos-old / test-pl-neg-old
#
# Relation and per-case interpreter tests:
#   make test-interp-relation - Relation tests across IL/SL/PL
#   make test-interp-neg      - Per-case impty IL negative tests
#
# CLI snapshot tests (target commands and instrumentation):
#   make test-cli        - target CLI and instrumentation snapshots
#   make test-lsp        - LSP diagnostics snapshot (Check.run -> LSP JSON)
#
# Grouped tests:
#   make test-quick      - Fast tests, including local and upstream coverage
#   make test-dep        - Dependency mutation-report golden (slow, opt-in)
#   make test-il         - IL tests for new p4 (pos + neg)
#   make test-sl         - SL tests for new p4 (pos + neg)
#   make test-pl         - PL tests for new p4 (pos + neg)
#   make test-il-old     - IL tests for p4-old (pos + neg)
#   make test-sl-old     - SL tests for p4-old (pos + neg)
#   make test-pl-old     - PL tests for p4-old (pos + neg)
#   make test-old        - All p4-old interpreter tests
#
# impty interpreter tests (per-variant: base, closure):
#   make test-impty-<v>-il-pos / -il-neg / -sl-pos / -sl-neg
#   make test-impty-<v>-il / -sl                     - per-variant pos+neg
#   make test-impty-<v>                              - per-variant il+sl
#   make test-impty                                  - all impty tests
#
# Mini-ML interpreter tests:
#   make test-miniml-il-pos / -il-neg / -sl-pos / -sl-neg / -pl-pos / -pl-neg
#   make test-miniml-il / -sl / -pl                  - per-mode pos+neg
#   make test-miniml                                  - all Mini-ML tests
#
#   make test            - quick + new p4 il/sl/pl

.PHONY: test test-quick test-elab test-elab-neg test-interp-relation test-interp-neg test-cli test-lsp test-struct test-annotate test-roundtrip-il test-roundtrip-el test-parsegen test-package test-bytesv test-instrumentation test-testgen-checkpoint test-dep
.PHONY: test-il test-il-pos test-il-neg
.PHONY: test-sl test-sl-pos test-sl-neg
.PHONY: test-pl test-pl-pos test-pl-neg
.PHONY: test-old test-il-old test-il-pos-old test-il-neg-old
.PHONY: test-sl-old test-sl-pos-old test-sl-neg-old
.PHONY: test-pl-old test-pl-pos-old test-pl-neg-old
.PHONY: test-impty test-impty-base test-impty-closure
.PHONY: test-impty-base-il test-impty-base-sl test-impty-base-pl
.PHONY: test-impty-closure-il test-impty-closure-sl test-impty-closure-pl
.PHONY: test-impty-base-il-pos test-impty-base-il-neg
.PHONY: test-impty-base-sl-pos test-impty-base-sl-neg
.PHONY: test-impty-base-pl-pos test-impty-base-pl-neg
.PHONY: test-impty-closure-il-pos test-impty-closure-il-neg
.PHONY: test-impty-closure-sl-pos test-impty-closure-sl-neg
.PHONY: test-miniml test-miniml-il test-miniml-sl test-miniml-pl
.PHONY: test-miniml-il-pos test-miniml-il-neg
.PHONY: test-miniml-sl-pos test-miniml-sl-neg
.PHONY: test-miniml-pl-pos test-miniml-pl-neg
.PHONY: promote

test-elab:
	@echo "#### Running elaboration test"
	@$(DUNE) build @spectec/test/elab/runtest --profile=release && echo OK

test-roundtrip-el:
	@echo "#### Running EL pretty-printer roundtrip test"
	@$(DUNE) build @spectec/test/roundtrip/el/runtest --profile=release && echo OK

test-elab-neg:
	@echo "#### Running elaboration negative tests"
	@$(DUNE) build @spectec/test/elab/neg/runtest --profile=release && echo OK

test-interp-relation:
	@echo "#### Running interpreter relation tests"
	@$(DUNE) build @spectec/test/interp/relation/runtest --profile=release && echo OK

test-interp-neg:
	@echo "#### Running interpreter negative tests (per-case impty IL corpus)"
	@$(DUNE) build @spectec/test/interp/neg/runtest --profile=release && echo OK

test-cli:
	@echo "#### Running CLI snapshot tests"
	@$(DUNE) build @spectec/test/cli/runtest --profile=release && echo OK

test-lsp:
	@echo "#### Running LSP diagnostics test"
	@$(DUNE) build @spectec/test/lsp/runtest --profile=release && echo OK

test-struct:
	@echo "#### Running structuring test"
	@$(DUNE) build @spectec/test/struct/runtest --profile=release && echo OK

test-bytesv:
	@echo "#### Running BytesV hex/width test"
	@$(DUNE) build @spectec/test/bytesv/runtest --profile=release && echo OK

test-instrumentation:
	@echo "#### Running instrumentation tests"
	@$(DUNE) build @spectec/test/instrumentation/runtest --profile=release && echo OK

test-testgen-checkpoint:
	@echo "#### Running testgen checkpoint compatibility test"
	@$(DUNE) build @spectec/test/testgen_checkpoint/runtest --profile=release && echo OK

test-dep: exe
	@echo "#### Running dependency mutation-report golden (attestation_0)"
	@sh spectec/test/dep_pos/run.sh

test-annotate:
	@echo "#### Running annotate test"
	@$(DUNE) build @spectec/test/annotate/runtest --profile=release && echo OK

test-roundtrip-il:
	@echo "#### Running EL<->IL premise roundtrip test"
	@$(DUNE) build @spectec/test/roundtrip/il/runtest --profile=release && echo OK

test-parsegen:
	@echo "#### Running grammar-driven parser differential test"
	@$(DUNE) build @spectec/test/parsegen/runtest --profile=release && echo OK

test-package:
	@echo "#### Running package ownership and plugin discovery tests"
	@$(DUNE) build --promote-install-files=false @spectec/test/package/runtest --profile=release && echo OK

# $(1): target prefix (p4 / p4-old)
# $(2): il / sl
# $(3): pos / neg
define run_interp_test
	@echo "#### Running $(2) interpreter $(3) tests ($(1))"
	@$(DUNE) build @spectec/test/interp/$(1)-$(2)-$(3) --profile=release
	@cat _build/default/spectec/test/interp/$(1)-$(2)-$(3).err >&2
	@echo OK
endef

test-il-pos:
	$(call run_interp_test,p4,il,pos)

test-il-neg:
	$(call run_interp_test,p4,il,neg)

test-sl-pos:
	$(call run_interp_test,p4,sl,pos)

test-sl-neg:
	$(call run_interp_test,p4,sl,neg)

test-pl-pos:
	$(call run_interp_test,p4,pl,pos)

test-pl-neg:
	$(call run_interp_test,p4,pl,neg)

test-il-pos-old:
	$(call run_interp_test,p4-old,il,pos)

test-il-neg-old:
	$(call run_interp_test,p4-old,il,neg)

test-sl-pos-old:
	$(call run_interp_test,p4-old,sl,pos)

test-sl-neg-old:
	$(call run_interp_test,p4-old,sl,neg)

test-pl-pos-old:
	$(call run_interp_test,p4-old,pl,pos)

test-pl-neg-old:
	$(call run_interp_test,p4-old,pl,neg)

test-quick: test-elab test-elab-neg test-interp-relation test-interp-neg test-cli test-lsp test-struct test-annotate test-roundtrip-il test-roundtrip-el test-impty test-miniml test-parsegen test-package test-bytesv test-instrumentation test-testgen-checkpoint
	@echo "#### Quick tests passed"

test-il: test-il-pos test-il-neg
	@echo "#### IL tests passed"

test-sl: test-sl-pos test-sl-neg
	@echo "#### SL tests passed"

test-pl: test-pl-pos test-pl-neg
	@echo "#### PL tests passed"

test-il-old: test-il-pos-old test-il-neg-old
	@echo "#### IL (p4-old) tests passed"

test-sl-old: test-sl-pos-old test-sl-neg-old
	@echo "#### SL (p4-old) tests passed"

test-pl-old: test-pl-pos-old test-pl-neg-old
	@echo "#### PL (p4-old) tests passed"

test-old: test-il-old test-sl-old test-pl-old
	@echo "#### p4-old interpreter tests passed"

test-impty-base-il-pos:
	$(call run_interp_test,impty-base,il,pos)

test-impty-base-il-neg:
	$(call run_interp_test,impty-base,il,neg)

test-impty-base-sl-pos:
	$(call run_interp_test,impty-base,sl,pos)

test-impty-base-sl-neg:
	$(call run_interp_test,impty-base,sl,neg)

test-impty-base-pl-pos:
	$(call run_interp_test,impty-base,pl,pos)

test-impty-base-pl-neg:
	$(call run_interp_test,impty-base,pl,neg)

test-impty-closure-il-pos:
	$(call run_interp_test,impty-closure,il,pos)

test-impty-closure-il-neg:
	$(call run_interp_test,impty-closure,il,neg)

test-impty-closure-sl-pos:
	$(call run_interp_test,impty-closure,sl,pos)

test-impty-closure-sl-neg:
	$(call run_interp_test,impty-closure,sl,neg)

test-impty-closure-pl-pos:
	$(call run_interp_test,impty-closure,pl,pos)

test-impty-closure-pl-neg:
	$(call run_interp_test,impty-closure,pl,neg)

test-impty-base-il: test-impty-base-il-pos test-impty-base-il-neg
	@echo "#### IL (impty-base) tests passed"

test-impty-base-sl: test-impty-base-sl-pos test-impty-base-sl-neg
	@echo "#### SL (impty-base) tests passed"

test-impty-base-pl: test-impty-base-pl-pos test-impty-base-pl-neg
	@echo "#### PL (impty-base) tests passed"

test-impty-closure-il: test-impty-closure-il-pos test-impty-closure-il-neg
	@echo "#### IL (impty-closure) tests passed"

test-impty-closure-sl: test-impty-closure-sl-pos test-impty-closure-sl-neg
	@echo "#### SL (impty-closure) tests passed"

test-impty-closure-pl: test-impty-closure-pl-pos test-impty-closure-pl-neg
	@echo "#### PL (impty-closure) tests passed"

test-impty-base: test-impty-base-il test-impty-base-sl test-impty-base-pl
	@echo "#### impty-base interpreter tests passed"

test-impty-closure: test-impty-closure-il test-impty-closure-sl test-impty-closure-pl
	@echo "#### impty-closure interpreter tests passed"

test-impty: test-impty-base test-impty-closure
	@echo "#### impty interpreter tests passed"

test-miniml-il-pos:
	$(call run_interp_test,miniml,il,pos)

test-miniml-il-neg:
	$(call run_interp_test,miniml,il,neg)

test-miniml-sl-pos:
	$(call run_interp_test,miniml,sl,pos)

test-miniml-sl-neg:
	$(call run_interp_test,miniml,sl,neg)

test-miniml-pl-pos:
	$(call run_interp_test,miniml,pl,pos)

test-miniml-pl-neg:
	$(call run_interp_test,miniml,pl,neg)

test-miniml-il: test-miniml-il-pos test-miniml-il-neg
	@echo "#### IL (Mini-ML) tests passed"

test-miniml-sl: test-miniml-sl-pos test-miniml-sl-neg
	@echo "#### SL (Mini-ML) tests passed"

test-miniml-pl: test-miniml-pl-pos test-miniml-pl-neg
	@echo "#### PL (Mini-ML) tests passed"

test-miniml: test-miniml-il test-miniml-sl test-miniml-pl
	@echo "#### Mini-ML interpreter tests passed"

test: test-quick test-il test-sl test-pl
	@echo "#### All quick tests + p4 + impty + Mini-ML interpreter tests passed"
