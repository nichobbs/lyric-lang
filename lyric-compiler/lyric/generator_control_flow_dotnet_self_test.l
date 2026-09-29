//! generator_control_flow_dotnet_self_test.l — `--target dotnet` runtime
//! regression test for a `for` over a `Set[T]` inside an async generator body
//! (#7729).  The dual-target cases are in `generator_control_flow_self_test.l`.
//!
//! A `yield` in that loop used to produce invalid IL on dotnet, because the
//! loop's `IEnumerable` protocol wraps it in a `try`/`finally`.  The file is
//! dotnet-only because `Std.Set` is unusable on the JVM (#7312); move these
//! cases into the dual-target file once that is fixed.
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
