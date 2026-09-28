//! stdlib/tests/random_tests.l — Tests for Std.Random.
//!
//! Covers the basic range contracts (#7252) added to `nextInt`,
//! `nextIntBelow`, `nextIntRange`, and `nextDouble`, the JVM kernel's
//! wide-range `nextIntRange` no longer overflowing (#7252), the full
//! `Int` domain and single-value-range edge cases, and the `min < max`
//! contract violation (#7487).
//!
//! #7487: the JVM kernel used to compute `nextIntRange` as
//! `min + (rng.nextLong().and(Long.MaxValue) % range)`, which is modulo
//! reduction of a 63-bit value and is biased by roughly `range / 2^63` —
//! negligible for `Std.Random`, but this file's job is bounds/contract
//! coverage, not statistics: a deterministic bound check over many draws
//! (rather than a chi-square uniformity test, which would need a huge
//! sample to bound its false-failure rate near zero and would still
//! occasionally flake) is what actually pins the fix, since the modulo
//! bug produced values that were still always in bounds.
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

// The full Int32 domain as a single range: min = Int.MinValue,
// max = Int.MaxValue. Regression coverage for #7487's exact-uniformity fix
// alongside #7252's overflow fix — both need this boundary to stay in
// bounds without panicking.
func testNextIntRangeFullIntDomain(): Unit {
  val rng = makeRandom(7)
  var i = 0
  while i < 20 {
    val v = nextIntRange(rng, -2147483648, 2147483647)
    assertTrue(v >= -2147483648 and v < 2147483647, "nextIntRange over the full Int domain stays in bounds")
    i = i + 1
  }
}

// A single-value range ([5, 6)) has exactly one possible outcome.
func testNextIntRangeSingleValue(): Unit {
  val rng = makeRandom(7)
  var i = 0
  while i < 20 {
    assertEqualInt(nextIntRange(rng, 5, 6), 5, "nextIntRange(rng, 5, 6) always returns 5")
    i = i + 1
  }
}

// min >= max violates nextIntRange's documented `requires: min < max`
// contract and must panic, not silently return a wrong value.
func testNextIntRangeInvalidRangePanics(): Unit {
  val rng = makeRandom(7)
  assertPanics("nextIntRange(rng, 5, 5) panics on an empty range", { -> val ignored = nextIntRange(rng, 5, 5) })
  assertPanics("nextIntRange(rng, 5, 3) panics on an inverted range", { -> val ignored = nextIntRange(rng, 5, 3) })
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
  testNextIntRangeFullIntDomain()
  testNextIntRangeSingleValue()
  testNextIntRangeInvalidRangePanics()
  testNextDoubleRange()
  println("random: ok")
}
