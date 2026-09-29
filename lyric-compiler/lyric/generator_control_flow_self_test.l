//! generator_control_flow_self_test.l — dual-target runtime regression test for
//! `match`, `try`/`catch`/`finally` and `defer` inside an async generator body
//! (#7729, D142).
//!
//! Before the fix, on `--target dotnet`:
//!
//!   * a `match` in a generator body failed the build in
//!     `synthesizeGeneratorMsil`'s field-count cross-check: Pass 1's
//!     `countGeneratorFieldsMsil` counted neither the scrutinee temporary nor
//!     the slots a pattern allocates (case casts, extracted fields, tuple
//!     elements, bound names), all of which the generator hoists to fields.
//!     A `try`/`catch` failed the same way, because the catch binding's slot
//!     was not counted.  The most each construct allocates is now declared next
//!     to its lowering and checked against the real allocation;
//!   * a `yield` inside a `try` built, then failed at run time with "Common
//!     Language Runtime detected an invalid program": the resume `switch`
//!     branched straight into the protected region.  Resumption now enters
//!     each region at its first instruction and re-dispatches there, and a
//!     `finally` is skipped while the generator suspends through it;
//!   * a consumer that stopped early (`break`) left the pending `finally`
//!     blocks of a generator suspended inside a `try` unrun.
//!
//! On `--target jvm` a consumer that stopped early likewise left the pending
//! `finally`/`defer` blocks to a GC-driven cleaner, and a body `catch` could
//! intercept the interrupt that unwinds the abandoned producer.  The `for` loop
//! now closes the generator's iterator, which unwinds the producer at once and
//! runs only the pending `finally`/`defer` blocks.
//!
//! The cases cover `match` over an `Option` and a user union (payload binds,
//! nested patterns, guards), over a tuple and a record, and as a value; a
//! `yield` inside `try`/`finally`, nested `try`/`finally` and after a `defer`,
//! each consumed to the end with the `finally` observed exactly once;
//! `try`/`catch` in the body, with and without a `yield` in the `try`; a
//! consumer `break` that runs the pending `finally`/`defer` blocks once, runs
//! no `catch`, and surfaces an exception a `finally` raises; and a record
//! declared after every generator (its field tokens are only right if each
//! generator's Pass-1 prediction held).
//!
//! `for` over a `Set[T]` inside a generator is in
//! `generator_control_flow_dotnet_self_test.l` (JVM `Std.Set` is #7312).
//!
//! Run via `lyric test`, compiled in-process on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generator_control_flow_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/generator_control_flow_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.GeneratorControlFlowSelfTest

import Std.Core
import Std.Collections
import Std.Testing

union Shape {
  case Circle(r: Int)
  case Rect(w: Int, h: Int)
  case Tagged(inner: Option[Int], weight: Int)
  case Empty
}

record Point {
  x: Int
  y: Int
}

async func genOption(o: in Option[Int]): Int {
  match o {
    case Some(v) -> yield v
    case None -> yield 0
  }
  yield -1
}

async func genShapes(shapes: in List[Shape]): Int {
  for s in shapes {
    match s {
      case Circle(r) -> yield r * 100
      case Rect(w, h) if w == h -> yield w * w
      case Rect(w, h) -> {
        yield w
        yield h
      }
      case Tagged(Some(v), weight) if weight > 1 -> yield v * weight
      case Tagged(Some(v), _) -> yield v
      case Tagged(None, weight) -> yield 0 - weight
      case Empty -> yield 7
    }
  }
}

async func genTuples(pairs: in List[(Int, Int)]): String {
  for p in pairs {
    match p {
      case (0, b) -> yield "zero-" + toString(b)
      case (a, 0) -> yield toString(a) + "-zero"
      case (a, b) -> yield toString(a) + "+" + toString(b) + "=" + toString(a + b)
    }
  }
}

async func genPoints(points: in List[Point]): Int {
  for p in points {
    match p {
      case Point { x = 0, y = yy } -> yield yy
      case Point { x = xx, y = yy } -> yield xx * yy
    }
  }
}

async func genMatchValue(xs: in List[Int]): String {
  for x in xs {
    val label = match x { case 0 -> "zero"; case n if n < 0 -> "neg"; case _ -> "pos" }
    yield label
  }
}

async func genTryFinally(log: in List[String]): Int {
  log.add("start")
  try {
    yield 1
    log.add("between")
    yield 2
  } finally {
    log.add("finally")
  }
  yield 3
  log.add("end")
}

