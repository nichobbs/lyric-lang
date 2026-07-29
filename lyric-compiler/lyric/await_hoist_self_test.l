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
