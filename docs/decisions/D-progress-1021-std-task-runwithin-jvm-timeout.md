# D-progress-1021 — `Std.Task.runWithin[T]`: real bounded-wait execution on both targets (#7461)

**Status:** shipped

Fixes #7461. Related: #5329.

## Problem

`lyric-health` checks carry a `timeoutMs` budget and panic isolation.
Before this change, the budget was only a *real* preemptive bound on
`--target dotnet` (`Health.Kernel.Net`'s `Task.Run`/`Task.Wait(int)`);
on `--target jvm` it was validated at registration but not enforced —
a hanging check hung `runLiveness`/`runReadiness` outright, and
`Health.timeoutEnforced` existed purely so callers could branch on
which guarantee applied on which target.

The root cause: there was no general way to run an arbitrary Lyric
closure with a bounded wait on the JVM. A Lyric closure has no bridge
to a JDK functional interface (`Runnable`/`Callable`) outside the
compiler's own `spawn`/`scope { }` keyword codegen, and even that
codegen's `scope { }.join()` / `await` have no bounded/timeout variant
— `scope`/`spawn` synthesise a bespoke `Callable` class per *syntactic*
spawn site at compile time, not a bridge for a *runtime* closure value,
so they cannot back a general stdlib API like `Health`'s check runner.

## Decision

Ship `Std.Task.runWithin[T](timeoutMs: in Int, f: in () -> T):
Option[T]` (Option 1 from the issue): run `f` off the calling thread
and block the caller for at most `timeoutMs`, returning `Some(result)`
when `f` completes in time or `None` on timeout.

- `requires: timeoutMs >= 0`.
- **A timed-out computation keeps running in the background on both
  targets** — neither the BCL nor the JDK has a way to forcibly abort
  a running thread. This is documented on the function itself and in
  `lyric-health/README.md`.
- **Panic semantics:** a panic inside `f`, once *observed* (i.e. only
  if it happens before the deadline), is re-raised on the calling
  thread — `runWithin` itself panics with the same message, exactly as
  a direct call to `f()` would. Panics are never silently swallowed by
  `runWithin`; a caller that wants panic isolation layered on top of
  the timeout wraps the call in its own `try { ... } catch Bug as b {
  ... }`, which is exactly what `Health.runCheckIsolated` already does
  for its own "check panicked" reporting. A panic that occurs only
  after the deadline has already elapsed is unobservable (the same
  "keeps running in the background" caveat).

### Kernel implementations

- **`--target dotnet`** (`lyric-stdlib/std/_kernel/task.l`): reuses
  the existing `taskRunWithCancel` (`Task.Run(Action, CancellationToken)`
  delegate bridging, D122) plus a new `waitTaskMs`
  (`Task.Wait(int)`), the same pattern `Health.Kernel.Net`'s
  now-retired private timeout kernel used.
- **`--target jvm`** (`lyric-stdlib/std/_kernel_jvm/task.l`): does
  **not** go through `spawn`/`scope { }` (no bounded join exists
  there). Instead it mirrors the daemon-thread idiom
  `_kernel_jvm/console_host.l`'s bounded stdin reader already ships
  (`StdinReadJob`/`startJob`/`joinStdinRead`, #7451): a plain record
  implements `java.lang.Runnable` via `impl` (the docs/51
  FFI-interfaces mechanism, already verified working on this target
  by that same file), runs on a real `new Thread(Runnable)`, and the
  calling thread bounds its wait with real `Thread.join(long millis)`
  — which genuinely stops blocking once `millis` elapses. No new
  compiler intrinsic was needed: the `impl <ExternInterface> for
  Record` + `Thread.join(long)` combination was already shipped and
  proven by the console kernel; `runWithin` is a new consumer of it,
  not a new compiler feature. `timeoutMs == 0` is special-cased to
  never call `Thread.join(0)`, whose JDK semantics mean "wait
  forever," not "don't wait."
- **`--target native`**: out of scope. `Std.Task` has no
  `_kernel_native/task.l` at all today — `import Std.Task` does not
  resolve on `--target native` already, independent of this change.
  Native also has no `try`/`catch` (panics abort the process, D-N-003),
  so the "capture a panic on a background thread and re-raise it on
  the caller" contract above cannot be implemented the same way even
  if a native kernel existed. A bounded wait itself could in principle
  be built on `pthread_create` + a condition variable (`pthread_cond_
  timedwait`), but that is new native-runtime (`lyric-rt`) work, not a
  small addition to an existing kernel — tracked in #7664, not
  attempted here.

### A pre-existing, narrow self-hosted compiler gap found and worked around

While building `runWithin[T]`'s single-slot result cell, a generic
record with a mutable field silently failed to propagate a write made
through a closure captured inside a GENERIC function — the field read
back its CONSTRUCTION-time value on both targets. Minimal repro, no
closure, no timeout, no `Task`/`Thread` involved at all:

```
record MyBox[T] { var value: T }
func myFn[T](seed: in T, other: in T): T {
  val box: MyBox[T] = MyBox(value = seed)
  box.value = other
  return box.value  // returns `seed`, not `other` on both targets
}
```

`Std.Collections.List[T]`'s own mutation (`add`/indexing) does **not**
have this problem (confirmed with the same repro shape substituting a
`List[T]` for `MyBox[T]`), so both kernels' `runWithin[T]` use a
`List[T]` as a one-slot result/panic-message cell instead of a
dedicated generic record. This is a genuine, narrow gap in generic
monomorphisation of `var`-field assignment inside a generic function —
not specific to `Std.Task`, to closures, or to either target — and is
called out here as a finding (tracked in #7663), not fixed as part of this change (out of
scope for #7461, which only needed a *working* `runWithin`). No issue
was filed for it as part of this session; a follow-up should file one
citing this entry's repro.

### `lyric-health` migration

`Health.runCheckIsolated` now calls `Task.runWithin(check.timeoutMs,
handler)` inside its own `try { ... } catch Bug as b { ... }` instead
of the old `@cfg(feature = "dotnet")` / `@cfg(feature = "jvm")` split —
one implementation, identical on both targets. `Health.Kernel.Net`
(the private `.NET`-only timeout kernel `lyric-health/src/_kernel/net/
health_kernel.l`) and `Health.timeoutEnforced` are both removed; the
`[features]` table in `lyric-health/lyric.toml` is kept (CI still
selects `--target jvm --no-default-features --features jvm`) but no
longer gates any `@cfg` in the package's own source. The suite's
"honors timeoutMs" test now asserts the SAME behaviour on both targets
instead of branching on `timeoutEnforced`.

## Verification

- `lyric-stdlib/tests/task_tests.l` gained six `runWithin` cases
  (completes-in-budget, `String` result, record result, times out on a
  hanging closure, `timeoutMs == 0` doesn't wait forever, a panic
  observed before the deadline propagates) — passing on both
  `lyric run` (dotnet) and `lyric build --target jvm` + `java -jar`.
- `lyric-health`'s 38-assertion suite passes unchanged on `lyric test
  --manifest lyric-health/lyric.toml` (dotnet) and `--target jvm
  --no-default-features --features jvm`, including "runChecks honors
  timeoutMs on this target" (a 50 ms budget against a 500 ms-sleeping
  check) on BOTH targets — this is the regression test for #7461
  itself.
- `scripts/ci/jvm-ecosystem-suites.sh` (storage, resilience, jsonrpc,
  mcp, health, generator-sdk, web): 8/8 passed.
- `scripts/ci/compiler-self-tests-batch.sh` and `scripts/ci/jvm-
  generics-self-tests-batch.sh`: 0 `not ok`.
