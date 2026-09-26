# D-progress-987 — Protected types are mutually exclusive on the JVM; `when:` barriers work

**Status:** shipped

Closes #7363 (dotnet and JVM; the native barrier half stays with D-N-017).

§7.5 says a protected type's `entry` and `func` operations run one at a
time, and an entry whose `when:` barrier is false blocks until it is true.

- **JVM.** Protected members were plain public methods with no monitor. The
  code called this a documented gap, but the issues it cited (#855, #1833)
  were closed. Four threads doing 2000 read-modify-write entries each ended
  at about 5300 instead of 8000. Every `entry` and `func` is now an
  `ACC_SYNCHRONIZED` method: the instance monitor is held for the whole
  body, it is reentrant, and it is released on an exception.
- **MSIL.** Entries already held `Monitor(this)` in a `finally`, but `func`
  members took no lock, so a `func` could read a half-applied entry (the
  test saw 30 torn reads in 4000). Every `func` is now lowered through the
  same Monitor-guarded path as an entry.
- **T0135.** A protected `func` cannot be `async` (a monitor cannot be held
  across a suspension, and the CLR `Monitor` belongs to the thread that took
  it) or declare its own type parameters (neither backend can lock a
  method-generic member). Both shapes used to compile on dotnet and run
  unlocked. Nothing in the repository used them (#7384 review).
- **Expression-bodied members.** Locking every `func` sent
  `func log(): Unit = println(n)` through the entry lowering, which stored
  the expression's value into a return slot even for `Unit`, leaving an
  empty stack: invalid IL. That arm now discards a `Unit` member's value and
  defaults a value member's void expression, as the ordinary method path
  does (#7400).
- **Barriers.** No backend lowered `when:`, so a barrier member ran with its
  barrier false. The contract elaborator now rewrites each barrier `entry`
  or `func` to start with `while not (barrier) { __lyric_protected_wait() }`.
  In a type with any barrier, every entry and func also gets
  `defer { __lyric_protected_notify() }`, which runs on normal and
  exceptional exit because any state change may enable a waiter. A first
  draft notified only from entries, so a waiter released by a func that set
  the barrier state blocked forever (#7384). Several barriers on one member
  are conjoined. The intrinsics lower onto the member's own lock:
  `Monitor.Wait`/`PulseAll(this)` on MSIL, `Object.wait`/`notifyAll` on the
  JVM. Waiting releases the lock.
  `--target native` has a mutex but no condition variable yet, and now
  rejects a barrier at build time instead of ignoring it (D-N-017).

Library code that relied on protected types for atomicity was racy on the
JVM before this: the shared `Resilience.TokenBucket` rate limiters and
lyric-mq's `IdempotencyLedger` (#7307).

Tests: `protected_exclusion_jvm_self_test.l` (spawned virtual threads) and
`protected_exclusion_dotnet_self_test.l` (`Task.Run`). Each covers lost
updates, torn `func` reads, a one-slot producer/consumer buffer driven by
`when:` barriers, and a gate that a `func` opens while an entry and a
barrier `func` wait on it. All of them failed before.
`typechecker_self_test.l` covers T0135.
