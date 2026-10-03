//! `Std.Bench.allocatedBytes()` on every target (docs/67 G1).
//!
//! The counter is the current thread's total heap allocation: the CLR's
//! `GC.GetAllocatedBytesForCurrentThread()` on dotnet, the HotSpot
//! `ThreadMXBean.getCurrentThreadAllocatedBytes()` on the JVM and the
//! `lyric_alloc` total of `lyric_rt` on native. `lyric bench` reports the
//! difference between two readings per run; `scripts/ci/bench-vec3-alloc.sh`
//! checks that value records allocate nothing on native.
@test_module
package BenchAllocSelfTest

import Std.Core
import Std.Collections
import Std.Bench
import Std.Testing

func build(n: in Int): List[String] {
  var acc: List[String] = []
  var i = 0
  while i < n {
    acc.add("item " + toString(i))
    i = i + 1
  }
  acc
}

test "the counter is never negative" {
  assertTrue(allocatedBytes() >= 0i64, "allocatedBytes() must not be negative")
}

test "the counter never goes down" {
  val a = allocatedBytes()
  val keep = build(10)
  val b = allocatedBytes()
  assertTrue(b >= a, "a later reading must not be smaller")
  assertEqualInt(keep.count, 10, "kept")
}

test "heap work is counted" {
  val a = allocatedBytes()
  val keep = build(200)
  val b = allocatedBytes()
  assertTrue(b - a >= 200i64, "200 new strings in a list must count at least 200 bytes")
  assertEqualInt(keep.count, 200, "kept")
}
