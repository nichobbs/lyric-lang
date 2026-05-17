# Test Coverage and CI Quality Review

Date reviewed: 2026-05-17  
Reviewer: Test Engineer (automated analysis)

---

## Coverage Matrix: stdlib modules vs. test files

| Module | Test file in `stdlib/tests/` |
|---|---|
| `app.l` | MISSING |
| `char.l` | `char_tests.l` |
| `collections.l` | MISSING |
| `console.l` | MISSING |
| `core.l` | `core_tests.l` |
| `core_proof.l` | MISSING |
| `directory.l` | MISSING |
| `encoding.l` | `encoding_tests.l` |
| `environment.l` | MISSING |
| `errors.l` | `errors_tests.l` |
| `file.l` | MISSING |
| `format.l` | `format_tests.l` |
| `http.l` | MISSING |
| `iter.l` | `iter_tests.l` |
| `json.l` | MISSING |
| `log.l` | MISSING |
| `math.l` | `math_tests.l` |
| `parse.l` | `parse_tests.l` |
| `path.l` | MISSING |
| `process.l` | MISSING |
| `process_capture.l` | MISSING |
| `rest.l` | MISSING |
| `set.l` | `set_tests.l` |
| `sort.l` | `sort_tests.l` |
| `stream.l` | MISSING |
| `string.l` | `string_tests.l` |
| `testing.l` | MISSING (tested implicitly via every other test file) |
| `testing_mocking.l` | `mocking_tests.l` |
| `testing_property.l` | MISSING |
| `testing_snapshot.l` | MISSING |
| `time.l` | MISSING |
| `uuid.l` | `uuid_tests.l` |
| `xml.l` | `xml_tests.l`, `xml_viability_tests.l` |
| `yaml.l` | `yaml_tests.l` |

**20 of 34 stdlib modules have no dedicated test file in `stdlib/tests/`.**

---

## Findings

### F-01 [HIGH] Twenty stdlib modules have no Lyric-level tests

The `stdlib/tests/` directory covers 14 of 34 `stdlib/std/*.l` modules.
Modules with no test file include: `collections`, `json`, `time`, `http`,
`rest`, `file`, `directory`, `path`, `process`, `process_capture`, `stream`,
`console`, `environment`, `app`, `sort` (only a sort_tests exists for `sort`
in the emitter-level tests — there is no stdlib/tests/sort test currently),
`log`, `core_proof`, `testing_property`, `testing_snapshot`.

Of these, `Std.Collections`, `Std.Json`, `Std.Time`, `Std.Http`, and `Std.Rest`
are high-use APIs. `Std.Collections` (List, Map) is used by virtually every
Lyric program; a regression in its API would be wide-blast and currently
undetected at the Lyric test level (though the F# emitter tests cover some
paths incidentally via `StdlibSeedTests`).

File: `stdlib/tests/` (compare with `stdlib/std/*.l`)

### F-02 [HIGH] All 25 ecosystem library packages have zero tests

Every `lyric-*` library directory (`lyric-web`, `lyric-db`, `lyric-cache`,
`lyric-mq`, `lyric-jobs`, `lyric-mail`, `lyric-storage`, `lyric-validation`,
`lyric-ws`, `lyric-session`, `lyric-search`, `lyric-feature-flags`,
`lyric-i18n`, `lyric-logging`, `lyric-otel`, `lyric-proto`, `lyric-grpc`,
`lyric-health`, `lyric-testing`, `lyric-resilience`, `lyric-auth`,
`lyric-aws-secrets`, `lyric-aws-xray`, `lyric-lambda`, `lyric-vscode`) contains
only source `.l` files and a `lyric.toml`. None have a `tests/` directory or
any `*_tests.l` file. The `lyric-testing` library, which is explicitly
designed to provide test helpers (`MockMailSender`, `MockStorageBucket`,
`TestClock`, etc.), has no tests of its own mocks.

This is a complete testing blind spot for production-facing libraries. A
behavioural regression in `Lyric.Web`'s router or `Lyric.Mq`'s idempotency
layer would be invisible until a downstream user reported it.

Directory checked: all `lyric-*/` at repo root.

### F-03 [HIGH] bootstrap.sh is not wired into CI; STRICT_VERIFY is never set

`scripts/bootstrap.sh` implements the three-stage reproducibility check
(F# bootstrap → self-hosted stage-1 → self-hosted stage-2, byte-for-byte
DLL comparison). A search of `.github/workflows/` finds no reference to
`bootstrap.sh` or `STRICT_VERIFY`. The workflow CI runs only `dotnet build`
and the seven Expecto test suites.

