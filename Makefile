# Makefile — convenience targets for the Lyric build/test loops.
#
# These wrap the same commands CI runs (see .github/workflows/ci.yml) and the
# bootstrap script (scripts/bootstrap.sh), with the common gotchas baked in so
# they can't be gotten wrong.  `make` is used (not `just`) because it's
# universally available with no install step.
#
# Two loops matter:
#
#   INNER LOOP (front-end changes: lexer/parser/typechecker/modechecker/fmt)
#     make stage1-fast        # rebuild self-hosted compiler DLLs, skip CLI bundle
#     make self-test NAME=parser
#   The self-test runner compiles a single *_self_test.l against the freshly
#   built stage-1 DLLs in ~seconds — no AOT binary needed.
#
#   END-TO-END LOOP (CLI behaviour, `lyric build/test/...`, ecosystem repros)
#     make lyric              # stage1 + AOT entry-point -> ./bin/lyric symlink
#     ./bin/lyric test --manifest lyric-session/lyric.toml
#
# Since scripts/bootstrap.sh now honours $TMPDIR (it mirrors the F# emitter's
# Path.GetTempPath()), none of these targets need the old `TMPDIR=/tmp` prefix.
#
# ─────────────────────────────────────────────────────────────────────────────
# BOOTSTRAP (mint) vs SELF-HOSTED — which compiler am I running?
# ─────────────────────────────────────────────────────────────────────────────
# There are THREE compilers in play.  Knowing which one you built is the
# difference between "this is a real self-hosted bug" and "I'm running the wrong
# binary".  See docs/10-bootstrap-progress.md §"Bootstrap vs self-hosted" for
# the full model.  In short:
#
#   1. MINT STAGE-0  — the historical F# bootstrap compiler, rebuilt from git
#      history by scripts/mint-stage0-fsharp.sh.  Its emitter is correct, so
#      everything it produces is VALID IL.  This is the seed CI uses
#      (LYRIC_BOOTSTRAP_MINT=1).
#
#   2. MINT STAGE-1 (a.k.a. the BOOTSTRAP compiler) — the self-hosted compiler
#      `.l` sources compiled BY the mint seed.  Valid IL; this is exactly what
#      CI ships and runs.  Build it with `make mint`.  Use it for all day-to-day
#      development: it RUNS the self-hosted codegen, so compiling a program with
#      it exercises the self-hosted emitter on USER code while staying runnable.
#
#   3. SELF-HOSTED STAGE-2 — the self-hosted compiler compiled BY ITSELF, built
#      as an ISOLATED, self-consistent toolchain by `make stage2`
#      (.bootstrap/stage2/{lib,bin}; no co-mingling with the seed).  This is the
#      END GOAL and the SHIP/TEST toolchain: run everything against it via
#      `make run-stage2 ARGS=...` (which pins LYRIC_STDLIB_BIN to its own
#      stdlib).  It is only runnable once the self-hosted EMITTER produces valid
#      IL for its own closure; `make stage2` reports the blocker non-fatally
#      when it does not, and `make ilverify` quantifies it.  Until stage 2 runs,
#      use the mint toolchain (#2) for day-to-day development.
#
# Decision rule when a test/program misbehaves:
#   * Reproduce with `make mint` (CI-faithful, known-good).  If it still fails,
#     the bug is real (self-hosted emitter or logic).  `make selfhost-check
#     FILE=repro.l` classifies it (valid IL + runs vs invalid IL).
#   * If it only fails with a bare `make lyric` binary, you were running the
#     not-yet-runnable full self-hosted toolchain — rebuild with `make mint`.

BUILD_CONFIG ?= Release
# `net10.0` must stay in sync with the TFM in `bootstrap/global.json` and
# `bootstrap/Directory.Build.props`.  When the SDK is bumped, update this
# path too — otherwise `make lyric` silently symlinks to a non-existent
# binary and the failure looks unrelated.
AOT_BIN := bootstrap/src/Lyric.Cli.Aot/bin/$(BUILD_CONFIG)/net10.0/lyric

