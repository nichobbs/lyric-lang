# 2026-09-27 — lyric-web's test suite compiles and passes on `--target jvm` (#7578)

Carried over from #7546 → #7578. `lyric-web`'s manifest test suite was never
run on `--target jvm` in CI. Investigating found the JVM backend bugs
(#5443/#5444/#5458) that used to block it from compiling at all had already
been fixed upstream; the six remaining failures were all in `lyric-web`
itself.

## Findings and fixes

- **`dispatch_tests.l`** — `decodeUtf8` used a hand-rolled `@externTarget`
  binding against `System.Text.Encoding` (a .NET-only BCL type), which the
  JVM backend compiled into a class file referencing .NET types and then
  failed codegen outright (`J008: stackmap simulation underflow at
  utf8Encoding`). Replaced with `Std.Encoding.tryDecodeUtf8`, the existing
  cross-platform stdlib decoder — no target-specific code needed at all.

- **`worker_dispatch_tests.l`, `serve_crash_isolation_tests.l`,
  `serve_tls_tests.l`** — each declared `System.Threading.Tasks.Task`/
  `System.Threading.Thread` externs directly (a documented test-only
  exception to the `_kernel/`-only extern rule, mirroring
  `stdlib/tests/tcp_host_tls_tests.l`) to run `Web.serve`/`serveTls` on a
  background thread, since both block the calling thread forever once
  bound. Added `@cfg(feature = "jvm")` twins that submit a
  `WorkerLoopRunnable`/`TestServerRunnable`-shaped record (`impl
  java.lang.Runnable`) to a shared
  `Executors.newVirtualThreadPerTaskExecutor()`, mirroring the dotnet
  `Task.Run` dispatch — a Lyric closure cannot be handed to an arbitrary JDK
  functional interface directly (the strongly-typed-delegate FFI, docs/50,
  is scoped to `@externTarget` function parameters).

  `Web.addWorker`'s worker-dispatch loop had never had a JVM twin at all —
  `Web.Kernel.Runtime`'s `startWorkerLoop` was dotnet-only, blocked (per its
  own header comment) on the same #5444/#5458 bugs. With those fixed, added
  a real JVM implementation: `startWorkerLoop`/`WorkerLoopRunnable`
  (`src/_kernel/jvm/web_kernel.l`) submits each registered `Worker` to the
  same shared virtual-thread executor, with the identical per-tick
  crash-isolation contract (#6935) as the dotnet kernel. `Web.serve`/
  `serveTls` call it right after `server.start()`.

- **`security_aspect_weaving_tests.l`** — already passes on `--target jvm`
  (18/18) on current `main`; the T0020 this issue named has already been
  fixed by unrelated upstream work. One dotnet-only test in this file
  (`HttpCircuitBreaker` circuit-opens-after-threshold, gated
  `@cfg(feature = "dotnet")`, tracked in #3669 — `Resilience.Kernel.Jvm`
  stubs the circuit breaker) is pre-existing, correctly documented, and out
  of scope for this issue.

- **`webtls_config_tests.l`** — re-verified after #7577 ("JVM setVar is
  observable"); it still failed. Root cause: a `config { }` block's
  generated JVM `<clinit>` reads its env var via a *direct* `System.getenv`
  call, entirely bypassing `Std.Environment.setVar`'s process-wide overlay
  (`Std.EnvironmentHost.envOverlay`, added by #7577). This is a real,
  separate compiler gap affecting every `config { }` block on
  `--target jvm` — filed as
  [#7594](https://github.com/nichobbs/lyric-lang/issues/7594) and fixed in
  the same session (see
  `docs/progress/2026-09-27-jvm-config-block-setvar-overlay.md`); the test
  now runs unmodified (a single expectation) on both targets.

## CI wiring

- `lyric-web` added to `scripts/ci/jvm-ecosystem-suites.sh` (with a
  `lyric restore --manifest lyric-web/lyric.toml` step first — it is the
  only suite in that script needing a Maven dependency, `io.undertow:
  undertow-core`).
- `.github/workflows/ci.yml`'s "Ecosystem suites on JVM (storage,
  resilience, jsonrpc, mcp, health)" step renamed to "Ecosystem suites on
  JVM (scripts/ci/jvm-ecosystem-suites.sh)" — it already also ran
  generator-sdk, and now also runs web.

## Also fixed while verifying

While confirming lyric-web's JVM parity end to end, also ran
`tests/jvm_server_smoke.l` (previously blocked on #5444/#5458, hence the
non-compiling status this issue and #7546 inherited) — it now compiles and
its manual verification steps (HTTP round trip, header echo, body echo,
404, TLS/mTLS via `serveTls`) pass under `java`. `lyric-web/README.md` and
`docs/44-jvm-production-readiness-plan.md`/`docs/57-stdlib-ecosystem-library-review.md`
carried stale claims that this suite (and lyric-web's JVM kernel generally)
did not compile/wasn't verified; corrected in place.

## Tests

`lyric test --manifest lyric-web/lyric.toml --target jvm --no-default-features --features jvm`:
8 suites, 88 assertions, 0 failures (was: 4 files failing to compile/run —
`dispatch_tests.l` J008, `worker_dispatch_tests.l`/`serve_crash_isolation_tests.l`
`NoClassDefFoundError`/`VerifyError` on `System.Threading.*`,
`webtls_config_tests.l` 1/2 failing).
`lyric test --manifest lyric-web/lyric.toml` (dotnet, unchanged behaviour):
8 suites, 88 assertions, 0 failures.
`bash scripts/ci/jvm-ecosystem-suites.sh` (full): all 7 suites (storage,
resilience, jsonrpc, mcp, health, generator-sdk, web) pass.

## Docs updated

- `lyric-web/README.md` — top status line, "Background workers", and
  "Known gaps" sections corrected for JVM parity.
- `lyric-web/src/web.l` — module header's addWorker doc comment corrected.
- `docs/44-jvm-production-readiness-plan.md` — J5's stale "lyric-web
  doesn't wire up its JVM kernel package yet" claim corrected.
- `docs/57-stdlib-ecosystem-library-review.md` — `lyric-web` (JVM) removed
  from the unverified bare-`extern package` suspect list (independently
  checked: it doesn't use that pattern).
- `docs/10-bootstrap-progress.md` Tier status — new row, D-progress-1017.
