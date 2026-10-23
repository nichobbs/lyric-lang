//! Std.Random on `--target native`: bounds, determinism for a fixed seed,
//! and that every residue of a small range turns up. `random_tests.l` also
//! asserts the contract panics, which need a catchable panic and so cannot
//! run on native (D-N-003); this file covers the rest.
//!
//!   lyric test --target native lyric-stdlib/tests/random_native_tests.l
@test_module
package Std.Random.NativeTests

import Std.Core
import Std.Random
import Std.Testing

test "nextInt is non-negative" {
  val rng = makeRandom(42)
  var ok = true
  var i = 0
  while i < 200 {
    if nextInt(rng) < 0 {
      ok = false
    }
    i = i + 1
  }
  assertTrue(ok, "nextInt never negative")
}

test "nextIntBelow and nextIntRange stay in bounds" {
  val rng = makeRandom(42)
  var ok = true
  var i = 0
  while i < 200 {
    val below = nextIntBelow(rng, 10)
    val ranged = nextIntRange(rng, 5, 15)
    val wide = nextIntRange(rng, -2000000000, 2000000000)
    val full = nextIntRange(rng, -2147483648, 2147483647)
    if below < 0 or below >= 10 or ranged < 5 or ranged >= 15 or wide < -2000000000 or wide >= 2000000000 {
      ok = false
    }
    if full < -2147483648 or full >= 2147483647 {
      ok = false
    }
    i = i + 1
  }
  assertTrue(ok, "every draw inside its range")
  assertEqualInt(nextIntRange(rng, 5, 6), 5, "a one-value range has one outcome")
}

test "nextDouble is in [0, 1)" {
  val rng = makeRandom(42)
  var ok = true
  var i = 0
  while i < 200 {
    val v = nextDouble(rng)
    if v < 0.0 or v >= 1.0 {
      ok = false
    }
    i = i + 1
  }
  assertTrue(ok, "nextDouble inside [0, 1)")
}

test "the same seed gives the same sequence, another seed a different one" {
  val a = makeRandom(1234)
  val b = makeRandom(1234)
  val c = makeRandom(1235)
  var same = true
  var differs = false
  var i = 0
  while i < 20 {
    val x = nextInt(a)
    val y = nextInt(b)
    val z = nextInt(c)
    if x != y {
      same = false
    }
    if x != z {
      differs = true
    }
    i = i + 1
  }
  assertTrue(same, "equal seeds agree")
  assertTrue(differs, "nearby seeds diverge")
}

test "every residue of a small range is drawn" {
  val rng = makeRandom(99)
  var seen0 = false
  var seen1 = false
  var seen2 = false
  var i = 0
  while i < 300 {
    val v = nextIntBelow(rng, 3)
    if v == 0 {
      seen0 = true
    }
    if v == 1 {
      seen1 = true
    }
    if v == 2 {
      seen2 = true
    }
    i = i + 1
  }
  assertTrue(seen0 and seen1 and seen2, "0, 1 and 2 all appear in 300 draws")
}