.PHONY: help stage1 stage1-fast aot lyric selfhosted-compiler \
        stage2 stage3 run-stage2 \
        mint ilverify selfhost-check \
        test test-lexer test-parser test-typechecker test-emitter \
        self-test clean

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ── Bootstrap stages ────────────────────────────────────────────────────────

# Everything stage 1 compiles from: the self-hosted compiler and stdlib `.l`
# sources, plus the bootstrap script itself.  These are the stamp rule's
# prerequisites so an edited compiler `.l` file makes `make aot` / `make
# lyric` rebuild stage 1 instead of silently embedding stale DLLs (#2706).
#
# NOTE: Stage 0 (F# bootstrap) has been deleted in favor of bootstrap-from-release.
# The bootstrap script downloads the latest self-hosted binary by default and
# uses it as stage-0, eliminating the need to maintain the F# compiler.
STAGE1_SRCS := $(shell find lyric-compiler lyric-stdlib -name '*.l') scripts/bootstrap.sh

stage1: ## Build the full self-hosted compiler + CLI bundle (.bootstrap/stage1)
	./scripts/bootstrap.sh --stage 1
	@touch .bootstrap/stage1.stamp

stage1-fast: ## Stage 1 without the CLI bundle — fastest loop for a single compiler package
	SKIP_CLI_BUNDLE=1 ./scripts/bootstrap.sh --stage 1
	# Intentionally NOT touching stage1.stamp here: SKIP_CLI_BUNDLE=1 skips the
	# CLI bundle (which rebuilds the self-hosted compiler DLLs), so the stamp
	# would be stale from the previous full build.  A subsequent `make lyric`
	# must see the stamp as older than any edited .l source so stage1 runs in
	# full (#3583).  Use `make stage1` + `make aot` if you need make lyric too.

# `aot` depends on the stage-1 stamp so a direct `make aot` with no prior
# stage 1 builds stage 1 first (via the stamp rule below) instead of failing
# on a missing CLI bundle, and so an out-of-date stamp (a `.l` source newer
# than the last stage-1 build) triggers a rebuild rather than embedding
# stale DLLs.  The stamp is written by `stage1` / `stage1-fast`.
# The recipe keeps --no-incremental on purpose: the AOT trampoline embeds the
# stage-1 DLLs, so a clean C# build is required whenever stage 1 has changed.
aot: .bootstrap/stage1.stamp ## Build the AOT entry-point project (builds stage 1 first when stale)
	@# ECMA-335 §II.22.23: seed binary may emit an unsorted InterfaceImpl table;
	@# patch the full-bundle DLL so MSBuild copies it to the AOT output directory.
	@if [ -f .bootstrap/stage1/Lyric.Stdlib.dll ]; then \
	    python3 scripts/patch_interface_impl.py .bootstrap/stage1/Lyric.Stdlib.dll; \
	fi
	dotnet build bootstrap/src/Lyric.Cli.Aot --configuration $(BUILD_CONFIG) --no-incremental

.bootstrap/stage1.stamp: $(STAGE1_SRCS)
	$(MAKE) stage1

# `lyric` reaches stage 1 only through `aot` -> stamp (a single serial
# dependency chain), never as a sibling prerequisite — under `make -j` a
# `lyric: stage1 aot` rule would run `stage1` and the stamp rule's recursive
# `$(MAKE) stage1` concurrently, racing on .bootstrap/stage1 (#2706).
lyric: aot ## Build the end-to-end `lyric` binary and symlink it to ./bin/lyric
	@mkdir -p bin
	@ln -sf "../$(AOT_BIN)" bin/lyric
	@echo "lyric binary ready: ./bin/lyric -> $(AOT_BIN)"
	@echo "writing sdk-version.json to .bootstrap/stage1/ (D109 / Q-dist-007) ..."
	@printf '{"language_version": "0.1","stdlib_version": "0.1.0","compiler_version": "0.1.0","build_date": "%s"}\n' \
	    "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	    > .bootstrap/stage1/sdk-version.json
	@echo "deploying the single full Lyric.Stdlib.dll bundle (D111) ..."
	@bash scripts/stage-selfhosted-stdlib.sh ./bin/lyric "$(dir $(AOT_BIN))" .bootstrap/stage1
