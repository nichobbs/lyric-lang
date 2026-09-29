//! generator_control_flow_dotnet_self_test.l — `--target dotnet` runtime
//! regression test for generator control flow the JVM backend does not run
//! yet (#7729).  The dual-target cases are in `generator_control_flow_self_test.l`.
//!
//! Each case here is dotnet-only for a named JVM gap, not by design:
//!
//!   * `try`/`catch` in a generator body — `--target jvm` fails at run time
//!     when the generator's producer thread catches a panic (#7720).  On
//!     dotnet the build used to fail in `synthesizeGeneratorMsil`'s field-count
//!     cross-check, because Pass 1 did not count the catch binding's slot.
//!   * a consumer that stops early — the MSIL generator's `DisposeAsync` now
//!     resumes a generator suspended inside a `try` so its pending `finally`
//!     blocks run exactly once.  The JVM producer thread is simply abandoned
//!     when the consumer stops, so its `finally` never runs (reported under #7729;
//!     the producer-thread leak itself is #3565).
//!   * `for` over a `Set[T]` — iterating a `Set` is broken on JVM (#7312).  On
//!     dotnet a `yield` in that loop used to produce invalid IL, because the
//!     loop's `IEnumerable` protocol wraps it in a `try`/`finally`.
//!
//! Run via `lyric test`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generator_control_flow_dotnet_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.GeneratorControlFlowDotnetSelfTest

import Std.Core
import Std.Collections
import Std.CollectionsHost
import Std.Set
import Std.Testing

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

async func genFromSet(s: in Set[Int]): Int {
  for x in s {
    yield x * 10
  }
  yield -1
}

async func genSetThenStop(s: in Set[Int], log: in List[String]): Int {
  try {
    for x in s {
      yield x
    }
  } finally {
    log.add("released")
  }
}

record AfterDotnetGenerators {
  count: Int
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

test "generator for over a Set[Int]" {
  val s: Set[Int] = newSet()
  setAdd(s, 4)
  setAdd(s, 5)
  var total = 0
  var count = 0
  var sawEnd = false
  for x in genFromSet(s) {
    if x == -1 {
      sawEnd = true
    } else {
      total = total + x
      count = count + 1
    }
  }
  assertEqualInt(count, 2, "both elements")
  assertEqualInt(total, 90, "each element scaled")
  assertTrue(sawEnd, "the yield after the loop")
}

test "generator for over a Set[Int]: consumer stops inside the loop" {
  val s: Set[Int] = newSet()
  setAdd(s, 1)
  setAdd(s, 2)
  setAdd(s, 3)
  val log: List[String] = newList()
  var seen = 0
  for x in genSetThenStop(s, log) {
    seen = seen + 1
    break
  }
  assertEqualInt(seen, 1, "one value before the break")
  assertEqual(joinStrings(log), "released", "the enclosing finally ran once")
}

test "generator control flow (dotnet): record declared after the generators" {
  val r = AfterDotnetGenerators(count = 5)
  assertEqualInt(r.count, 5, "field read")
}
