//! stdlib/tests/random_tests.l — Tests for Std.Random.
//!
//! Covers the basic range contracts (#7252) added to `nextInt`,
//! `nextIntBelow`, `nextIntRange`, and `nextDouble`, plus the JVM
//! kernel's Long-computed `nextIntRange` no longer overflowing on a wide
//! `[min, max)` range.
package Std.Random.Tests

import Std.Core
import Std.Random
import Std.Testing

func testNextIntNonNegative(): Unit {
  val rng = makeRandom(42)
  var i = 0
  while i < 20 {
    assertTrue(nextInt(rng) >= 0, "nextInt is non-negative")
    i = i + 1
  }
}

func testNextIntBelowRange(): Unit {
  val rng = makeRandom(42)
  var i = 0
  while i < 50 {
    val v = nextIntBelow(rng, 10)
    assertTrue(v >= 0 and v < 10, "nextIntBelow(rng, 10) is in [0, 10)")
    i = i + 1
  }
}

func testNextIntRangeBasic(): Unit {
  val rng = makeRandom(42)
  var i = 0
  while i < 50 {
    val v = nextIntRange(rng, 5, 15)
    assertTrue(v >= 5 and v < 15, "nextIntRange(rng, 5, 15) is in [5, 15)")
    i = i + 1
  }
}

// #7251/#7252: on the JVM, `min + rng.nextInt(max - min)` overflows Int32
// when `max - min` exceeds Int.MaxValue — a wide range spanning most of
// the Int32 domain used to throw IllegalArgumentException even though
// `min < max` held. The kernel now computes the range in Long.
func testNextIntRangeWideRange(): Unit {
  val rng = makeRandom(42)
  val min = -2000000000
  val max = 2000000000
  var i = 0
  while i < 20 {
    val v = nextIntRange(rng, min, max)
    assertTrue(v >= min and v < max, "nextIntRange over a wide range stays in bounds")
    i = i + 1
  }
}

func testNextDoubleRange(): Unit {
  val rng = makeRandom(42)
  var i = 0
  while i < 20 {
    val v = nextDouble(rng)
    assertTrue(v >= 0.0 and v < 1.0, "nextDouble is in [0.0, 1.0)")
    i = i + 1
  }
}

func main(): Unit {
  testNextIntNonNegative()
  testNextIntBelowRange()
  testNextIntRangeBasic()
  testNextIntRangeWideRange()
  testNextDoubleRange()
  println("random: ok")
}
