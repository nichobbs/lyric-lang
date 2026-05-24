## Native test runner — `lyric test`

Status: shipped (v1 — D-progress-138).

This document describes the native `lyric test` command and the
`@test_module` / `test "…" { … }` surface it consumes. v1 is a
*bootstrap-grade* runner: enough to retire the F# Expecto bridge for
`lyric-stdlib/tests/*_tests.l` and let the language reference's promised
surface (§3.2, §13.2) compile end-to-end. Property-based testing,
fixtures, snapshot infrastructure beyond `Std.Testing.snapshot`,
parallelism, JUnit XML output, doctests, and contract-based property
auto-derivation are all explicitly Phase 3+ work.

The motivation for finishing v1 now: the panic-on-failure idiom we
ship today (`assertEqual` panics → exit 0 = pass) couples the stdlib
test suite to the F# Expecto runner in
`bootstrap/tests/Lyric.Emitter.Tests/StdlibLyricTests.fs`. Once the
self-hosted compiler retires the F# host (Phase 5 §M5.4), there is
no host left to discover the tests. Shipping a native runner now is
both a Phase 5 deliverable and an immediate quality-of-life win for
the existing stdlib test suite.

### 1. Surface

The language reference (§3.2, §13.2) and worked examples (§5, §11)
already define the surface. v1 implements a strict subset:

```
@test_module
package Account

test "deposit increases balance" {
  val a0 = empty()
  val a1 = deposit(a0, 100)
  expect(balance(a1) == 100)
}
```

#### 1.1 Items v1 supports

* `test "<title>" { <block> }` — runs once. The block is executed
  inside a try/catch shim. A panic (or any uncaught exception)
  marks the test failed; clean return marks it passed. The title
  is a string literal and serves as the human-readable identifier
  in test output.

#### 1.2 Items v1 *parses* but does not *execute*

* `property "<title>" forall(<binders>) [where <expr>] { <block> }`
  — emitted as a **skipped** test in the report (`# skip property
  "…": properties not implemented`) so the surface compiles
  without errors but the runner does not invent generators. v2
  adds property execution.
* `fixture <name>: <type> = <expr>` — parsed and currently rejected
  with a hard `T0901 fixtures not yet supported` diagnostic at
  test-emission time. Worked-example §5 uses fixtures via `wire`
  blocks; v1 supports `wire` in tests just like in production code,
  so the worked-example pattern still works without `fixture` items.

#### 1.3 Assertion library

`Std.Testing` already ships `assertEqual`, `assertEqualInt`,
`assertTrue`, plus snapshot helpers. v1 adds nothing to the
library itself. Tests use those helpers (and panic-on-fail);
the test runner observes pass/fail via thrown / not-thrown
exceptions, which the existing `panic(...)` lowering already
encodes.

The single-argument `expect(<bool-expr>)` form referenced in
`docs/01-language-reference.md` §3.2 is *not* implemented in v1.
Its lowering — `assertTrue(<bool-expr>, "<source-text-of-expr>")`
— requires either a codegen pass with access to the source string
or a CST-aware AST rewrite (currently the lexer drops trivia
between tokens, so reconstructing the original expression text in
the AST is lossy beyond simple cases). The CST work in M5.1 stage
5' lays the groundwork, but plumbing it through the test path is
v2 work. v1 tests use the existing two-argument
`expect(<cond>, <msg>)` builtin or the `Std.Testing.assert*` family.

### 2. CLI

```
lyric test <source.l> [--filter <substring>] [--list]
                      [-o <output.dll>] [-v|--verbose]
lyric test --manifest <lyric.toml> [--filter <substring>] [--list]
```

#### 2.1 Behaviour

* `lyric test <source.l>` compiles `<source.l>` (which must carry
  `@test_module` at the file head) and runs the resulting PE.
