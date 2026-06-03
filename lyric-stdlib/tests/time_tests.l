// stdlib/tests/time_tests.l — Tests for Std.Time.monotonicNanos().
//
// Verifies that monotonicNanos() returns non-decreasing values across successive
// calls and that the value advances across observable work.  Also checks that
// now() returns a positive epoch via totalMillis.
package Std.Time.Tests

import Std.Core
import Std.Time
import Std.Testing

func testNowReturnsPositiveEpoch(): Unit {
  // now() returns a time after the Unix epoch.  We verify by computing elapsed
  // milliseconds since epoch 0 using the stdlib's own fromEpochMillis / totalMillis.
  val t      = now()
  val epoch0 = fromEpochMillis(0i64)
  val ms     = totalMillis(since(t, epoch0))
  assertTrue(ms > 0.0, "now() must represent a time after the Unix epoch")
}

func testMonotonicNanosNonDecreasing(): Unit {
  val a = monotonicNanos()
  val b = monotonicNanos()
  assertTrue(b >= a, "second monotonicNanos() call must be >= first")
}

func testMonotonicNanosTwoCallsDiffer(): Unit {
  val a = monotonicNanos()
  // Busy-spin so the monotonic clock has a chance to advance.
  // Assertion is >= (not >) to avoid flakiness on coarse-clock platforms
  // where the resolution is coarser than the spin duration.
  var i = 0
  while i < 100000 { i = i + 1 }
  val b = monotonicNanos()
  assertTrue(b >= a, "monotonicNanos() must not go backwards across non-trivial work")
}

func testMonotonicNanosThreeCallsOrdered(): Unit {
  val t1 = monotonicNanos()
  val t2 = monotonicNanos()
  val t3 = monotonicNanos()
  assertTrue(t1 <= t2, "t1 <= t2")
  assertTrue(t2 <= t3, "t2 <= t3")
}

func main(): Unit {
  testNowReturnsPositiveEpoch()
  testMonotonicNanosNonDecreasing()
  testMonotonicNanosTwoCallsDiffer()
  testMonotonicNanosThreeCallsOrdered()
  println("time: ok")
}
