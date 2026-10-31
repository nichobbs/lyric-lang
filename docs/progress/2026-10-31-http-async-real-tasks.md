# Std.Http free async functions await real tasks on dotnet (#5608)

On `--target dotnet` the `Std.HttpHost` kernel declared its client and body
operations as `@externTarget async func`. The emitter unwraps those with a
blocking `Task<T>.get_Result()` inside the wrapper, so every `await` in
`hostGetSafe` and friends resolved synchronously: the state machine never
suspended, `getAsync(url)` held its caller until the headers arrived, and two
requests started from one thread ran back to back (3.1 s for two 1.5 s
handlers).

Fix (all in `lyric-stdlib/std/_kernel/http_host.l`, no compiler change):
- The nine blocking async externs are replaced by plain auto-FFI helpers that
  return the live `Task[T]` (`clientGetTask`, `contentTextTask`, ...).
- Each `host*Safe` wrapper now `await`s a real task. A faulted task rethrows at
  the await and V0012 forbids `await` inside `try`, so the wrapper awaits
  `settle(t)` (`Task.WhenAny(t, t)`, which never faults) and then reads the
  outcome with a non-suspending `try` around `Task<T>.Result` (`taskOutcome`).
  Error messages are unchanged: they come from the same `Result` access as
  before.

Result: two 1.5 s requests from one thread finish in about 1.6 s, starting a
request returns in about 20 ms, and cancelling a token ends an in-flight request
before the server answers. `http_async_concurrency_tests.l` covers this in CI.

Not fixed here: `async func`s inside an `impl` or as record methods are lowered
by the MSIL backend as ordinary synchronous methods (the interface slot and the
impl return the bare `T`), so `defaultClient().get(url)` and the other
`HttpClient` interface methods still block their caller. Making them real state
machines changes the interface slot signature, impl lowering, method-call
return tracking and the restored-package MemberRefs; plan on #5608.
JVM and native behaviour are unchanged.