* `lyric test --manifest <lyric.toml>` discovers every `*_tests.l`
  / `*_test.l` file under the project's `src/` (or, where present,
  the manifest's `[test] paths = […]` table — v2) and compiles
  each as a separate test program. v1 ships single-file mode only;
  the multi-manifest form is documented here so the CLI vocabulary
  doesn't churn between v1 and v2.
* Without `@test_module`, the file is rejected with
  `T0900: lyric test requires '@test_module' at the file head`.
* `--list` prints titles only, exit 0, runs nothing.
* `--filter <substring>` runs only tests whose title contains
  `<substring>` (case-sensitive). Skipped tests are reported as
  `# skip` lines.

#### 2.2 Output

A plain stream that's both human-readable and TAP-like (so a CI
adapter is one `awk` away). For a file with three tests where the
middle one fails:

```
1..3
ok 1 - deposit increases balance
not ok 2 - rejects negative amount
  panic: assertEqualInt 'amount' failed: expected=-1 actual=0
ok 3 - withdraw decreases balance

# tests 3
# pass  2
# fail  1
```

Exit codes:

* `0` — every selected test passed (or all were skipped/filtered out).
* `1` — at least one test failed.
* `2` — compilation error (no tests were run).
* `64` — usage error (bad CLI flags, missing `@test_module`, etc.).

### 3. Compilation strategy

`lyric build` and `lyric run` compile a package with a user-declared
`func main(): Unit` to a runnable PE. `lyric test` swaps that
out: the user does *not* declare `main`, and the compiler synthesises
one from the package's `ITest` items.

Concretely, when `@test_module` is set on the file the emitter:

1. Refuses if the package declares `func main(): Unit` (`T0902`),
   so the synthetic main can't shadow user code.
2. For each `ITest t` in source order, emits a private static method
   on the package's static class:

   ```fsharp
   let mname = sprintf "__test_%d" idx
   let mb    = staticClass.DefineMethod(mname, MethodAttributes.Private |||
                                                MethodAttributes.Static,
                                        typeof<bool>, [||])
   ```

   The method body is `t.Body` lowered by the existing block emitter,
   wrapped in a `try { … ; ldc.i4.1 ; ret } catch (Exception e) { … ;
   ldc.i4.0 ; ret }` shim. The catch block prints the panic message
   to stderr (the existing `Lyric.Stdlib.Console::Println` plus a
   stderr variant we already use for diagnostics).

3. Emits a synthetic `main()` that calls each `__test_<idx>` in
   order, prints the TAP header, increments per-test counters, and
   exits with `0` or `1` per §2.2.

4. When `--filter` is in play, the synthesizer reads the filter from
   `args[0]` (we pass it via `dotnet exec` arg), so the same PE
   supports re-runs without recompilation.

The dispatch table — title strings, indices, skip-reason strings —
is emitted as static-readonly fields on the same class, populated in
the static constructor. This avoids string-interning surprises and
keeps the emitter self-contained.

### 4. Test-module visibility

§3.2 of the language reference grants `@test_module` packages access
to non-`pub` declarations of the package they test. v1 does **not**
implement the cross-package access rule — for now, `@test_module`
behaves like an ordinary single package whose test items get
compiled. Files in `lyric-stdlib/tests/` already work this way (each is
its own package), and the worked-example bank tests put the
`@test_module` package in the *same* package as the code under test,
which v1 supports natively (one file = one package = test items
visible to all of it).

