// stdlib/tests/time_tests.l — Tests for Std.Time.
//
// Covers: nowMs returns a positive epoch, monotonicNanos returns non-decreasing
// values across successive calls, and the difference between two calls is
// non-zero after any observable work.
package Std.Time.Tests

import Std.Core
import Std.Time
import Std.Testing

func testNowMsPositive(): Unit {
  val t = nowMs()
  assertTrue(t > 0L, "nowMs() must return a positive epoch millisecond value")
}

func testMonotonicNanosNonDecreasing(): Unit {
  val a = monotonicNanos()
  val b = monotonicNanos()
  assertTrue(b >= a, "second monotonicNanos() call must be >= first")
}

func testMonotonicNanosTwoCallsDiffer(): Unit {
  val a = monotonicNanos()
  // Busy-spin a tiny bit so the clock has a chance to advance.
  var i = 0
  while i < 10000 { i = i + 1 }
  val b = monotonicNanos()
  assertTrue(b > a, "monotonicNanos() must advance across non-trivial work")
}

func testMonotonicNanosThreeCallsOrdered(): Unit {
  val t1 = monotonicNanos()
  val t2 = monotonicNanos()
  val t3 = monotonicNanos()
  assertTrue(t1 <= t2, "t1 <= t2")
  assertTrue(t2 <= t3, "t2 <= t3")
}

func main(): Unit {
  testNowMsPositive()
  testMonotonicNanosNonDecreasing()
  testMonotonicNanosTwoCallsDiffer()
  testMonotonicNanosThreeCallsOrdered()
  println("time: ok")
}
