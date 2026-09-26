//! stdlib/tests/testing_property_tests.l — Tests for Std.Testing.Property.
//!
//! Covers the property runners' preconditions (#7251) and a JVM regression:
//! `Random`, a `pub alias` Std.Random re-exports from Std.RandomHost, was
//! resolved in Std.Testing.Property as a nonexistent
//! `Std/Testing/Property/Random` class, so every `forAll*` call failed with
//! NoClassDefFoundError on --target jvm.
@test_module
package Std.Testing.Property.ContractsTests

import Std.Core
import Std.Random
import Std.Testing
import Std.Testing.Property

test "forAllInt runs the property over the range" {
  val rng = makeRandom(7)
  forAllInt(rng, 0, 10, 20, { (x: Int) -> x >= 0 and x < 10 })
  assertTrue(true, "every sample was in [0, 10)")
}

test "forAllInt reports the shrunk failing input" {
  val rng = makeRandom(7)
  assertPanicsWith("x < 5 fails", "property failed", { -> forAllInt(rng, 0, 100, 50, { (x: Int) -> x < 5 }) })
}

test "forAllBool and forAllIntPair run" {
  val rng = makeRandom(11)
  forAllBool(rng, 10, { (b: Bool) -> b or not b })
  forAllIntPair(rng, -5, 5, 10, { (a: Int, b: Int) -> a + b == b + a })
  assertTrue(true, "both ran")
}

test "an empty range or zero trials is a precondition failure (#7251)" {
  val rng = makeRandom(7)
  assertPanics("min == max", { -> forAllInt(rng, 5, 5, 10, { (x: Int) -> true }) })
  assertPanics("n == 0", { -> forAllBool(rng, 0, { (b: Bool) -> true }) })
  assertPanics("nextIntRange with an empty range", { -> val _ = nextIntRange(rng, 3, 3) })
  assertPanics("nextIntBelow zero", { -> val _ = nextIntBelow(rng, 0) })
}
