//! `Std.Task.Scope` known-failure tracker — split out of `task_tests.l`
//! (#5325) because this test is pinned to D119 slice S3
//! (sibling-cancel-on-first-fault), a separately-tracked, not-yet-shipped
//! feature — not to a routine test-suite fix. Deliberately **NOT**
//! wired into any CI job (see the bottom of this header for why), unlike
//! every other `lyric-stdlib/tests/*.l` file — mirrors the precedent
//! already set by `contract_meta_emit_self_test.l` (tracked in #2580,
//! also unwired) for a test that cannot cleanly pass yet.
//!
//! Status (2026-09-05): this file originally carried THREE tests, all
//! pinned to issue #5329 (`scopeSpawn`/`awaitAll` never actually ran a
//! spawned closure — `Task.Run(Action[, CancellationToken])`'s delegate
//! never invoked on `--target dotnet`, plus a separate null-dereference on
//! an empty scope on both targets). #5329's fix (a lambda literal passed
//! directly to a stdlib function's `() -> Unit`-typed parameter was
//! building a `Func<object>` delegate instead of the `System.Action` that
//! parameter's own signature requires — see `_kernel/task.l`'s module doc,
//! "D119 slice S3" bug (3)) flipped `testScopeNormalCompletionRunsEveryChild`
//! and `testScopeWithNoChildrenCompletesImmediately` green on BOTH targets;
//! both were merged back into `task_tests.l` and are now CI-wired there,
//! per this file's own prior exit condition.
//!
//! The ONE test remaining here, `testScopeSiblingObservesCancelOnFault`,
//! was never actually about #5329's bugs — it tests D119 slice S3's EAGER
//! cross-sibling cancel-on-fault guarantee, a separate feature the
//! `_kernel/task.l` module doc documents as "investigated, NOT shipped",
//! blocked on its OWN still-open bugs (1) `Task.ContinueWith(Action<Task>)`
//! generic-delegate erasure and (2) a `TaskAwaiter`/closure MSIL lowering
//! panic — neither touched by #5329's fix. It now passes on `--target jvm`
//! (real virtual-thread cooperative cancellation) but still fails on
//! `--target dotnet` (no eager cancel-on-fault there yet).
//!
//! **Why this file is not CI-wired:** wiring in a test that fails on one
//! target but not the other either breaks the build for a reason no
//! change in this repo can fix today (dishonest red) or requires catching
//! the failure and reporting green anyway (dishonest green — the "Ignore-
//! attributed tests" pattern `CLAUDE.md` explicitly forbids). Once D119
//! slice S3 ships on `--target dotnet` (a separate, larger effort than
//! #5329 — tracked by the two open bugs above, not by #5329 itself),
//! delete this header's caveat, merge this test back into `task_tests.l`,
//! and wire the merged file into CI like every other
//! `lyric-stdlib/tests/*.l` file.
package Std.Task.Tests.ScopeKnownFailures

import Std.Core
import Std.Task
import Std.Testing
import Std.Time

// ─── Scope: D119 slice S3 sibling-cancel-on-first-fault ──────────────────────
// One sibling panics; the other polls the scope's token in a loop.  awaitAll
// must still surface the fault (pre-existing `Task.WhenAll` behaviour on
// .NET; this backend's own join loop on JVM), and — the D119 S3 guarantee —
// the polling sibling must observe the cancellation and stop before its loop
// runs to completion.
func testScopeSiblingObservesCancelOnFault(): Unit {
  val sc = makeScope()
  val tok = scopeToken(sc)
  var observedCancel = false
  var ranToCompletion = false
  scopeSpawn(sc, { -> panic("boom") })
  scopeSpawn(
    sc,
    { ->
      var i = 0
      var stopped = false
      while i < 500 and not stopped {
        if isCancelled(tok) {
          observedCancel = true
          stopped = true
        } else {
          sleepMillis(2)
          i = i + 1
        }
      }
      if not stopped {
        ranToCompletion = true
      }
    }
  )
  assertPanics("awaitAll rethrows the faulting sibling's panic", { -> val r = await awaitAll(sc) })
  cancelScope(sc)
  disposeScope(sc)
  assertTrue(observedCancel, "the non-faulting sibling observed cancellation while still running")
  assertFalse(ranToCompletion, "the non-faulting sibling stopped early rather than running its full loop")
}

// Runs the D119 S3 test in isolation and reports it — the same
// isolate-and-report shape #5323 established for this file, kept even
// though there is only one test left, in case a future addition needs it
// again.  Returns true when the test's real assertions passed (i.e. D119
// slice S3 has shipped for this target), false when it hit the still-open
// known failure.
func runScopeTest(name: in String, test: () -> Unit): Bool {
  try {
    test()
    println("ok - " + name)
    true
  } catch Bug as bug {
    println("KNOWN FAILURE (D119 slice S3) - " + name + ": " + bug.message)
    false
  }
}

func main(): Int {
  val r1 = runScopeTest("testScopeSiblingObservesCancelOnFault", testScopeSiblingObservesCancelOnFault)
  if r1 {
    println("D119 slice S3 passed - merge this file back into task_tests.l and wire it into CI")
    0
  } else {
    println("known D119 slice S3 failure reproduced - see above; this file is intentionally not CI-wired")
    1
  }
}
