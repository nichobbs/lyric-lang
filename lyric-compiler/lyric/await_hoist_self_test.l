//! await_hoist_self_test.l — dedicated evaluation-order regression test for
//! `Lyric.AwaitHoist` (#5606/#5628, #5630).
//!
//! `async_spawn_self_test.l` already exercises every hoist shape (second-
//! argument awaits, method-call arguments, index expressions, assignment
//! targets, …) but only asserts the resulting VALUE — a value miscompile
//! and an evaluation-order regression can both slip through pure-value
//! assertions built from commutative-looking arithmetic. This file instead
//! has every operand append an ordering marker to a shared `log` before
//! returning its value, so a hoist that silently reorders operands (rather
//! than merely miscomputing one) fails a `log` assertion even when the
//! final numeric result would otherwise look plausible.
//!
//! Shapes covered, each as its own `async func` (only `async func` bodies
//! are rewritten by `Lyric.AwaitHoist`):
//!   - `f(a, await e, b)` — a 3-arg free-function call, second argument
//!     awaited, left/right un-hoisted siblings must still evaluate in
//!     left-to-right order around it.
//!   - a method-call whose RECEIVER is a stacked operand ahead of an
//!     awaited argument (UFCS desugars `recv.m(arg)` to `m(recv, arg)`).
//!   - an index expression (`xs[await e]`) used as a call argument (an
//!     operand-stack position, not a bare `val` initializer).
//!   - assignment-target hoisting (#5628): `xs[await e1] = await e2` must
//!     hoist the TARGET's index before the value, matching normal
//!     left-to-right assignment semantics (`arr[i] = v` reads `arr`/`i`
//!     first).
//!   - #6457 (porting `Lyric.Propagate`'s #6456/#6460 fixes): a MEMBER-target
//!     assign whose value is a bare (or binop-of-two) `await` — `b.value =
//!     await fetchNum()` is exactly `val x = await t`, the shape this pass
//!     otherwise treats as already safe, but the receiver is still stacked
//!     first on MSIL — an index-target assign, a call through a local
//!     LAMBDA VALUE (`f(await e)`), and a call through a CALLEE EXPRESSION
//!     (`getF()(await e)`) — all verified crashing with
//!     `InvalidProgramException` on `--target dotnet` before this round's
//!     fix, unaffected on `--target jvm` (#5936 spills).
//!
//! Run in CI via native `lyric test` on BOTH targets (model:
//! `bitwise_self_test.l`): `--target dotnet` compiles in-process through
//! `Msil.Bridge` (the load-bearing target — `Lyric.AwaitHoist` exists
//! specifically to keep the async-SM `MoveNext` operand stack empty across
//! a suspension); `--target jvm` compiles in-process through `Jvm.Bridge`
//! (`compileToJarBundled`) and runs under `java` (already correct without
//! hoisting, so this pins the rewrite is semantics-preserving there too).
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.AwaitHoistSelfTest

import Std.Collections
import Std.Core
import Std.Testing

// Appends `tag` to `log`, then returns `value`. Used directly as a plain
// (un-hoisted) operand, and via `markAsync` below as the awaited operand —
// both paths make evaluation order directly observable.
func mark(log: in List[String], tag: in String, value: in Int): Int {
  log.add(tag)
  value
}

async func markAsync(log: in List[String], tag: in String, value: in Int): Int {
  return mark(log, tag, value)
}

func joinLog(log: in List[String]): String {
  var s = ""
  var i = 0
  while i < log.count {
    if i > 0 {
      s = s + ","
    }
    s = s + log[i]
    i = i + 1
  }
  s
}

func combine3(a: in Int, b: in Int, c: in Int): Int {
  a * 100 + b * 10 + c
}

// f(a, await e, b): `a` and `c` (plain, un-hoisted operands) must still
// evaluate in left-to-right order around the hoisted awaited middle operand.
async func callSecondArgAwait(log: in List[String]): Int {
  return combine3(mark(log, "a", 1), await markAsync(log, "b", 2), mark(log, "c", 3))
}

record Combiner {
  base: Int

  func combine(self: in Combiner, x: in Int): Int {
    self.base * 100 + x
  }
}

