# `Std.Task.runWithin[T]`: real bounded-wait timeout on both targets (#7461)

`lyric-health` checks carry a `timeoutMs` budget and panic isolation.
`timeoutMs` was only a real, preemptive bound on `--target dotnet`
(`Health.Kernel.Net`'s private `Task.Run`/`Task.Wait(int)` kernel); on
`--target jvm` it was validated but never enforced, so a hanging check
hung `runLiveness`/`runReadiness` outright. `Health.timeoutEnforced`
existed only so callers could branch on which guarantee applied.

Shipped `Std.Task.runWithin[T](timeoutMs: in Int, f: in () -> T):
Option[T]`: runs `f` off the calling thread, blocks for at most
`timeoutMs`, returns `Some(result)` or `None` on timeout. A timed-out
computation keeps running in the background on both targets (neither
the BCL nor the JDK can forcibly abort a running thread — documented
on the function and in `lyric-health/README.md`). A panic inside `f`,
once observed before the deadline, is re-raised on the calling thread
(propagates, mirroring a direct call), so a caller layers its own
panic isolation on top exactly as `Health.runCheckIsolated` already
does.

- `--target dotnet` (`_kernel/task.l`): `Task.Run(Action,
  CancellationToken)` (existing `taskRunWithCancel`) + a new
  `Task.Wait(int)` binding (`waitTaskMs`) — the same primitives
  `Health.Kernel.Net`'s retired kernel used.
- `--target jvm` (`_kernel_jvm/task.l`): does NOT go through
  `spawn`/`scope { }` (no bounded join exists there — `scope`/`spawn`
  synthesise a `Callable` per *syntactic* spawn site, not a bridge for
  a runtime closure value). Instead mirrors
  `_kernel_jvm/console_host.l`'s bounded stdin reader (`StdinReadJob`
  pattern, #7451): a record implements `java.lang.Runnable` via `impl`
  (docs/51), runs on a real `new Thread(Runnable)`, joined with real
  `Thread.join(long millis)`. No new compiler feature was needed — the
  `impl <ExternInterface> for Record` + `Thread.join` combination was
  already shipped and proven by the console kernel. `timeoutMs == 0`
  is special-cased (never calls `Thread.join(0)`, whose JDK semantics
  mean "wait forever").
- `--target native`: out of scope. `Std.Task` has no
  `_kernel_native/task.l` at all already (`import Std.Task` doesn't
  resolve there independent of this change), and native has no
  `try`/`catch` to capture a background panic even if it did. A
  pthread + `pthread_cond_timedwait`-based bounded wait is plausible
  future work, tracked in #7664.

Building the single-slot result cell surfaced a pre-existing, narrow
self-hosted compiler gap: a generic record's `var`-typed field mutated
through a closure captured inside a GENERIC function silently loses
the write — the field reads back its construction-time value, on both
targets, with no closure/timeout/Task involved at all (minimal repro
in D-progress-1021; tracked in #7663). `Std.Collections.List[T]`'s own mutation does not
have this problem, so both kernels use a `List[T]` as the result cell
instead of a dedicated generic record. Documented as a finding, not
fixed here.

`Health.runCheckIsolated` now calls `Task.runWithin` inside its own
`try/catch Bug`, replacing the `@cfg(feature = "dotnet")` /
`@cfg(feature = "jvm")` split with one implementation identical on
both targets. `Health.Kernel.Net` and `Health.timeoutEnforced` are
removed; `lyric-health`'s timeout test now asserts the same behaviour
on both targets instead of branching on `timeoutEnforced`.

Verified: `lyric-stdlib/tests/task_tests.l` (6 new `runWithin` cases:
in-budget, `String`/record results, timeout, zero-timeout, panic
propagation) on `lyric run` and `--target jvm` + `java -jar`;
`lyric-health`'s 38-assertion suite on `lyric test --manifest
lyric-health/lyric.toml` and `--target jvm --no-default-features
--features jvm`, including the real cross-target timeout regression
test; `scripts/ci/jvm-ecosystem-suites.sh` (8/8);
`scripts/ci/compiler-self-tests-batch.sh` and
`scripts/ci/jvm-generics-self-tests-batch.sh` (0 `not ok`).

See `docs/decisions/D-progress-1021-std-task-runwithin-jvm-timeout.md`
for the full design and the compiler-gap repro.
