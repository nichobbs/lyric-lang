// async_sm_self_test.l — regression test for user-defined `async func`
// IAsyncStateMachine synthesis (Phase B.0, Epic #2070 / D086).
//
// Phase B.0 covers async functions whose bodies contain NO EAwait nodes.
// The self-hosted MSIL backend synthesises an IAsyncStateMachine sealed
// class, MoveNext (runs the user body synchronously and calls SetResult),
// and a kickoff function that instantiates the SM, calls ATMB.Start<SM>,
// and returns Task / Task<T>.
//
// These tests exercise the two main paths:
//
//   - void async func (AsyncTaskMethodBuilder, returns Task)
//   - non-void async func (AsyncTaskMethodBuilder<T>, returns Task<T>)
//
// Both are exercised end-to-end through the self-hosted Msil.Bridge with
// runtime value assertions.  The async_extern_self_test.l (Phase A) tests
// @externTarget async; this file tests user-defined async.
//
//   lyric test lyric-compiler/lyric/async_sm_self_test.l

@test_module
package Lyric.AsyncSmSelfTest

import Std.Core
import Std.Testing

// ── Non-void async func ───────────────────────────────────────────────────────
// Returns an Int.  No awaits in the body.  Phase B.0 path.
async func asyncAddOne(n: in Int): Int {
  n + 1
}

// Returns a String concatenation.
async func asyncGreet(name: in String): String {
  "Hello, " + name + "!"
}

// ── Void async func ───────────────────────────────────────────────────────────
// Returns Unit (void path: AsyncTaskMethodBuilder, not AsyncTaskMethodBuilder<T>).
async func asyncNoop(): Unit = ()

// Void async func with a side-effecting body (uses a local var).
async func asyncDoubleAndDiscard(n: in Int): Unit {
  val doubled = n * 2
  val _ = doubled
}

// ── Explicit-return paths (regression for #2256) ─────────────────────────────
// These exercise the MoveNext epilogue reachability fix: explicit `return`
// inside the body must stash the result and branch to the epilogue so that
// SetResult is always called before MoveNext returns.
async func asyncReturnExplicit(n: in Int): Int {
  return n * 2
}

async func asyncReturnFromBranch(n: in Int): Int {
  if n > 0 { return n }
  0 - n
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "non-void async func: Int return" {
  val result = asyncAddOne(41)
  assertEqualInt(result, 42, "asyncAddOne(41) should return 42")
}

test "non-void async func: String return" {
  val greeting = asyncGreet("World")
  assertEqual(greeting, "Hello, World!", "asyncGreet should return the greeting string")
}

test "void async func: no-op completes without error" {
  asyncNoop()
  assertTrue(true, "void async func returned normally")
}

test "void async func: body with local val completes without error" {
  asyncDoubleAndDiscard(21)
  assertTrue(true, "void async func with local completed normally")
}

test "non-void async func: result matches synchronous computation" {
  val a = asyncAddOne(0)
  val b = asyncAddOne(a)
  val c = asyncAddOne(b)
  assertEqualInt(c, 3, "three sequential asyncAddOne calls should give 3")
}

test "non-void async func: explicit return computes correct value" {
  val result = asyncReturnExplicit(21)
  assertEqualInt(result, 42, "asyncReturnExplicit(21) should return 42")
}

test "non-void async func: explicit return from branch computes correct value" {
  val pos = asyncReturnFromBranch(5)
  val neg = asyncReturnFromBranch(-3)
  assertEqualInt(pos, 5, "asyncReturnFromBranch(5) should return 5")
  assertEqualInt(neg, 3, "asyncReturnFromBranch(-3) should return 3")
}
