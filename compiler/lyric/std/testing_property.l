// std/testing_property.l — Bootstrap-grade property-based testing.
//
// Phase 3 / D-progress-064.  The user supplies a property function
// `(T) -> Bool` and a generator-shaped helper that produces
// random Ts.  `forAll*` runs the property on N samples and panics
// on the first counterexample.
//
// Bootstrap-grade scope: no shrinking (the failing input is
// reported as-is), no Gen[T] type-class — each scalar gets its
// own `forAll<Type>` helper.  Future revisions can layer
// shrinking + composable generators on top of `Std.Iter` and a
// proper Gen monad.
//
// All randomness is supplied by the caller via a `Random` value
// from `Std.Random`; tests can seed it for determinism.
package Std.Testing.Property

import Std.Core
import Std.Random

/// Run `prop` on `n` random `Int` samples in `[min, max)`,
/// panicking with the failing input on the first violation.
/// `n` controls how many samples are drawn; typical usage is
/// 100-1000 per property.
pub func forAllIntRange(
        rng: in Random,
        min: in Int,
        max: in Int,
        n: in Int,
        prop: in (Int) -> Bool): Unit {
  var i: Int = 0
  while i < n {
    val x = nextIntRange(rng, min, max)
    if not prop(x) {
      panic("property failed for Int input: " + toString(x))
    }
    i = i + 1
  }
}

/// Run `prop` on `n` random `Bool` samples.
pub func forAllBool(
        rng: in Random,
        n: in Int,
        prop: in (Bool) -> Bool): Unit {
  var i: Int = 0
  while i < n {
    val b = nextBool(rng)
    if not prop(b) {
      panic("property failed for Bool input: " + toString(b))
    }
    i = i + 1
  }
}

/// Run `prop` on `n` random `Double` samples in `[0.0, 1.0)`.
/// For other ranges, scale the input inside `prop`.
pub func forAllDouble(
        rng: in Random,
        n: in Int,
        prop: in (Double) -> Bool): Unit {
  var i: Int = 0
  while i < n {
    val d = nextDouble(rng)
    if not prop(d) {
      panic("property failed for Double input: " + toString(d))
    }
    i = i + 1
  }
}

/// Run `prop` on `n` random `(Int, Int)` pairs in `[min, max)`.
/// Useful for properties that take two scalars (e.g. commutativity).
pub func forAllIntPair(
        rng: in Random,
        min: in Int,
        max: in Int,
        n: in Int,
        prop: in (Int, Int) -> Bool): Unit {
  var i: Int = 0
  while i < n {
    val x = nextIntRange(rng, min, max)
    val y = nextIntRange(rng, min, max)
    if not prop(x, y) {
      panic(
        "property failed for Int pair: (" + toString(x) + ", " +
        toString(y) + ")")
    }
    i = i + 1
  }
}
