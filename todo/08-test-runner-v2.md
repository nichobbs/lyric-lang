# Tier 8 — Test Runner v2

## Issues
- **#677** — Property-based test execution: integrate shrinking, seed control, and counterexample replay
- **#678** — Doctests, `--update-snapshots`, and cross-package test access (`@test_visible`)

## Prompt

You are working on the **lyric-lang** repository. Read `CLAUDE.md` fully before doing anything else, then read `docs/24-test-runner-plan.md` for the authoritative test runner design.

Your task is to implement the two v2 test runner features listed above. Work on a new branch named `feat/tier8-test-runner-v2`. Open a **draft** PR immediately after your first commit. Keep it draft until every acceptance criterion below is green. Rebase onto `main` at the start of each work session and before marking ready. Push after every coherent batch of changes.

All implementation goes in `lyric-compiler/lyric/test_synth/` and `lyric-stdlib/std/testing.l` (and companion files in those directories). The F# bootstrap (`Lyric.Cli.Tests`, `StdlibLyricTests.fs`) may need minor wiring — that is acceptable only as thin shim corrections with zero new logic.

---

### #677 — Property-based test execution

`Std.Testing` ships `forAll` and `check` but the test runner (`lyric test`) does not yet call `Std.Testing.runProperties`. Properties are silently skipped — only `@test`-annotated functions run. Shrinking, seed control, and counterexample replay are entirely missing.

**Implement in `lyric-stdlib/std/testing.l` and `lyric-compiler/lyric/test_synth/test_synth.l`:**

1. **`forAll` generator protocol** — The `Gen[T]` type must support:
   - `Gen.int(min: Int, max: Int): Gen[Int]`
   - `Gen.string(maxLen: Int): Gen[String]`
   - `Gen.bool(): Gen[Bool]`
   - `Gen.list(elem: Gen[T], maxLen: Int): Gen[List[T]]`
   - `Gen.map(g: Gen[T], f: T -> U): Gen[U]`
   - `Gen.filter(g: Gen[T], pred: T -> Bool): Gen[T]` (rejection sampling, bounded)
   - `Gen.oneOf(choices: List[Gen[T]]): Gen[T]`

2. **Shrinking** — Every `Gen[T]` must carry a `shrink: T -> List[T]` function alongside its `generate`. Default shrinkers:
   - `Int`: toward 0 by halving
   - `String`: remove last char, then remove middle char, then replace chars with `'a'`
   - `Bool`: `true` shrinks to `[false]`; `false` has no shrinks
   - `List[T]`: remove last element, then remove first element, remove element at each index

3. **`check` function** — `check(gen: Gen[T], prop: T -> Bool, runs: Int = 100): CheckResult` where `CheckResult` is:
   ```lyric
   pub union CheckResult {
     case Passed(runs: Int)
     case Failed(counterexample: Any, shrunk: Any, seed: Long, run: Int)
   }
   ```
   After finding a failing example, `check` must run the shrinker to produce a minimal counterexample.

4. **Seed control** — `check` accepts an optional `seed: Long` parameter. If omitted, a random seed is chosen and recorded in the `Failed` result so the exact run can be replayed. `lyric test --seed <n>` threads the seed through to all `check` calls in the test run.

5. **Counterexample replay** — `lyric test --replay <seed>:<run>` re-runs only the failing run at the given seed, skipping all other runs.

6. **`@property` annotation** — Mark property test functions with `@property(runs=500)`. The test synthesiser (`test_synth.l`) must recognise `@property`-annotated functions and emit calls to `check` wrapping the property body, with the `runs` value from the annotation. Include the `CheckResult` in the TAP output.

7. **TAP output for properties** — On failure, TAP output must include:
   ```
   not ok N - propertyName
   # Counterexample: <value>
   # Shrunk from: <original>
   # Seed: <seed>  Run: <run>
   # Replay: lyric test --replay <seed>:<run>
   ```

**Tests in `lyric-stdlib/tests/property_tests.l`:**
- `forAll` with `Gen.int` finds the counterexample for `x > 0` (counterexample is `<= 0`)
- Shrinker reduces `[1,2,3,4,5]` counterexample list to minimal failing list
- `--seed` flag produces identical run sequence
- `Passed` result returned when property holds for all `runs` samples

---

### #678 — Doctests, `--update-snapshots`, and `@test_visible`

Three distinct features that complement the existing `lyric test` runner:

#### Doctests

A doctest is a `///` doc-comment code fence marked with `lyric`:

```lyric
/// ```lyric
/// assertEqual(add(1, 2), 3)
/// ```
pub func add(a: Int, b: Int): Int = a + b
```

The test synth must extract all such fences from `///` doc-comments, wrap each in a synthesised `@test func __doctest_<n>_<funcName>`, and include them in the test run. Failures cite the source file and line of the doc-comment fence.