Additionally, the bootstrap script's reproducibility check defaults to
reporting-only mode (`STRICT_VERIFY` defaults to `0`): mismatches between
stage-1 and stage-2 DLLs are printed but do not exit non-zero. If
`STRICT_VERIFY=1` is never set (it is not set anywhere in CI or in the
script's own defaults), F# and self-hosted emitter divergence goes
undetected automatically.

File: `scripts/bootstrap.sh` lines 183–221; `.github/workflows/ci.yml` (no
reference to bootstrap).

### F-04 [HIGH] CI smoke tests use `--target dotnet-legacy` exclusively, never testing the default self-hosted MSIL path

The CI smoke test loop at `ci.yml` lines 188–207 explicitly passes
`--target dotnet-legacy` for every `examples/*.l` file:

```
dotnet run --project src/Lyric.Cli ... -- build "$ex" --force --target dotnet-legacy
```

A comment in the workflow explains this as intentional ("The self-hosted MSIL
path is still experimental"), but the self-hosted MSIL emitter (`--target dotnet`,
the current default for end users) is only validated indirectly through the
M1–M83 MSIL self-test suite in `Lyric.Emitter.Tests`. No CI step compiles and
executes a realistic Lyric program through the full self-hosted MSIL pipeline
end-to-end. If the `Msil.Bridge` path regresses on any of the `examples/*.l`
programs, the CI smoke test will pass anyway.

File: `.github/workflows/ci.yml` lines 188–207.

### F-05 [MEDIUM] CI has no lint or format-check step

`lyric lint` (five AST rules, `--error-on-warning` flag) and `lyric fmt --check`
exist as CLI commands and are documented in CLAUDE.md. Neither is invoked in
`ci.yml`. Format drift in the self-hosted Lyric sources (`compiler/lyric/lyric/`,
`stdlib/`) accumulates undetected. Adding `lyric fmt --check` on each `.l` file
and `lyric lint --error-on-warning` to the CI job would catch both at zero cost.

File: `.github/workflows/ci.yml` (absent step).

### F-06 [MEDIUM] CI has no platform matrix — Linux only, no Windows or macOS

The `ci.yml` single job runs on `ubuntu-latest`. The Lyric compiler targets
.NET 10 and ships on all three major platforms; the emitter relies on
`System.Reflection.Emit.PersistedAssemblyBuilder` and
`ManagedPEBuilder`, which have platform-specific PE generation
behaviors (path separators, line endings in embedded resources, culture
ordering). There is no matrix entry for `windows-latest` or `macos-latest`,
so a regression specific to one platform would not be caught before release.

File: `.github/workflows/ci.yml` line 22.

### F-07 [MEDIUM] Coverlet coverage collection will always report zero for Expecto console-app test projects

The coverage step at `ci.yml` lines 98–138 invokes `coverlet` with:

```
coverlet "$dll" --target dotnet --targetargs "$dll"
```

This re-runs the test DLL directly via `dotnet exec`, bypassing `dotnet test`
and MSBuild instrumentation. Expecto projects are console apps, not xUnit/MSTest
test projects, and are not designed to be instrumented by `coverlet.console`
in this mode (coverlet does not rewrite the DLL in-flight for `dotnet exec`
invocations). The result is that `coverlet_status` will reflect non-zero exit
codes consistently, which is silently swallowed by `continue-on-error: true`.
The coverage report will contain empty or near-zero data. The actual coverage
numbers shown in the step summary are not reliable.

File: `.github/workflows/ci.yml` lines 98–138.

### F-08 [MEDIUM] Subprocess-spawning CLI tests have no timeout, creating a CI hang risk

`Lyric.Cli.Tests/ProjectBuildTests.fs` calls `proc.WaitForExit()` without a
timeout argument on both the `runCli` and `runDll` helper functions (lines 32
and 51). If the `lyric build --manifest` subprocess hangs — for example, due
to a deadlock in the self-hosted MSIL bridge or an infinite loop in a
compile-time expansion — the CLI test will block indefinitely. The emitter
test suite (`EmitTestKit.runDll`) applies a 60-second timeout via
`proc.WaitForExit(60_000)`, which is the correct pattern; CLI tests should
match it.

File: `compiler/tests/Lyric.Cli.Tests/ProjectBuildTests.fs` lines 32, 51.  
Compare with: `compiler/tests/Lyric.Emitter.Tests/EmitTestKit.fs` line 43.

### F-09 [MEDIUM] `StdlibLyricTests` is sequenced but sibling emitter tests run in parallel — no temp dir isolation guarantee

`StdlibLyricTests.fs` wraps its test list in `testSequenced`, meaning the
sixteen stdlib Lyric test programs run one at a time. However, the broader
Expecto suite in `Program.fs` does not configure `--parallel false` globally;
by default Expecto runs top-level `testList` entries in parallel. The stdlib
Lyric tests each call `compileAndRun`, which creates a unique GUID-named temp
dir and deletes it after the test. Because the GUID is generated fresh per
call, parallel-safe isolation is preserved at that level. The sequencing is
therefore conservative but correct — no cleanup hazard exists. However, the
`testSequenced` constraint unnecessarily serializes all sixteen tests instead
of letting them run concurrently. If the stdlib test count grows, this becomes
a notable CI time sink.

File: `compiler/tests/Lyric.Emitter.Tests/StdlibLyricTests.fs` line 69.

### F-10 [MEDIUM] Verifier tests are Z3-dependent for negative / counterexample cases, with no mock fallback

`DriverTests.fs` and `RegressionTests.fs` contain numerous tests whose
assertion is conditional on whether Z3 is present:

```fsharp
match r.Outcome with
| Counterexample _ | Unknown _ -> ()
```

Tests with the `Unknown _` fallback pass vacuously in any environment where Z3
is absent. This means a self-hosting regression in the Z3 SMT output pipeline
(e.g. a wrong model parse) would only be caught on CI where Z3 is installed.
The Z3 install step (`sudo apt-get install -y z3`) is in `ci.yml`, so CI
itself is covered, but local developer runs without Z3 would silently skip
counterexample verification. There is no dedicated mock solver that exercises
the counterexample-rendering path deterministically.

File: `compiler/tests/Lyric.Verifier.Tests/DriverTests.fs` (many tests);
`compiler/tests/Lyric.Verifier.Tests/RegressionTests.fs`.

### F-11 [MEDIUM] Benchmark suite has no regression comparison — results are artifact-only

`bench.yml` uploads benchmark artifacts to GitHub Actions but does not compare
results against a previous baseline. `bench_report.py` generates HTML charts
but takes no `--previous` or `--threshold` argument; it has no baseline-loading
path at all. There is no step that fetches a prior run's artifact, computes
percentage change, or fails the job when mean latency regresses by more than
X%. Benchmark data therefore accumulates in GitHub artifacts with no automated
signal for performance regressions.

File: `.github/workflows/bench.yml`; `.github/scripts/bench_report.py`.

### F-12 [MEDIUM] Self-hosted self-test suite has no coverage for the monomorphizer (`mono.l`)

Nine self-test files exist for the self-hosted compiler components:
`lexer_self_test.l`, `parser_self_test.l`, `typechecker_self_test.l`,
`modechecker_self_test.l`, `contract_elaborator_self_test.l`,
`test_synth_self_test.l`, `manifest_self_test.l`, `fmt_self_test.l`,
`verifier_self_test.l`. The monomorphizer (`compiler/lyric/lyric/mono.l`,
`Lyric.Mono`, M5.2 stage 4) has no corresponding `mono_self_test.l`.
Similarly there is no self-test for `cli.l` (`Lyric.Cli`), `repl/repl.l`,
`emitter.l`, or `contract_meta.l`.

File: `compiler/lyric/lyric/` (compare `*_self_test.l` list with the module
list in CLAUDE.md).

### F-13 [MEDIUM] `StdlibLyricTests` assertion is weaker than intended — only checks exit 0 and "ok" substring

`StdlibLyricTests.fs` compiles each `*_tests.l` file and asserts that the
process exits 0 and that stdout contains the string `"ok"`. This means a test
file that prints `"ok at the start"` and then panics mid-run would still pass
if the panic causes a non-zero exit (good), but a test that silently short-
circuits and prints nothing but `"ok"` while skipping all assertions would
also pass. The Lyric `Std.Testing` module uses panic-on-failure semantics, so
this is probably safe in practice — but the runner has no awareness of how many
assertions executed within a file, which makes it impossible to detect a test
file that defines zero assertions.

File: `compiler/tests/Lyric.Emitter.Tests/StdlibLyricTests.fs` lines 51–56.

### F-14 [LOW] JVM target tested only via `javap` structural verification, never via execution

`JvmSelfTest.fs` compiles a Lyric source to a JVM class file and runs
`javap -c` to verify it is structurally valid. The test does not execute the
class file against a JVM (`java -cp ...`). This means a class file that is
structurally valid but produces wrong output at runtime (e.g. wrong integer
constant, wrong method dispatch) would not be caught. Java 21 is installed in
CI (`actions/setup-java@v4`) but `java` is never invoked in any test step.

File: `compiler/tests/Lyric.Emitter.Tests/JvmSelfTest.fs`.

### F-15 [LOW] `bench.yml` uses `continue-on-error: true` on every benchmark step — a silent failure pattern

Each of the four benchmark steps in `bench.yml` (lines 66–101) has
`continue-on-error: true`. A benchmark that fails to compile or crashes at
runtime produces an empty result file (`bench-results/bench_*.txt`),
`bench_report.py` then generates a report with empty sections, and the job
exits 0. There is no step that validates that at least one timing line was
written to each output file, so a silently broken benchmark produces a green
CI run with a blank report section. This makes it impossible to detect
benchmark regressions that manifest as compilation errors.

File: `.github/workflows/bench.yml` lines 66–101.

### F-16 [LOW] `auto-rebase.yml` is triggered by `workflow_dispatch` only, not by pushes to `main`

The CLAUDE.md describes the auto-rebase workflow as running "on each push to
`main`", but the actual `auto-rebase.yml` trigger is `workflow_dispatch` only
— it must be manually triggered. The `auto-merge.yml` (if it exists) may
handle the automatic case, but the rebase action is purely on-demand. This
creates a window where open PRs accumulate merge conflicts against main
without automatic resolution being attempted.

File: `.github/workflows/auto-rebase.yml` lines 1–5.

### F-17 [LOW] Coverage report uses `HtmlInline_AzurePipelines` reporter, which requires Azure DevOps pipeline rendering

`ci.yml` line 153 includes `HtmlInline_AzurePipelines` as a report type, which
generates HTML that embeds Azure DevOps-specific inline scripts for chart
rendering. In a standard GitHub Actions environment this report renders as a
static HTML file without the chart data. The report is uploaded as a GitHub
Actions artifact and is readable but degrades visually outside of Azure
DevOps. Using `Html` (plain) or `HtmlChart` as the primary type would produce
a self-contained report for all CI environments.

File: `.github/workflows/ci.yml` line 153.

### F-18 [LOW] No contract-meta drift check in CI

`lyric public-api-diff` (backed by `Lyric.ContractMeta`) detects changes in
the public API surface and embedded `Lyric.Contract` metadata between builds.
No CI step invokes this command to verify that a PR's public API changes are
intentional. A change that accidentally removes a `pub` function from
`stdlib/std/` or from an ecosystem library would be caught only by whoever
reads the PR diff, not by an automated gate.

File: `.github/workflows/ci.yml` (absent step).

### F-19 [LOW] `StdlibSeedTests` inlines the full stdlib as a single package, masking import-path resolution bugs

`StdlibSeedTests.fs` loads every `.l` file under `stdlib/std/` (including
`_kernel/`), strips each file's `package` declaration, and concatenates them
into one inline body before passing it to the emitter. This approach bypasses
the multi-package import resolution path (`import Std.X` resolved by file
lookup). Actual users write `import Std.Collections`; the test validates the
stdlib logic but not that the importer correctly locates and loads each module
as a separate package. The separate `StdlibImportTests.fs` and
`StdlibLyricTests.fs` partially compensate, but `StdlibSeedTests` remains
misleadingly named and tests a code path no end user exercises.

File: `compiler/tests/Lyric.Emitter.Tests/StdlibSeedTests.fs`.

### F-20 [LOW] Verifier `VcgenTests.fs` and `ImportsTests.fs` do not appear to test any VC generation for string operations, bitwise operators, or union types

`RegressionTests.fs` and `DriverTests.fs` cover identities on `Int`, `Bool`,
`Long`, `String`, `Double`, and `Float32`. There are no tests for:
- Bitwise operators (`BOpXor`, `BOpOr`, `BOpAnd`) in VC generation — only
  their SMT-LIB display is tested in `RegressionTests.fs`.
- String concatenation or string comparison in a `@proof_required` context.
- Union-typed return values in postconditions.
- `match` over union variants (M4.1 supports only wildcard, literal, and bare
  binding patterns per the `DriverTests.fs` comment).

File: `compiler/tests/Lyric.Verifier.Tests/`.

---

## Summary

**Test health: NEEDS ATTENTION**

The compiler's own F# test suite is thorough: seven Expecto projects, 200+
self-hosted MSIL self-tests (M1–M83), 130+ JVM lowering tests (B4–B130), and
a positive/negative verifier regression suite. The verifier in particular has
both positive and negative tests, counterexample rendering tests, and
solver-independence gates. The F# unit tests follow consistent patterns and
use isolated temp directories.

The significant gaps are:

1. Twenty of 34 stdlib modules have no Lyric-level test.
2. All 25 ecosystem library packages (`lyric-*`) have no tests at all.
3. The three-stage bootstrap reproducibility check (`scripts/bootstrap.sh`) is
   not wired into CI and `STRICT_VERIFY` is never enforced.
4. CI smoke tests use `--target dotnet-legacy` exclusively, so the default
   self-hosted MSIL end-to-end path is never exercised on realistic programs.
5. Coverlet's invocation pattern for Expecto console-app projects does not
   produce reliable coverage data — the numbers in the step summary should not
   be trusted.
