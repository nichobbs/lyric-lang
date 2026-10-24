# D246 — `lyric test --coverage` counts statement lines through the compiler on .NET and the JVM

**Status:** accepted, implemented (#5294)

Supersedes the JaCoCo slice of D135 (`--target jvm --coverage`, JaCoCo agent plus
`Lyric.JacocoCobertura`).  The owner approved compiler-level coverage for the MSIL
and JVM targets on 2026-10-24 and deferred native.

## Context

D135 shipped JVM coverage by attaching the third-party JaCoCo agent to the test
JAR and translating JaCoCo's XML into Cobertura.  It covered one target, needed
two downloaded jars, could only say "covered or not" per line (JaCoCo has no
execution counts), and the MSIL target had nothing.  #5294 asked for a story
that works the same on both managed targets without a non-Lyric collector.

## Decision

1. **One instrumentation, shared by both backends.**  `Lyric.Coverage`
   rewrites a source file before it reaches the pipeline: each statement of each
   function body (blocks nested in `if`, `match`, loops, `try`, lambdas
   included) is prefixed with `__lyric_cov.hit(<id>); `, and the file's
   `package` line gains `; import Std.Coverage as __lyric_cov`.  Every
   insertion is on a line the statement or the package declaration already
   occupies, so no line of the file moves and diagnostics stay exact.  The two
   backends compile the same text, so they report the same lines by
   construction; there is no per-backend emitter work to keep in step.
2. **Counters are a stdlib module.**  `Std.Coverage` keeps the counts in a
   `protected type` (safe under `spawn` and the parallel pool) and
   `dumpFromEnv` writes `<id> <count>` lines to the file named by
   `LYRIC_COVERAGE_OUT`.  It is pure Lyric, so no kernel is needed on any
   target.  The synthesised test `main` calls `dumpFromEnv` before it returns
   (`TestSynth.withCoverageDump`).
3. **Reports in the CLI.**  `lyric test` keeps the map from ids to lines, sums
   the counts of every test run (each run is its own process), and writes
   `coverage.info` (lcov, with function and line records) and `coverage.xml`
   (Cobertura) to `.lyric-test`, plus a console summary.  A line's count is the
   most any statement on it ran.  `--min-coverage <percent>` turns the total into
   a gate.
4. **What is the code under test.**  In project mode, every `[project.packages]`
   source; test files only get the counter import their `main` needs.  For a
   single test file, the file's own functions.  `test` items are never counted
   (they are not functions until the runner rewrites them, after this pass).
   Not instrumented: `Std.*` packages (the counter is built from them),
   `@pure`/`@proof_required`/`@axiom` packages and `@pure`/`@axiom` functions
   (a call to the counter would fail the effect and proof checks), and files
   that do not parse.
5. **Loud failures.**  A run that instrumented nothing, `--coverage` with
   `--fail-fast` (the report of an early stop means nothing) and
   `--min-coverage` without `--coverage` are errors; project mode needs
   `[project.tests]` entries (the `@test_module` fallback runs each file on its
   own).  A test run that wrote no counts is a warning naming the file.
6. **Native is deferred** behind the debug-information bands of docs/63 (B2 and
   later): `--target native` is rejected with a pointer to #8553.  Native's
   own route is clang's `-fprofile-instr-generate -fcoverage-mapping`, which
   needs source locations in the emitted LLVM IR.
7. **JaCoCo is removed**: the `--coverage` JaCoCo path of `cli_test.l`,
   `Lyric.JacocoCobertura` and its self-test, `make jacoco`,
   `scripts/ci/coverage-smoke-test.sh` and the two CI steps that ran them.

## Consequences

* Statement counting is line-level and per-statement: no branch coverage, and
  an arm `case p -> expr` with an expression body is not a statement of its
  own (its block form is).
* The instrumented code runs slower (a protected-type call per statement); the
  flag is for coverage runs, not for the normal suite.
* The same pass is the natural base for a coverage gate over the compiler's own
  suites once they run in project mode.
