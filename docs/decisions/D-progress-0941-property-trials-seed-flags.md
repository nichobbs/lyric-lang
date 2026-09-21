# D-progress-941 — `lyric test --property-trials`/`--seed` (property-testing v2 slice 1, #6907)

**Status:** shipped

## Context

#6907 asked for "property testing v2": a composable `Generator[T]` combinator
library, custom/opaque-type generators (headlined by a `SortedSet[Int]`
worked example), `--property-trials`/`--seed` CLI flags, and contract
(`ensures:`)-derived properties. A scoping investigation established that:

- `Lyric.TestSynth` (`lyric-compiler/lyric/test_synth/test_synth.l`) is a
  pure source-text rewriter that runs **before** type-checking, with no
  symbol table or cross-file visibility. It cannot inspect a type's fields,
  discover its constructors, or call arbitrary user code to build a value —
  ruling out a general opaque/record/union generator at this layer without a
  much larger architectural change (a real typed generator pass integrated
  into the pipeline, not a text-rewrite stage).
- The headline `SortedSet[Int]` example additionally requires constructing
  an opaque type across a package boundary, which **T0100** (the compiler's
  cross-package opaque-construction restriction) blocks outright — there is
  no smart-constructor discovery/rejection-sampling design yet, so this
  slice would be infeasible even with a generator layer.
- `ensures:`-derived properties need semantics decided against the existing
  contract elaborator (`lyric-compiler/lyric/contract_elaborator/elaborator.l`)
  first — a separate design question, not a CLI-flag change.
- `--property-trials`/`--seed`, by contrast, are pure CLI-plumbing: threading
  two already-supported values (the sample count and the RNG seed literal
  `tryBuildPropertyDriver` already synthesizes into the generated harness)
  through as caller-controlled parameters instead of hardcoded `100`/`1000`.

Per CLAUDE.md's production-readiness standard, shipping a half-implemented
slice of the full #6907 ask (e.g. generators that work for `Int` but panic
or silently no-op for anything else) is not acceptable. Rather than land a
partial, bootstrap-grade generator layer, this entry scopes to the one piece
that is both tractable today and independently useful: reproducible,
tunable property runs.

## Decision

Ship "v2 slice 1" only:

- `pub record PropertyRunConfig { trials: Int = 100; seed: Int = 1000 }` in
  `Lyric.TestSynth`, threaded through `synthesizeFor`/`tryBuildPropertyDriver`
  in place of the hardcoded `100`/`1000 + idx` literals.
- `pub func synthesizeWithPropertiesConfig(source, filter, cfg): Outcome` —
  additive alongside the existing `synthesizeWithProperties` (which keeps its
  old signature and behaviour, delegating to `PropertyRunConfig()`'s
  defaults, so no existing caller breaks).
- `lyric test --property-trials <N>` (`N >= 1`, default 100) and
  `lyric test --seed <N>` (default 1000) in `Lyric.Cli`'s `cmdTest`/
  `cmdTestManifest`, threaded through both the single-file and `--manifest`
  paths (including the `[project.tests]`-empty scan-fallback loop, which
  re-serializes argv into a recursive `cmdTest` invocation and must re-add
  both flags explicitly to propagate them).
- Both flags require `--properties` — passing either without it is a loud
  CLI error (`test: --property-trials/--seed require --properties`), not a
  silent no-op, consistent with this codebase's existing `--coverage`/
  `--update-snapshots` flag-validation precedent.
- The synthesized panic message on a property failure now reports the exact
  seed and trial count used (`[seed=N, trials=N]`), so a CI failure is
  reproducible by re-running with the same flags.
- Each property in a file still gets its own distinct seed
  (`cfg.seed.xor(idx)` — XOR rather than `+`, since `Int` is 32-bit and an
  addition could overflow-panic for an extreme `--seed` on a multi-property
  file; XOR is always in-range and equally injective in `idx`), so an
  explicit `--seed` never collides two properties in the same file onto the
  same sample sequence.

## Explicitly deferred (separate follow-up issues, not silently dropped)

1. **Composable `Generator[T]` combinators + custom/imported-type
   generators** — needs a design decision on type-checker integration (or
   `Lyric.ContractMeta`-based metadata) since `TestSynth` itself has no
   symbol table.
2. **Opaque-type invariant-respecting generation** (the `SortedSet[Int]`
   case) — blocked on T0100; needs a design doc for smart-constructor
   discovery + rejection sampling before any implementation.
3. **`ensures:`-derived properties** — needs semantics agreed against the
   contract elaborator first.

## Verification

- `lyric-compiler/lyric/cli_test_self_test.l` — 9 new cases: both flags
  rejected without `--properties`; `--property-trials 0`, `--property-trials
  abc`, and `--seed abc` all rejected; an always-failing property still fails
  at `--property-trials 1`; an always-true property still passes at
  `--property-trials 500 --seed 42`; two properties in one file both pass
  under one explicit shared `--seed` (distinct per-property offset); a
  two-property file under `--seed 2147483647` (near `Int32.MaxValue`) does
  not overflow-panic, pinning down the `cfg.seed.xor(idx)` fix.
- `lyric-compiler/lyric/test_synth_self_test.l` — unchanged existing cases
  continue to pass (`synthesize`/`synthesizeWithProperties`'s old signatures
  and behaviour are untouched).
