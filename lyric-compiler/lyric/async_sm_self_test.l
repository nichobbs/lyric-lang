// async_sm_self_test.l — regression test for user-defined `async func`
// IAsyncStateMachine synthesis (Phase B.0 + B.1, Epic #2070 / D086).
//
// Phase B.0 covers async functions whose bodies contain NO EAwait nodes.
// Phase B.1 covers async functions whose bodies contain one or more EAwait
// nodes: real AwaitUnsafeOnCompleted suspension with a state-dispatch switch,
// typed awaiter fields, and resume labels.
//
// Test callers use `await asyncXxx(...)` because the kickoff returns Task<T>
// (or Task for void); `emitBlockingAwait` in non-SM contexts synchronously
// resolves via GetAwaiter().GetResult().
//
// Phase B.1 functions (`asyncAddTwo`, `asyncAddThree`, `asyncVoidChain`,
// `asyncSumViaAwait`) await other async functions in their bodies, exercising
// the full SM machinery including state dispatch, AwaitUnsafeOnCompleted,
// resume labels, and awaiter-field stash/restore.
//
//   lyric test lyric-compiler/lyric/async_sm_self_test.l

@test_module
package Lyric.AsyncSmSelfTest

import Std.Core
import Std.Testing

// ── Phase B.0: no awaits in body ─────────────────────────────────────────────

// Returns an Int.  No awaits in the body.
async func asyncAddOne(n: in Int): Int {
  n + 1
}

// Returns a String concatenation.
async func asyncGreet(name: in String): String {
  "Hello, " + name + "!"
}

// Void path: AsyncTaskMethodBuilder, not AsyncTaskMethodBuilder<T>.
async func asyncNoop(): Unit = ()

// Void async func with a side-effecting body (uses a local var).
async func asyncDoubleAndDiscard(n: in Int): Unit {
  val doubled = n * 2
  val _ = doubled
}

// Explicit-return paths (regression for #2256).
async func asyncReturnExplicit(n: in Int): Int {
  return n * 2
}

async func asyncReturnFromBranch(n: in Int): Int {
  if n > 0 { return n }
  0 - n
}

// ── Phase B.1: awaits in body ─────────────────────────────────────────────────

// Two sequential awaits: each chains into Phase B.0 asyncAddOne.
// asyncAddTwo(n) = n + 2
async func asyncAddTwo(n: in Int): Int {
  val a = await asyncAddOne(n)
  await asyncAddOne(a)
}

// Three sequential awaits.
// asyncAddThree(n) = n + 3
async func asyncAddThree(n: in Int): Int {
  val a = await asyncAddOne(n)
  val b = await asyncAddOne(a)
  await asyncAddOne(b)
}

// Void async func that awaits a non-void result and discards it.
async func asyncVoidChain(n: in Int): Unit {
  val _ = await asyncAddOne(n)
}

// Computes (a + b) via two awaits.
// asyncSumViaAwait(a, b) = a + b
async func asyncSumViaAwait(a: in Int, b: in Int): Int {
  val stepped = await asyncAddOne(a - 1)
  await asyncAddOne(stepped + b - 1)
}

// ── Phase B.0 tests ───────────────────────────────────────────────────────────

test "non-void async func: Int return" {
  val result = await asyncAddOne(41)
  assertEqualInt(result, 42, "asyncAddOne(41) should return 42")
}

test "non-void async func: String return" {
  val greeting = await asyncGreet("World")
  assertEqual(greeting, "Hello, World!", "asyncGreet should return the greeting string")
}

test "void async func: no-op completes without error" {
  await asyncNoop()
  assertTrue(true, "void async func returned normally")
}

test "void async func: body with local val completes without error" {
  await asyncDoubleAndDiscard(21)
  assertTrue(true, "void async func with local completed normally")
}

test "non-void async func: result matches synchronous computation" {
  val a = await asyncAddOne(0)
  val b = await asyncAddOne(a)
  val c = await asyncAddOne(b)
  assertEqualInt(c, 3, "three sequential asyncAddOne calls should give 3")
}

test "non-void async func: explicit return computes correct value" {
  val result = await asyncReturnExplicit(21)
  assertEqualInt(result, 42, "asyncReturnExplicit(21) should return 42")
}

test "non-void async func: explicit return from branch computes correct value" {
  val pos = await asyncReturnFromBranch(5)
  val neg = await asyncReturnFromBranch(-3)
  assertEqualInt(pos, 5, "asyncReturnFromBranch(5) should return 5")
  assertEqualInt(neg, 3, "asyncReturnFromBranch(-3) should return 3")
}

// ── Phase B.1 tests ───────────────────────────────────────────────────────────

test "Phase B.1: two sequential awaits produce correct result" {
  val result = await asyncAddTwo(10)
  assertEqualInt(result, 12, "asyncAddTwo(10) should return 12")
}

test "Phase B.1: asyncAddTwo at zero" {
  val result = await asyncAddTwo(0)
  assertEqualInt(result, 2, "asyncAddTwo(0) should return 2")
}

test "Phase B.1: three sequential awaits produce correct result" {
  val result = await asyncAddThree(7)
  assertEqualInt(result, 10, "asyncAddThree(7) should return 10")
}

test "Phase B.1: three sequential awaits from zero" {
  val result = await asyncAddThree(0)
  assertEqualInt(result, 3, "asyncAddThree(0) should return 3")
}

test "Phase B.1: void async func that awaits non-void completes without error" {
  await asyncVoidChain(5)
  assertTrue(true, "asyncVoidChain completed normally")
}

test "Phase B.1: composition of B.1 and B.0 functions" {
  val a = await asyncAddTwo(0)
  val b = await asyncAddOne(a)
  assertEqualInt(b, 3, "asyncAddTwo(0)=2 then asyncAddOne(2)=3")
}

test "Phase B.1: two B.1 functions composed" {
  val a = await asyncAddTwo(0)
  val b = await asyncAddThree(a)
  assertEqualInt(b, 5, "asyncAddTwo(0)=2 then asyncAddThree(2)=5")
}

test "Phase B.1: asyncSumViaAwait correctness" {
  val result = await asyncSumViaAwait(3, 4)
  assertEqualInt(result, 7, "asyncSumViaAwait(3,4) should return 7")
}