async func genNestedTry(log: in List[String]): Int {
  try {
    log.add("1")
    yield 1
    try {
      log.add("2")
      yield 2
      log.add("3")
      yield 3
    } finally {
      log.add("inner")
    }
    log.add("4")
    yield 4
  } finally {
    log.add("outer")
  }
  log.add("5")
  yield 5
}

async func genTryInLoop(log: in List[String], n: in Int): Int {
  var i = 0
  while i < n {
    try {
      yield i
    } finally {
      log.add("f" + toString(i))
    }
    i = i + 1
  }
}

async func genDefer(log: in List[String]): Int {
  defer {
    log.add("deferred")
  }
  log.add("1")
  yield 1
  log.add("2")
  yield 2
  log.add("body done")
}

async func genMatchInTry(o: in Option[Int], log: in List[String]): Int {
  try {
    match o {
      case Some(v) -> {
        yield v
        yield v + 1
      }
      case None -> yield 0
    }
  } finally {
    log.add("done")
  }
}

async func genCatchNamed(fail: in Bool, log: in List[String]): Int {
  yield 1
  try {
    if fail {
      panic("boom")
    }
    log.add("no panic")
  } catch Bug as e {
    log.add("caught")
  }
  yield 2
}

async func genCatchDiscarded(fail: in Bool, log: in List[String]): Int {
  try {
    if fail {
      panic("boom")
    }
  } catch Bug as _ {
    log.add("caught")
  }
  yield 3
}

async func genCatchAroundYield(fail: in Bool, log: in List[String]): Int {
  try {
    yield 1
    if fail {
      panic("after resume")
    }
    yield 2
  } catch Bug as e {
    log.add("caught")
  } finally {
    log.add("finally")
  }
  yield 9
}

async func genStoppable(log: in List[String]): Int {
  try {
    try {
      yield 1
      yield 2
      yield 3
    } finally {
      log.add("inner")
    }
  } finally {
    log.add("outer")
  }
  log.add("unreachable after stop")
}

async func genDeferStoppable(log: in List[String]): Int {
  defer {
    log.add("deferred")
  }
  yield 1
  yield 2
}

async func genCatchNotOnStop(log: in List[String]): Int {
  try {
    yield 1
    yield 2
  } catch Bug as e {
    log.add("caught")
  } finally {
    log.add("finally")
  }
  log.add("after")
}

async func genFinallyThrowsOnStop(): Int {
  try {
    yield 1
    yield 2
  } finally {
    panic("cleanup failed")
  }
}

async func genPanicInsideTry(log: in List[String]): Int {
  yield 1
  try {
    panic("caught inside the generator")
  } catch Bug as e {
    log.add("caught: ${e.message}")
  }
  yield 2
}

async func genYieldThenPanicInTry(log: in List[String]): Int {
  try {
    yield 1
    panic("after the first yield")
  } catch Bug as _ {
    log.add("handled")
  }
  yield 2
}

// Two-slot (Long/Double) yields inside and after a try (#7745): the JVM
// `run()` max_stack is exactly the body's tracked peak, so the deepest wide
// yield sequences guard against an under-count.
async func genWideInsideTry(a: in Long, b: in Long, log: in List[String]): Long {
  try {
    yield a * b + a
    panic("after the wide yield")
  } catch Bug as _ {
    log.add("handled")
  }
  yield b + a * b
}

async func genDoubleInsideTry(x: in Double, log: in List[String]): Double {
  try {
    yield (x + 1.0) * (x - 1.0)
    panic("after the Double yield")
  } catch Bug as _ {
    log.add("handled")
  }
  yield x * (x + x * 0.5)
}

record AfterGenerators {
  first: Int
  second: String
}

func passThrough(g: in Int): Int {
  g
}

func joinInts(xs: in List[Int]): String {
  var s = ""
  var i = 0
  while i < xs.count {
    if i > 0 {
      s = s + ","
    }
    s = s + toString(xs[i])
    i = i + 1
  }
  s
}

func joinStrings(xs: in List[String]): String {
  var s = ""
  var i = 0
  while i < xs.count {
    if i > 0 {
      s = s + ","
    }
    s = s + xs[i]
    i = i + 1
  }
  s
}

test "generator match: Option payload bind and None" {
  val got: List[Int] = newList()
  for x in genOption(Some(5)) {
    got.add(x)
  }
  for x in genOption(None) {
    got.add(x)
  }
  assertEqual(joinInts(got), "5,-1,0,-1", "Some(5) then None")
}