ifeq ($(SKIP_SELFHOSTED_COMPILER),1)
	@echo "SKIP_SELFHOSTED_COMPILER=1; skipping the self-hosted compiler-DLL staging"
else
	@echo "staging self-hosted compiler DLLs for native lyric test (#3086) ..."
	@bash scripts/stage-selfhosted-compiler.sh ./bin/lyric "$(dir $(AOT_BIN))" .bootstrap/stage1
endif

# Re-stage only the self-hosted compiler DLLs (after `make lyric
# SKIP_SELFHOSTED_COMPILER=1`, or to refresh them without a full rebuild).
selfhosted-compiler: ## Stage self-hosted compiler DLLs under <libdir>/selfhosted (#3086)
	@bash scripts/stage-selfhosted-compiler.sh ./bin/lyric "$(dir $(AOT_BIN))" .bootstrap/stage1

# ── Isolated self-hosted ship/test toolchain (stage 2) ──────────────────────
# Stage 2 is the SHIP/TEST toolchain: the stage-1 true compiler rebuilds itself
# and the full stdlib into an isolated, self-consistent root
# (.bootstrap/stage2/{lib,bin}) with NO co-mingling of the seed's artefacts.
# Everything (compiler self-tests, stdlib, ecosystem, user code) should be run
# against THIS toolchain, pinned via `LYRIC_STDLIB_BIN=.bootstrap/stage2/lib`.
# Building it is the runnability gate: a self-hosted emitter bug surfaces here
# as a clean, specific failure rather than as build-system noise.  Requires a
# stage-1 build first (`make stage1` or `make mint`).
stage2: ## Build the isolated self-hosted ship/test toolchain (.bootstrap/stage2)
	./scripts/bootstrap.sh --stage 2
	@echo "stage-2 toolchain: .bootstrap/stage2/bin/lyric"
	@echo "run things against it with: LYRIC_STDLIB_BIN=$$PWD/.bootstrap/stage2/lib .bootstrap/stage2/bin/lyric ..."

stage3: ## Run the reproducibility-fixpoint diagnostic over stage 2 (non-blocking)
	./scripts/bootstrap.sh --stage 3

# Convenience: run an arbitrary `lyric` invocation against the stage-2 toolchain
# with the stdlib pinned.  Usage: make run-stage2 ARGS="test path/to/foo.l"
run-stage2: ## Run the stage-2 toolchain with stdlib pinned, e.g. ARGS="--version"
	@test -x .bootstrap/stage2/bin/lyric || { echo "no stage-2 toolchain; run 'make stage2' first"; exit 2; }
	LYRIC_STDLIB_BIN="$$PWD/.bootstrap/stage2/lib" .bootstrap/stage2/bin/lyric $(ARGS)

# ── Bootstrap (mint) toolchain + self-hosted-emitter diagnostics ────────────
# The CI-faithful, known-good dev toolchain.  Builds mint stage-1 (F#-emitted,
# valid IL — what CI ships) and the AOT entry point on top of it, then stages
# the runtime stdlib.  Use this for day-to-day development and for reproducing
# failures: if a program/test fails here, the bug is real.  Contrast with a
# bare `make lyric`, which builds the not-yet-runnable full self-hosted stage-1.
mint: ## Build the CI-faithful mint (bootstrap) toolchain -> ./bin/lyric (valid IL)
	LYRIC_BOOTSTRAP_MINT=1 ./scripts/bootstrap.sh --stage 1
	@touch .bootstrap/stage1.stamp
	dotnet build bootstrap/src/Lyric.Cli.Aot --configuration $(BUILD_CONFIG) --no-incremental
	@mkdir -p bin
	@ln -sf "../$(AOT_BIN)" bin/lyric
	@echo "mint (bootstrap) lyric ready: ./bin/lyric -> $(AOT_BIN)  [valid IL, CI-faithful]"
	@bash scripts/stage-selfhosted-stdlib.sh ./bin/lyric "$(dir $(AOT_BIN))" .bootstrap/stage1

