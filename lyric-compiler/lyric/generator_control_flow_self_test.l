//! generator_control_flow_self_test.l — dual-target runtime regression test for
//! `match`, `try`/`finally` and `defer` inside an async generator body (#7729).
//!
//! Before the fix, on `--target dotnet`:
//!
//!   * a `match` in a generator body failed the build in
//!     `synthesizeGeneratorMsil`'s field-count cross-check: Pass 1's
//!     `countGeneratorFieldsMsil` counted neither the scrutinee temporary nor
//!     the slots a pattern allocates (case casts, extracted fields, tuple
//!     elements, bound names), all of which the generator hoists to fields.
//!     The most each pattern shape allocates is now declared next to the
//!     pattern lowering and checked against the real allocation on every
//!     `match` arm the compiler lowers;
//!   * a `yield` inside a `try` built, then failed at run time with "Common
//!     Language Runtime detected an invalid program": the resume `switch`
//!     branched straight into the protected region.  Resumption now enters
//!     each region at its first instruction and re-dispatches there, and a
//!     `finally` is skipped while the generator suspends through it.
//!
//! The cases cover `match` over an `Option` and a user union (payload binds,
//! nested patterns, guards), over a tuple and a record, and as a value; a
//! `yield` inside `try`/`finally`, nested `try`/`finally` and after a `defer`,
//! each consumed to the end with the `finally` observed exactly once; and a
//! record declared after every generator (its field tokens are only right if
//! each generator's Pass-1 prediction held).
//!
//! Only the generator writes to the shared `log`: the JVM generator body runs
//! on a producer thread concurrently with the consumer, so the order of the
//! consumer's own effects relative to the body's is not defined there.
//!
//! Cases that do not run on `--target jvm` yet are in
//! `generator_control_flow_dotnet_self_test.l`.
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

// The tuple elements are only stringified: arithmetic on a tuple-pattern bind
// hits a separate, non-generator gap on both targets (the binds lose their
// element types when the scrutinee comes out of a `List[(Int, Int)]`).
async func genTuples(pairs: in List[(Int, Int)]): String {
  for p in pairs {
    match p {
      case (0, b) -> yield "zero-" + toString(b)
      case (a, 0) -> yield toString(a) + "-zero"
      case (a, b) -> yield toString(a) + "-" + toString(b)
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
  assertEqual(joinStrings(got), "zero-4,3-zero,2-5", "tuple arms")
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

test "generator control flow: record declared after the generators" {
  val r = AfterGenerators(first = passThrough(11), second = "ok")
  assertEqualInt(r.first, 11, "first field")
  assertEqual(r.second, "ok", "second field")
}