test "generator match: user union with nested patterns and guards" {
  val shapes: List[Shape] = newList()
  shapes.add(Circle(r = 2))
  shapes.add(Rect(w = 3, h = 3))
  shapes.add(Rect(w = 4, h = 5))
  shapes.add(Tagged(inner = Some(6), weight = 2))
  shapes.add(Tagged(inner = Some(8), weight = 1))
  shapes.add(Tagged(inner = None, weight = 9))
  shapes.add(Empty)
  val got: List[Int] = newList()
  for x in genShapes(shapes) {
    got.add(x)
  }
  assertEqual(joinInts(got), "200,9,4,5,12,8,-9,7", "every arm in order")
}

test "generator match: tuple patterns" {
  val pairs: List[(Int, Int)] = newList()
  pairs.add((0, 4))
  pairs.add((3, 0))
  pairs.add((2, 5))
  val got: List[String] = newList()
  for x in genTuples(pairs) {
    got.add(x)
  }
  assertEqual(joinStrings(got), "zero-4,3-zero,2+5=7", "tuple arms")
}

test "generator match: record patterns" {
  val points: List[Point] = newList()
  points.add(Point(x = 0, y = 9))
  points.add(Point(x = 3, y = 4))
  val got: List[Int] = newList()
  for x in genPoints(points) {
    got.add(x)
  }
  assertEqual(joinInts(got), "9,12", "record arms")
}

test "generator match: match as a value" {
  val xs: List[Int] = newList()
  xs.add(0)
  xs.add(-3)
  xs.add(8)
  val got: List[String] = newList()
  for s in genMatchValue(xs) {
    got.add(s)
  }
  assertEqual(joinStrings(got), "zero,neg,pos", "labels")
}

test "generator try/finally: yields inside, finally runs once" {
  val log: List[String] = newList()
  val got: List[Int] = newList()
  for x in genTryFinally(log) {
    got.add(x)
  }
  assertEqual(joinInts(got), "1,2,3", "values")
  assertEqual(joinStrings(log), "start,between,finally,end", "finally runs once, after the last yield in the try")
}

test "generator try/finally: nested regions" {
  val log: List[String] = newList()
  val got: List[Int] = newList()
  for x in genNestedTry(log) {
    got.add(x)
  }
  assertEqual(joinInts(got), "1,2,3,4,5", "values")
  assertEqual(joinStrings(log), "1,2,3,inner,4,outer,5", "inner then outer finally, each once")
}

test "generator try/finally: region re-entered on each loop iteration" {
  val log: List[String] = newList()
  val got: List[Int] = newList()
  for x in genTryInLoop(log, 3) {
    got.add(x)
  }
  assertEqual(joinInts(got), "0,1,2", "values")
  assertEqual(joinStrings(log), "f0,f1,f2", "one finally per iteration")
}

test "generator defer: runs once after the last yield" {
  val log: List[String] = newList()
  val got: List[Int] = newList()
  for x in genDefer(log) {
    got.add(x)
  }
  assertEqual(joinInts(got), "1,2", "values")
  assertEqual(joinStrings(log), "1,2,body done,deferred", "deferred block runs at the end")
}

test "generator match inside try/finally" {
  val log: List[String] = newList()
  val got: List[Int] = newList()
  for x in genMatchInTry(Some(4), log) {
    got.add(x)
  }
  for x in genMatchInTry(None, log) {
    got.add(x)
  }
  assertEqual(joinInts(got), "4,5,0", "values")
  assertEqual(joinStrings(log), "done,done", "one finally per run")
}

test "generator try/catch: named binding, with and without a panic" {
  val log: List[String] = newList()
  val got: List[Int] = newList()
  for x in genCatchNamed(true, log) {
    got.add(x)
  }
  for x in genCatchNamed(false, log) {
    got.add(x)
  }
  assertEqual(joinInts(got), "1,2,1,2", "values")
  assertEqual(joinStrings(log), "caught,no panic", "handler runs only on a panic")
}

test "generator try/catch: discarded binding" {
  val log: List[String] = newList()
  val got: List[Int] = newList()
  for x in genCatchDiscarded(true, log) {
    got.add(x)
  }
  assertEqual(joinInts(got), "3", "values")
  assertEqual(joinStrings(log), "caught", "handler ran")
}