// Same shape as `mark`, but for a receiver value (`Combiner`) instead of an
// `Int` operand.
func markCombiner(log: in List[String], tag: in String, base: in Int): Combiner {
  log.add(tag)
  Combiner(base = base)
}

// Method-call receiver + awaited arg: `<recv>.combine(<arg>)` desugars to
// `combine(<recv>, <arg>)` — the receiver counts as the first stacked
// operand ahead of the awaited argument, so it must log before it.
async func methodReceiverAwait(log: in List[String]): Int {
  val c = markCombiner(log, "recv", 5)
  return c.combine(await markAsync(log, "arg", 7))
}

// Indexing: an index expression containing an await, used as a call
// argument (an operand-stack position — not a bare `val` initializer,
// which already compiles correctly without hoisting).
async func indexArgAwait(log: in List[String]): Int {
  val xs: List[Int] = newList()
  xs.add(10)
  xs.add(20)
  xs.add(30)
  return combine3(mark(log, "a", 1), xs[await markAsync(log, "idx", 1)], mark(log, "c", 3))
}

// #5628: assignment-target hoisting. The TARGET's index must hoist (and
// log) BEFORE the value — matching plain `arr[i] = v`'s "read arr/i first"
// semantics — not the other way around.
async func assignTargetAwait(log: in List[String]): Int {
  val xs: List[Int] = newList()
  xs.add(10)
  xs.add(20)
  xs.add(30)
  xs[await markAsync(log, "tgtidx", 1)] = mark(log, "tgtval", 99)
  return xs[1]
}

test "f(a, await e, b) evaluates left-to-right around the hoisted middle operand" {
  val log: List[String] = newList()
  val result = await callSecondArgAwait(log)
  assertEqualInt(result, 123, "combine3(1, 2, 3)")
  assertEqual(joinLog(log), "a,b,c", "operands log in source order despite the hoist")
}

test "method-call receiver evaluates before the awaited argument" {
  val log: List[String] = newList()
  val result = await methodReceiverAwait(log)
  assertEqualInt(result, 507, "Combiner(base=5).combine(7) == 5*100+7")
  assertEqual(joinLog(log), "recv,arg", "receiver logs before the awaited argument")
}

test "an awaited index expression in argument position evaluates in order" {
  val log: List[String] = newList()
  val result = await indexArgAwait(log)
  assertEqualInt(result, 303, "combine3(1, xs[1]=20, 3) == 1*100 + 20*10 + 3")
  assertEqual(joinLog(log), "a,idx,c", "the index operand logs between its un-hoisted siblings")
}

test "assignment-target hoisting: target index logs before the value (#5628)" {
  val log: List[String] = newList()
  val result = await assignTargetAwait(log)
  assertEqualInt(result, 99, "xs[1] was overwritten to 99")
  assertEqual(joinLog(log), "tgtidx,tgtval", "target index evaluates before the assigned value")
}

// ── #6457: member/index assignment TARGETS stack the receiver on MSIL ────────
// `b.value = await fetchNum()` — verified crashing with
// `InvalidProgramException` before this round's fix: the receiver is
// stacked (`lowerAssignExprMsil` pushes it with no spill) before the value
// resumes across the suspension. Mirrors `Lyric.Propagate`'s #6456 fix.
record Box {
  var value: Int
}

func markBox(log: in List[String], tag: in String): Box {
  log.add(tag)
  Box(value = 0)
}

async func memberAssignAwait(log: in List[String]): Int {
  val b = markBox(log, "recv")
  b.value = await markAsync(log, "val", 42)
  return b.value
}

test "member-target assign await: stores the awaited value (#6457)" {
  val log: List[String] = newList()
  val result = await memberAssignAwait(log)
  assertEqualInt(result, 42, "the awaited value lands through the member write")
  assertEqual(joinLog(log), "recv,val", "receiver, then the awaited value")
}

// A second-await variant: the value is a binop of two awaits, so even
// though `Lyric.AwaitHoist`'s own binop-RHS rule already covers a bare
// `await` in a regular-binop RHS via the emitter's LHS spill
// (`phaseBSpillToLocal`), the OUTER stacked receiver is a hazard that spill
// alone cannot fix — the receiver is pushed before the binop even starts
// evaluating.
async func memberAssignTwoAwaits(log: in List[String]): Int {
  val b = markBox(log, "recv")
  b.value = await markAsync(log, "v1", 10) + await markAsync(log, "v2", 20)
  return b.value
}

