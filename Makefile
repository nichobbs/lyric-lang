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

BUILD_CONFIG ?= Release
AOT_BIN := bootstrap/src/Lyric.Cli.Aot/bin/$(BUILD_CONFIG)/net10.0/lyric

.PHONY: help stage0 stage1 stage1-fast aot lyric \
        test test-lexer test-parser test-typechecker test-emitter test-cli \
        self-test clean

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ── Bootstrap stages ────────────────────────────────────────────────────────

stage0: ## Build the F# stage-0 bootstrap compiler only
	./scripts/bootstrap.sh --stage 0

stage1: ## Build stage-0 + the full self-hosted compiler + CLI bundle (.bootstrap/stage1)
	./scripts/bootstrap.sh --stage 1

stage1-fast: ## Stage 1 without the CLI bundle — fastest loop for a single compiler package
	SKIP_CLI_BUNDLE=1 ./scripts/bootstrap.sh --stage 1

aot: ## Build the AOT entry-point project (requires a prior `make stage1`)
	dotnet build bootstrap/src/Lyric.Cli.Aot --configuration $(BUILD_CONFIG)

lyric: stage1 aot ## Build the end-to-end `lyric` binary and symlink it to ./bin/lyric
	@mkdir -p bin
	@ln -sf "../$(AOT_BIN)" bin/lyric
	@echo "lyric binary ready: ./bin/lyric -> $(AOT_BIN)"

# ── F# test suites (Expecto console apps) ───────────────────────────────────

test: test-lexer test-parser test-typechecker test-emitter test-cli ## Run every F# test suite

test-lexer: ## Run the lexer test suite
	dotnet run --project bootstrap/tests/Lyric.Lexer.Tests -c $(BUILD_CONFIG)

test-parser: ## Run the parser test suite
	dotnet run --project bootstrap/tests/Lyric.Parser.Tests -c $(BUILD_CONFIG)

test-typechecker: ## Run the type-checker test suite
	dotnet run --project bootstrap/tests/Lyric.TypeChecker.Tests -c $(BUILD_CONFIG)

test-emitter: ## Run the emitter test suite (includes all self-hosted self-tests)
	dotnet run --project bootstrap/tests/Lyric.Emitter.Tests -c $(BUILD_CONFIG)

test-cli: ## Run the CLI test suite
	dotnet run --project bootstrap/tests/Lyric.Cli.Tests -c $(BUILD_CONFIG)

# ── Self-hosted self-tests (fast inner-loop verification) ───────────────────
# Usage: make self-test NAME=parser   (runs the `<NAME>_self_test_passes` case)
# Valid NAMEs include: lexer parser typechecker modechecker contract_elaborator
#                      test_synth manifest fmt cfg contract_meta restored_packages
#                      verifier
self-test: ## Run one self-hosted self-test, e.g. `make self-test NAME=parser`
	@if [ -z "$(NAME)" ]; then echo "usage: make self-test NAME=parser"; exit 2; fi
	dotnet run --project bootstrap/tests/Lyric.Emitter.Tests -c $(BUILD_CONFIG) \
	  -- --filter-test-case "$(NAME)_self_test_passes"

# ── Housekeeping ────────────────────────────────────────────────────────────

clean: ## Remove bootstrap artefacts (.bootstrap) and the ./bin symlink
	rm -rf .bootstrap bin