test "generator try/catch: yield in the try body, panic after resuming" {
  val log: List[String] = newList()
  val got: List[Int] = newList()
  for x in genCatchAroundYield(true, log) {
    got.add(x)
  }
  assertEqual(joinInts(got), "1,9", "the panic skips the second yield")
  assertEqual(joinStrings(log), "caught,finally", "the resumed region's handlers run")
  val log2: List[String] = newList()
  val got2: List[Int] = newList()
  for x in genCatchAroundYield(false, log2) {
    got2.add(x)
  }
  assertEqual(joinInts(got2), "1,2,9", "no panic")
  assertEqual(joinStrings(log2), "finally", "only the finally runs")
}

test "generator try/finally: consumer stops early, pending finally blocks run once" {
  val log: List[String] = newList()
  val got: List[Int] = newList()
  for x in genStoppable(log) {
    got.add(x)
    if x == 2 {
      break
    }
  }
  assertEqual(joinInts(got), "1,2", "values up to the break")
  assertEqual(joinStrings(log), "inner,outer", "inner then outer finally, each once")
}

test "generator defer: consumer stops early, deferred block runs once" {
  val log: List[String] = newList()
  for x in genDeferStoppable(log) {
    break
  }
  assertEqual(joinStrings(log), "deferred", "deferred block ran on stop")
}

test "generator try/finally: stopping a finished generator runs nothing again" {
  val log: List[String] = newList()
  val got: List[Int] = newList()
  for x in genStoppable(log) {
    got.add(x)
  }
  assertEqual(joinInts(got), "1,2,3", "all values")
  assertEqual(joinStrings(log), "inner,outer,unreachable after stop", "each finally once")
}

test "generator try/catch: stopping the consumer runs the finally, not the catch" {
  val log: List[String] = newList()
  for x in genCatchNotOnStop(log) {
    break
  }
  assertEqual(joinStrings(log), "finally", "only the pending finally runs on stop")
}

test "generator try/finally: an exception from a finally run on stop reaches the consumer" {
  var caught = ""
  try {
    for x in genFinallyThrowsOnStop() {
      break
    }
  } catch Bug as e {
    caught = e.message
  }
  assertTrue(caught.contains("cleanup failed"), "the finally's panic propagated: '" + caught + "'")
}

test "generator try/catch: a panic in the body is caught by the body's own handler" {
  val log: List[String] = newList()
  var total = 0
  for x in genPanicInsideTry(log) {
    total = total + x
  }
  assertEqualInt(total, 3, "both yields around the handled panic arrive")
  assertEqualInt(log.count, 1, "the body's own handler ran once")
  assertTrue(log[0].contains("caught inside the generator"), "the handler saw the body's panic")
}

test "generator try/catch: a panic after a yield is handled on the next pull" {
  val log: List[String] = newList()
  val seen: List[Int] = newList()
  for x in genYieldThenPanicInTry(log) {
    seen.add(x)
    log.add("C${x}")
  }
  assertEqualInt(seen.count, 2, "both yields arrive")
  assertEqual(joinStrings(log), "C1,handled,C2", "the handler runs between the consumer's two steps")
}

test "generator try/catch: Long yields inside and after a try keep their values" {
  val log: List[String] = newList()
  val seen: List[Long] = newList()
  for x in genWideInsideTry(4000000000, 2, log) {
    seen.add(x)
  }
  assertEqualInt(seen.count, 2, "both yields arrive")
  assertEqualLong(seen[0], 12000000000, "4e9 * 2 + 4e9")
  assertEqualLong(seen[1], 8000000002, "2 + 4e9 * 2")
  assertEqualInt(log.count, 1, "the body's handler ran once")
}

test "generator try/catch: Double yields inside and after a try keep their values" {
  val log: List[String] = newList()
  val seen: List[Double] = newList()
  for d in genDoubleInsideTry(3.0, log) {
    seen.add(d)
  }
  assertEqualInt(seen.count, 2, "the try-body yield and the post-try yield arrive")
  assertTrue(seen[0] == 8.0, "(3 + 1) * (3 - 1) = 8")
  assertTrue(seen[1] == 13.5, "3 * (3 + 3 * 0.5) = 13.5")
  assertEqualInt(log.count, 1, "the body's handler ran once")
}

test "generator control flow: record declared after the generators" {
  val r = AfterGenerators(first = passThrough(11), second = "ok")
  assertEqualInt(r.first, 11, "first field")
  assertEqual(r.second, "ok", "second field")
}