**Implementation:**
1. Extend `test_synth.l` to scan `IFunc` doc-comments for `` ``` ``lyric fences.
2. For each fence, synthesise a test function that imports the same package and calls the fence body.
3. Doctests run automatically as part of `lyric test` unless `--no-doctests` is passed.
4. Doctest functions must have access to the module's public API (they run in the same package scope as the function they document).

**Tests:** `lyric-compiler/lyric/test_synth_self_test.l` — add doctest extraction cases; verify the synthesised test function names and bodies are correct.

#### `--update-snapshots`

Snapshot tests use `assertSnapshot(actual: String, name: String)`. On first run (no snapshot file exists), `assertSnapshot` writes the snapshot and passes. On subsequent runs, it compares against the stored snapshot. With `--update-snapshots`, the stored snapshot is overwritten with the new value and the test passes.

**Implementation in `lyric-stdlib/std/testing.l`:**
1. `assertSnapshot` reads/writes snapshot files from a `__snapshots__/` directory adjacent to the test file.
2. The snapshot file name is `<testFuncName>-<snapshotName>.snap`.
3. `lyric test --update-snapshots` sets a flag that causes `assertSnapshot` to overwrite rather than compare.
4. On mismatch (without `--update-snapshots`), the failure message shows a unified diff between expected and actual.

**Tests:** `lyric-stdlib/tests/snapshot_tests.l` — verify that snapshot creation, comparison, and update work correctly (mock the file I/O or use a temp directory).

#### `@test_visible`

`@test_visible` on a `pub` item gives test-code in **other packages** access to the item without requiring it to be part of the public stable API. The item is compiled into the DLL but excluded from `lyric public-api-diff` output and `@stable` requirements.

**Implementation:**
1. Add `@test_visible` to the annotation set in `lyric-compiler/lyric/ast.l`.
2. The type checker must permit cross-package access to `@test_visible` items only when the importing package's manifest has `[dev-dependencies]` (not `[dependencies]`) on the target package.
3. `lyric public-api-diff` must exclude `@test_visible` items from the diff.
4. `lyric-testing` must use `@test_visible` to expose its mock infrastructure to test files without polluting the stable API.

**Tests:** Add a cross-package test in `lyric-testing/tests/` that imports a `@test_visible` function from `lyric-stdlib` and verifies it resolves; verify that a `[dependencies]` (not `[dev-dependencies]`) import of the same item is a type error.

---

## Acceptance Criteria

- [ ] `Gen[T]` type with all specified combinators (`int`, `string`, `bool`, `list`, `map`, `filter`, `oneOf`)
- [ ] Every `Gen[T]` carries a `shrink` function; shrinkers correct for all built-in types
- [ ] `check` finds minimal counterexample via shrinking; `CheckResult` union has `Passed` and `Failed` variants
- [ ] `--seed <n>` flag threads seed through to all `check` calls; same seed → same sequence
- [ ] `--replay <seed>:<run>` re-runs only the specified failing run
- [ ] `@property(runs=N)` annotation recognised by test synth; `check` called with correct `runs`
- [ ] TAP output for failed property includes counterexample, shrunk value, seed, and replay instructions
- [ ] `property_tests.l` passes; shrinking and seed replay verified
- [ ] Doctest extraction from `///` code fences in `test_synth.l`
- [ ] Synthesised doctest functions compile and run as part of `lyric test`
- [ ] `--no-doctests` flag suppresses doctest synthesis
- [ ] Doctest failure cites source file and line of the fence
- [ ] `assertSnapshot` reads/writes `__snapshots__/` relative to test file
- [ ] `--update-snapshots` overwrites stored snapshot; test passes
- [ ] Mismatch without `--update-snapshots` shows unified diff in failure message
- [ ] `snapshot_tests.l` passes; create/compare/update all verified
- [ ] `@test_visible` annotation recognised by type checker
- [ ] `@test_visible` items accessible only via `[dev-dependencies]`; `[dependencies]` import is a type error
- [ ] `lyric public-api-diff` excludes `@test_visible` items from output
- [ ] Cross-package `@test_visible` test in `lyric-testing/tests/` passes
- [ ] All existing tests pass (`dotnet run --project bootstrap/tests/Lyric.Emitter.Tests`, `Lyric.Cli.Tests`)
- [ ] No new F# domain logic
- [ ] No disabled or skipped tests
- [ ] PR is draft until all criteria above are green; then marked ready for review
- [ ] Branch rebased onto `main` immediately before marking ready