test "member-target assign await: two-await value stores the sum (#6457)" {
  val log: List[String] = newList()
  val result = await memberAssignTwoAwaits(log)
  assertEqualInt(result, 30, "10 + 20 through the member write")
  assertEqual(joinLog(log), "recv,v1,v2", "receiver, then both awaited operands in order")
}

test "member-target assign await: receiver still evaluates before the hoisted value (#6457)" {
  val log: List[String] = newList()
  val result = await memberAssignAwait(log)
  assertEqualInt(result, 42, "assignment completes")
  assertEqual(joinLog(log), "recv,val", "receiver, then value — original order preserved by the temps")
}

async func indexAssignAwait(log: in List[String]): Int {
  val xs: List[Int] = newList()
  xs.add(0)
  xs[0] = await markAsync(log, "val", 55)
  return xs[0]
}

test "index-target assign await: stores the awaited value (#6457)" {
  val log: List[String] = newList()
  val result = await indexAssignAwait(log)
  assertEqualInt(result, 55, "the awaited value lands through the index write")
  assertEqual(joinLog(log), "val", "the value expression ran exactly once")
}

// ── #6457: a call through a local LAMBDA VALUE stacks the delegate ref ───────
// `f(await e)` parses to the identical `ECall(EPath, args)` shape as a free
// call, but invoking a lambda-typed local value pushes the delegate
// reference before arguments evaluate on both targets — the old
// first-free-arg exemption was unsound here. Mirrors `Lyric.Propagate`'s
// #6460 fix.
async func lambdaCalleeAwait(log: in List[String]): Int {
  val f: (Int) -> Int = { x: Int -> x * 10 }
  val r = f(await markAsync(log, "arg", 7))
  return r
}

test "lambda-value callee await: invokes with the awaited value (#6457)" {
  val log: List[String] = newList()
  val result = await lambdaCalleeAwait(log)
  assertEqualInt(result, 70, "7 * 10 through the lambda-value call")
  assertEqual(joinLog(log), "arg", "the awaited argument evaluated exactly once")
}

// The same hazard one level up: the callee is itself a call expression
// (`pickDoublerAwait()(await e)`) — the invoked value lands on the stack
// before the argument evaluates.
func pickDoublerAwait(): (Int) -> Int {
  { x: Int -> x * 10 }
}

async func calleeExprCallAwait(log: in List[String]): Int {
  val r = pickDoublerAwait()(await markAsync(log, "arg", 8))
  return r
}

test "callee-expression call await: invokes with the awaited value (#6457)" {
  val log: List[String] = newList()
  val result = await calleeExprCallAwait(log)
  assertEqualInt(result, 80, "8 * 10 through the callee-expression call")
  assertEqual(joinLog(log), "arg", "the awaited argument evaluated exactly once")
}

// ── #6457: await in operand position inside a loop invariant expression ─────
// `ahHasAwaitStmt` covered `SInvariant`/`SRule` but `ahNeedsHoistStmt`
// didn't, so a qualifying await here was detected as present but never
// hoisted (mirroring `Lyric.Propagate`'s #6463 review fix). Both backends
// compile `SInvariant`/`SRule` as a runtime no-op today (`case
// SInvariant(_) -> {}` in `msil/codegen.l`; `LNop` in
// `jvm/codegen/05_stmts.l`), so this is a compiles-and-runs smoke test
// (walk-consistency), not a crash regression pin — the invariant's own
// truth is never checked at runtime by either backend yet.
async func fetchCap(): Int {
  return 1000
}

func combine3Invariant(a: in Int, b: in Int, c: in Int): Int {
  a * 100 + b * 10 + c
}

async func sumWithAwaitInvariant(n: in Int): Int {
  var i = 0
  var sum = 0
  while i < n
    invariant: sum <= combine3Invariant(0, await fetchCap(), 0)
  {
    sum = sum + i
    i = i + 1
  }
  return sum
}

test "await in operand position inside a loop invariant expression compiles (#6457)" {
  val result = await sumWithAwaitInvariant(5)
  assertEqualInt(result, 10, "0+1+2+3+4 = 10 with the await-bearing invariant expression present")
}