The cross-package case (separate test package referencing a
production package's privates) lands in v2 along with the manifest-
driven discovery story.

### 5. Implementation sequencing

* **Stage 1** (this PR) — emitter shim, synthetic `main`, `lyric
  test <source.l>` CLI, `expect(...)` macro lowering, single-file
  TAP-style output, exit codes, `--list`, `--filter`, two-character
  CLI tests, port a representative `lyric-stdlib/tests/*_tests.l` to use
  `expect` so we exercise the new path.
* **Stage 2** _(shipped — D-progress-297, #465)_ — `--manifest` discovery,
  multi-file test runs via `Emitter.emitProject`, feature-default resolution,
  local-path dep resolution.  Cross-package non-pub access (§3.2) and retiring
  the F# Expecto bridge for the stdlib test suite are follow-up items.
* **Stage 3** — property execution (auto-derived generators for
  primitive types and opaque ranges), `lyric test --properties`,
  doctest harness for ` ```lyric ` blocks.
* **Stage 4** — fixture lifetimes, parallel runs, JUnit XML output,
  `--seed` for reproducible property runs.

Each stage is independently shippable. Stage 1 is the v1 cut; later
stages can land without breaking the surface or the CLI flag set
documented here.

### 5a. JVM target (`lyric test --jvm`)

**Status (D-progress-206, B126):** Bootstrap-grade stub shipped.

The `--jvm` flag switches the test compilation from the .NET-hosted
`Emitter.MSIL` backend to the `Emitter.Jvm` backend. The synthesised
source (produced by `TestSynth`) is compiled to a JAR via the JVM
lowering pipeline.

Current behaviour (B126):
- The synthesised source is compiled with the JVM-compatible stdlib.
- The resulting JAR is written to the output path.
- A warning is printed to stderr: *"JUnit 5 ConsoleLauncher integration
  deferred to B127+"* — the TAP runner still executes via `dotnet exec`
  until the full `LyricTestEngine` lands.

The `@LyricTest` annotation class and test-module class emitter
(`Jvm.TestEngine`: `lyricTestAnnotationClass`, `lowerTestModuleClass`,
`LPTestModule`) are shipped and verified by self-test B126 (see
`docs/32-junit-runner-sketch.md` and D-progress-206 in
`docs/10-bootstrap-progress.md`).

The full `LyricTestEngine` JUnit 5 `TestEngine` implementation is
deferred to B127+ (see `docs/32-junit-runner-sketch.md` §5 and §9
Q-J007e).

### 6. Diagnostics

| Code  | Meaning |
|-------|---------|
| T0900 | `lyric test` invoked on a file without `@test_module`. |
| T0901 | `fixture` declarations are not yet supported. |
| T0902 | `@test_module` package may not declare `func main(): Unit`. |
| T0903 | (reserved — single-arg `expect(...)` lowering is v2 work.) |
| T0904 | `property` declarations are parsed but skipped at runtime. (Warning, not error — the v1 runner emits a TAP `# skip` line.) |

T-codes 0900–0999 are reserved for the test runner.

### 7. Open questions (deferred to v2+)

* **Q-test-1** — Should `@test_module` packages be allowed to call
  `func main(): Unit` of the package they test, or is that always
  T0902? (Default: forbid.)
* **Q-test-2** — Does `lyric test` link `Std.Testing` automatically,
  or must the user `import Std.Testing` explicitly? v1 requires the
  explicit import for parity with `lyric build`.
* **Q-test-3** — Should `expect(a == b)` synthesise structured
  output (`expected: a, actual: b`) by recognising `==` at the AST
  level, or always fall back to the source-text label? v1 uses the
  source-text label exclusively; v2 may special-case `==`/`!=`.
* **Q-test-4** — Doctest discovery: how do we extract ` ```lyric `
  blocks from doc comments without a CST? The lexer currently drops
  non-doc comments, but doc comments survive — so the data is
  preserved. What's missing is a markdown-fenced-block extractor.
  Stage 3.

### 8. Why not defer everything to Phase 5?

Two answers:

1. The F# host *will* go away in Phase 5 §M5.4. When it does, the
   stdlib test suite needs a runner. Building the runner now means
   Phase 5 inherits a working tool rather than a missing one.
2. The native runner is small. Stage 1 is roughly a 200-line
   emitter pass plus a dispatch table — comparable in size to the
   `lyric prove` driver. Doing it now removes the
   exit-code-of-the-PE coupling between Lyric tests and F# Expecto
   that complicates every "run all stdlib tests" workflow.
