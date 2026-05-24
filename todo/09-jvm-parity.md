# Tier 9 — JVM Platform Parity

## Issues
- **#674** — `lyric run --target jvm` end-to-end: emit JVM bytecode and run via `java`
- **#673** — `lyric-compiler/jvm/` missing `module-path.txt` for JVM module system
- **#676** — JUnit 5 `LyricTestEngine`: full `TestEngine` implementation (B127+)
- **#680** — `lyric bench --target jvm`: JMH-backed benchmarking
- **#675** — GraalVM `native-image` compilation for JVM-target Lyric programs
- **#1065** — JVM `ProcessCaptureHost.runCaptureWithTimeout` Java implementation not shipped

## Prompt

You are working on the **lyric-lang** repository. Read `CLAUDE.md` fully before doing anything else, then read `docs/18-jvm-emission.md` (JVM bytecode emission strategy) and `docs/33-platform-parity-remediation.md` (R1–R6 remediation plan). Also read `docs/32-junit-runner-sketch.md` for the JUnit 5 adapter design.

Your task is to implement full JVM platform parity for the lyric toolchain. Work on a new branch named `feat/tier9-jvm-parity`. Open a **draft** PR immediately after your first commit. Keep it draft until every acceptance criterion below is green. Rebase onto `main` at the start of each work session and before marking ready. Push after every coherent batch of changes.

All implementation goes in `.l` files (JVM codegen in `lyric-compiler/jvm/`, stdlib JVM kernels in `lyric-stdlib/std/_kernel_jvm/`, etc.) plus the minimal Java shim classes in `lyric-stdlib/src/jvm/`. No new F# logic. The only acceptable F# changes are thin shim corrections in `bootstrap/src/` that are required to wire new JVM-side externs.

**Critical constraint:** The self-hosted JVM emitter in `lyric-compiler/jvm/` is the source of truth. Do NOT add JVM emission logic to the F# bootstrap. If a JVM feature is not yet reachable via the self-hosted pipeline, implement it in `lyric-compiler/jvm/` and update the pipeline routing.

---

### #1065 — JVM `ProcessCaptureHost.runCaptureWithTimeout`

`lyric-stdlib/std/_kernel_jvm/process_capture_host.l` declares an opaque type `ProcessCaptureResult` and accessor externs, but the corresponding Java class `lyric.stdlib.jvm.ProcessCaptureResult` and updated `ProcessCaptureHost.runCapture` have not been implemented.

**Implement `lyric-stdlib/src/jvm/ProcessCaptureHost.java`:**
- Run the subprocess with `ProcessBuilder`
- Capture stdout and stderr in parallel (separate threads to avoid pipe deadlock)
- Enforce the timeout via `process.waitFor(timeout, TimeUnit.MILLISECONDS)`
- Return a `ProcessCaptureResult` with `stdout`, `stderr`, `exitCode`, and `timedOut` fields
- The `ProcessCaptureResult` class must be a public Java class with the four fields as accessible instance fields (or via getters matched by the extern accessor names in `process_capture_host.l`)

Remove the `// KNOWN GAP` comment from `process_capture_host.l` once implemented. Update `docs/10-bootstrap-progress.md` accordingly.

**Tests:** `lyric-stdlib/tests/process_capture_tests.l` — add a `@cfg(feature = "jvm")` test case that runs a known subprocess and verifies all four fields in `ProcessCaptureResult`.

---

### #673 — `module-path.txt` for JVM module system

The JVM target's output directory is missing `module-path.txt` — the file that lists the JARs on the module path required to run the compiled program. Without it, `java --module-path $(cat module-path.txt) -m <main>` fails.

**Implement in `lyric-compiler/jvm/`:**

1. During `lyric build --target jvm`, after all JARs are written to the output directory, emit `module-path.txt` listing each JAR path (one per line) that the compiled output depends on.
2. The paths should be relative to the output directory (so `java --module-path $(cat module-path.txt)` works from the output dir).
3. Include the Lyric runtime JAR path.
4. `lyric run --target jvm` must read `module-path.txt` and construct the `java` invocation correctly.