# Measure self-hosted-EMITTER IL validity: emit the whole compiler closure with
# the self-hosted emitter (the AOT binary routes --target dotnet through
# Msil.Bridge) and run `ilverify` over every emitted DLL.  0 errors is the gate
# for the full self-hosted toolchain (item 3 above) being runnable.  Requires a
# built binary — run `make mint` (or `make lyric`) first.
ilverify: ## Run the self-hosted-emitter IL-validity gate (scripts/ilverify-selfhosted.sh)
	bash scripts/ilverify-selfhosted.sh "$(AOT_BIN)"

# Classify a single repro: is a misbehaving construct a REAL self-hosted-emitter
# bug, or an environment artifact?  Compiles FILE with the mint (bootstrap)
# toolchain — which runs the self-hosted codegen — then runs it and ilverifies
# the emitted DLL, printing a verdict.  Usage: make selfhost-check FILE=repro.l
selfhost-check: ## Classify a repro: real self-hosted bug vs artifact (FILE=repro.l)
	@if [ -z "$(FILE)" ]; then echo "usage: make selfhost-check FILE=path/to/repro.l"; exit 2; fi
	bash scripts/selfhost-check.sh "$(FILE)"

# ── F# test suites (Expecto console apps) ───────────────────────────────────

test: test-lexer test-parser test-typechecker test-emitter ## Run F# test suites

test-lexer: ## Run the lexer test suite
	dotnet run --project bootstrap/tests/Lyric.Lexer.Tests -c $(BUILD_CONFIG)

test-parser: ## Run the parser test suite
	dotnet run --project bootstrap/tests/Lyric.Parser.Tests -c $(BUILD_CONFIG)

test-typechecker: ## Run the type-checker test suite
	dotnet run --project bootstrap/tests/Lyric.TypeChecker.Tests -c $(BUILD_CONFIG)

test-emitter: ## Run the emitter test suite (includes all self-hosted self-tests)
	dotnet run --project bootstrap/tests/Lyric.Emitter.Tests -c $(BUILD_CONFIG)

# ── Self-hosted self-tests (fast inner-loop verification) ───────────────────
# Usage: make self-test NAME=parser   (runs the `<NAME>_self_test_passes` case)
# Valid NAMEs include: lexer parser typechecker modechecker contract_elaborator
#                      test_synth manifest fmt cfg contract_meta restored_packages
#                      verifier
self-test: ## Run one self-hosted self-test, e.g. `make self-test NAME=parser`
	@if [ -z "$(NAME)" ]; then echo "usage: make self-test NAME=parser"; exit 2; fi
	dotnet run --project bootstrap/tests/Lyric.Emitter.Tests -c $(BUILD_CONFIG) \
	  -- --filter-test-case "$(NAME)_self_test_passes"

# ── Maven resolver ──────────────────────────────────────────────────────────

maven-resolver: ## Build resolver/pom.xml into resolver/target/lyric-resolver.jar
	mvn package -q -DskipTests -f resolver/pom.xml
	@echo "lyric-resolver.jar built: resolver/target/lyric-resolver.jar"

# ── Housekeeping ────────────────────────────────────────────────────────────

clean: ## Remove bootstrap artefacts (.bootstrap) and the ./bin symlink
	rm -rf .bootstrap bin