**Tests:** Compile a minimal "hello world" Lyric program with `--target jvm`, verify `module-path.txt` is emitted, and verify `java --module-path $(cat module-path.txt) -m <main>` runs correctly.

---

### #674 — `lyric run --target jvm` end-to-end

`lyric run --target jvm` is partially wired but the end-to-end pipeline from source to running JVM bytecode is not complete. The goal is feature-parity with `lyric run` (which targets .NET).

**Implementation in `lyric-compiler/jvm/` and `lyric-compiler/lyric/cli.l`:**

1. **JVM codegen pipeline** — Ensure the self-hosted JVM emitter in `lyric-compiler/jvm/` can compile the full Lyric language feature set to JVM bytecode:
   - Verify all constructs handled by the MSIL emitter are also handled by the JVM emitter. For any gap, either implement it or emit a clear diagnostic ("feature X not yet supported on JVM target").
   - Cross-package generics (see #858): ensure the monomorphizer passes `GPType` specialisations to the JVM emitter.
   - Async (`async func`, `await`): verify JVM async lowering to coroutines/virtual threads works end-to-end.

2. **`lyric run --target jvm` command** — In `lyric-compiler/lyric/cli.l`:
   - Build via the JVM pipeline
   - Construct the `java` invocation using `module-path.txt` (see #673)
   - Stream stdout/stderr from the `java` process back to the caller
   - Return the process exit code

3. **Parity test** — The `lyric-stdlib/tests/` suite must pass on `--target jvm` as well as `--target dotnet`. Add `@cfg(feature = "jvm")` guards only where genuine JVM-specific differences exist (not as a way to skip tests).

**Tests:** `lyric-compiler/lyric/jvm_self_test.l` covering:
- "Hello, World" compiles and runs on JVM
- A function using generics produces typed IL (not `MObject`) on JVM
- `async func` compiles and yields the correct result on JVM
- The exit code is propagated correctly

---

### #676 — JUnit 5 `LyricTestEngine` (B127+)

The `@LyricTest` annotation class and `Jvm.TestEngine` bridge shipped in B126 (D-progress-206). The full `LyricTestEngine` implementing JUnit 5's `TestEngine` SPI is deferred to B127+.

**Implement `LyricTestEngine`** as a Java class in `lyric-stdlib/src/jvm/`:

1. Register as a JUnit 5 `TestEngine` via `META-INF/services/org.junit.platform.engine.TestEngine`.
2. `discover()` — scan the classpath for classes with `@LyricTest`-annotated methods; return a `TestDescriptor` tree where each method is a leaf `TestDescriptor`.
3. `execute()` — invoke each discovered `@LyricTest` method; map exceptions to `TestExecutionResult.failed(...)`, successful returns to `TestExecutionResult.successful()`.
4. The engine ID must be `"lyric-test-engine"`.
5. `lyric test --target jvm` must invoke `java` with the JUnit Platform Launcher CLI and the `LyricTestEngine` on the classpath, producing TAP-compatible output.

**Update `lyric-compiler/lyric/cli.l`:** The `lyric test --target jvm` command must:
- Synthesise test wrappers (annotated with `@LyricTest`) for `@test`-annotated Lyric functions.
- Compile to JVM bytecode.
- Invoke the JUnit Platform Launcher with `LyricTestEngine`.
- Parse the JUnit XML result and re-emit TAP output.

**Tests:** At least one Lyric `@test` function must round-trip through the JUnit 5 engine on JVM and produce the correct TAP pass/fail output.

---

### #680 — `lyric bench --target jvm` (JMH)

`lyric bench` on `.NET` uses BenchmarkDotNet. On JVM, the equivalent is JMH (Java Microbenchmark Harness). `lyric bench --target jvm` is not yet implemented.

**Implement in `lyric-compiler/lyric/cli.l` and `lyric-stdlib/src/jvm/`:**

1. `@bench` annotation on a Lyric function marks it as a JMH benchmark.
2. The bench synth (extend `test_synth.l` or add `bench_synth.l`) wraps `@bench`-annotated functions in a JMH `@Benchmark`-annotated Java method.
3. `lyric bench --target jvm` compiles the benchmark class, invokes JMH via `java -jar jmh-runner.jar`, and returns a structured JSON result (matching the `.NET` `BenchmarkDotNet` output schema as closely as possible for cross-platform comparison).
4. At minimum: `lyric bench --target jvm` must run, not crash, and produce output for at least one `@bench` function.

**Tests:** A `@bench func noop(): Unit = ()` benchmark must compile and run on JVM without errors. The output must include at least the benchmark name and a numeric result.

---

### #675 — GraalVM `native-image` for JVM-target programs

`lyric build --target jvm --native` must invoke `native-image` to produce a standalone native binary from the compiled JARs. This requires:

1. **Reflection metadata generation** — JVM Lyric programs that use `Std.Reflection` must emit GraalVM reflection config (`reflect-config.json`) alongside the JARs.
2. **`native-image` invocation** — In `lyric-compiler/lyric/cli.l`, after `lyric build --target jvm` completes, construct and run the `native-image` command with the correct classpath and main class.
3. **Closed-world assumption** — Document (in a `// NOTE:` comment in `cli.l`) which Lyric features are incompatible with the GraalVM closed-world assumption and emit a diagnostic for any such feature used in a `--native` build.
4. If GraalVM `native-image` is not on `PATH`, emit a clear diagnostic: `"native-image not found; install GraalVM JDK and set GRAALVM_HOME"`.

**Tests:** The existing `lyric-compiler/lyric/jvm_self_test.l` "Hello, World" case must also pass with `--native` (when `native-image` is available; skip with a `@cfg(feature = "graalvm_native")` guard when it is not).

---

## Acceptance Criteria

- [ ] `lyric.stdlib.jvm.ProcessCaptureHost` Java class implements `runCaptureWithTimeout` with parallel stdout/stderr capture and timeout enforcement
- [ ] `ProcessCaptureResult` has `stdout`, `stderr`, `exitCode`, `timedOut` fields accessible from Lyric
- [ ] `KNOWN GAP` comment removed from `process_capture_host.l`; `docs/10-bootstrap-progress.md` updated
- [ ] JVM `ProcessCaptureResult` test (`@cfg(feature = "jvm")`) passes
- [ ] `module-path.txt` emitted to output directory by `lyric build --target jvm`
- [ ] `java --module-path $(cat module-path.txt) -m <main>` successfully runs a compiled Lyric program
- [ ] `lyric run --target jvm` compiles and runs a Lyric program end-to-end via the self-hosted JVM pipeline
- [ ] Generic functions produce typed JVM IL (not erased to `Object`) at call sites
- [ ] `async func` compiles and runs correctly on JVM target
- [ ] `jvm_self_test.l` passes including generics and async cases
- [ ] `LyricTestEngine` registered as JUnit 5 `TestEngine` via SPI; `engine-id = "lyric-test-engine"`
- [ ] `lyric test --target jvm` discovers and runs `@test`-annotated Lyric functions via JUnit 5
- [ ] TAP output produced from JUnit XML results; pass/fail correctly reported
- [ ] `@bench` annotation recognised; JMH wrapper synthesised by bench synth
- [ ] `lyric bench --target jvm` runs and produces structured output (name + numeric result)
- [ ] `lyric build --target jvm --native` invokes `native-image` when available
- [ ] Reflection config (`reflect-config.json`) emitted for programs using `Std.Reflection`
- [ ] Clear diagnostic when `native-image` not on PATH
- [ ] All existing tests pass (`dotnet run --project bootstrap/tests/Lyric.Emitter.Tests`, `Lyric.Cli.Tests`)
- [ ] No new F# domain logic; only thin shim corrections
- [ ] No disabled or skipped tests (use `@cfg(feature = "jvm")` / `@cfg(feature = "graalvm_native")` guards where required)
- [ ] PR is draft until all criteria above are green; then marked ready for review
- [ ] Branch rebased onto `main` immediately before marking ready
