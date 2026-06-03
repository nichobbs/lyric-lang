// std/testing_property.l — Property-based testing with shrinking.
//
// Phase 3 / D-progress-064, redesigned for v1.0.  Provides:
//   • `forAll[T]`            — generic primitive; caller supplies generator,
//                              shrinker, display, and property.
//   • `shrinkInt(n, min)`    — shrinker for Int toward 0 (or min).
//   • `shrinkBool(b)`        — shrinker for Bool toward false.
//   • `forAllInt(…)`         — convenience wrapper for Int ranges.
//   • `forAllBool(…)`        — convenience wrapper for Bool.
//   • `forAllDouble(…)`      — convenience wrapper for Double (no shrinking).
//   • `forAllIntPair(…)`     — paired-Int wrapper with per-component shrinking.
//
// On the first counterexample, `forAll` (and each convenience wrapper)
// calls the shrinker to convergence to find the simplest failing input,
// then panics with the display string of that input.
//
// All randomness is caller-supplied via a `Random` value from `Std.Random`
// so tests can be seeded for determinism.
package Std.Testing.Property

import Std.Core
import Std.Collections
import Std.Random

// ─────────────────────────────────────────────────────────────────────────────
// § Shrinking helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Produce simpler candidate integers from `n`, staying at or above `min`.
/// Tries `n/2` (halving) and `0` (if in range).  Returns an empty list when
/// `n` is already 0 or no strictly simpler candidate exists.
@stable(since="1.0")
pub func shrinkInt(n: in Int, min: in Int): List[Int] {
    val candidates: List[Int] = newList()
    if n != 0 {
        val half = n / 2
        if half >= min and half != n {
            candidates.add(half)
        }
        if 0 >= min and 0 != n and 0 != half {
            candidates.add(0)
        }
    }
    candidates
}

/// Shrink `true` toward `false`; `false` is already minimal.
@stable(since="1.0")
pub func shrinkBool(b: in Bool): List[Bool] {
    val candidates: List[Bool] = newList()
    if b {
        candidates.add(false)
    }
    candidates
}

// ─────────────────────────────────────────────────────────────────────────────
// § Generic primitive
// ─────────────────────────────────────────────────────────────────────────────

// Repeatedly apply `shrink` until no candidate reduces the failure further.
// First-found-wins: once a smaller failure is located the remaining candidates
// at the current level are skipped and the recursion dives into the simpler one.
generic[T] func shrinkToFixedPoint(
        failing: in T,
        shrink:  in (T) -> List[T],
        prop:    in (T) -> Bool): T {
    val candidates = shrink(failing)
    var best = failing
    var j = 0
    while j < candidates.count {
        val candidate = candidates[j]
        if not prop(candidate) {
            best = shrinkToFixedPoint(candidate, shrink, prop)
            j = candidates.count  // first smaller failure wins; skip the rest
        } else {
            j = j + 1
        }
    }
    best
}

/// Run `prop` on `n` random values produced by `gen`.  On the first
/// counterexample, call `shrink` to convergence to find the simplest
/// failing input, then panic with `display(smallest)`.
///
/// Parameters:
///   `rng`     — seeded random source (`Std.Random.makeRandom`).
///   `n`       — number of random samples to draw (typical: 100–1000).
///   `gen`     — generator: produces a `T` from an RNG.
///   `shrink`  — shrinker: given a failing `T`, returns simpler candidates.
///               Return an empty list to disable shrinking.
///   `display` — renders the failing input as a string for the panic message.
///   `prop`    — the property: must hold for all generated inputs.
@stable(since="1.0")
pub generic[T] func forAll(
        rng:     in Random,
        n:       in Int,
        gen:     in (Random) -> T,
        shrink:  in (T) -> List[T],
        display: in (T) -> String,
        prop:    in (T) -> Bool): Unit {
    var i = 0
    while i < n {
        val x = gen(rng)
        if not prop(x) {
            val smallest = shrinkToFixedPoint(x, shrink, prop)
            panic("property failed: " + display(smallest))
        }
        i = i + 1
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// § Convenience wrappers
// ─────────────────────────────────────────────────────────────────────────────

// Converge Int shrinking toward a fixed point for a single-Int property.
// Separated from shrinkToFixedPoint to avoid generic closure capture.
func shrinkIntToFixedPoint(failing: in Int, min: in Int, prop: in (Int) -> Bool): Int {
    val candidates = shrinkInt(failing, min)
    var best = failing
    var j = 0
    while j < candidates.count {
        val c = candidates[j]
        if not prop(c) {
            best = shrinkIntToFixedPoint(c, min, prop)
            j = candidates.count  // first smaller failure wins; skip the rest
        } else {
            j = j + 1
        }
    }
    best
}

// Converge Bool shrinking toward a fixed point for a single-Bool property.
func shrinkBoolToFixedPoint(failing: in Bool, prop: in (Bool) -> Bool): Bool {
    val candidates = shrinkBool(failing)
    var best = failing
    var j = 0
    while j < candidates.count {
        val c = candidates[j]
        if not prop(c) {
            best = c  // Bool shrinks to false in one step; no further recursion
            j = candidates.count  // first smaller failure wins; skip the rest
        } else {
            j = j + 1
        }
    }
    best
}

/// Run `prop` on `n` random `Int` values in `[min, max)`.
/// Failing inputs are shrunk toward 0 (or `min`) before the panic message.
@stable(since="1.0")
pub func forAllInt(
        rng:  in Random,
        min:  in Int,
        max:  in Int,
        n:    in Int,
        prop: in (Int) -> Bool): Unit {
    var i = 0
    while i < n {
        val x = nextIntRange(rng, min, max)
        if not prop(x) {
            val smallest = shrinkIntToFixedPoint(x, min, prop)
            panic("property failed: " + toString(smallest))
        }
        i = i + 1
    }
}

/// Run `prop` on `n` random `Bool` samples.
/// `true` shrinks toward `false`.
@stable(since="1.0")
pub func forAllBool(
        rng:  in Random,
        n:    in Int,
        prop: in (Bool) -> Bool): Unit {
    var i = 0
    while i < n {
        val b = nextBool(rng)
        if not prop(b) {
            val smallest = shrinkBoolToFixedPoint(b, prop)
            panic("property failed: " + toString(smallest))
        }
        i = i + 1
    }
}

/// Run `prop` on `n` random `Double` samples in `[0.0, 1.0)`.
/// Doubles are not shrunk; scale the input inside `prop` for other ranges.
@stable(since="1.0")
pub func forAllDouble(
        rng:  in Random,
        n:    in Int,
        prop: in (Double) -> Bool): Unit {
    var i = 0
    while i < n {
        val d = nextDouble(rng)
        if not prop(d) {
            panic("property failed: " + toString(d))
        }
        i = i + 1
    }
}

/// Run `prop` on `n` random `(Int, Int)` pairs in `[min, max)`.
/// On failure, greedily shrinks each component toward 0 independently:
/// first the left component (right held fixed), then the right.
@stable(since="1.0")
pub func forAllIntPair(
        rng:  in Random,
        min:  in Int,
        max:  in Int,
        n:    in Int,
        prop: in (Int, Int) -> Bool): Unit {
    var i = 0
    while i < n {
        val x = nextIntRange(rng, min, max)
        val y = nextIntRange(rng, min, max)
        if not prop(x, y) {
            val sx = shrinkPairLeft(x, y, min, prop)
            val sy = shrinkPairRight(sx, y, min, prop)
            panic(
                "property failed for pair: (" + toString(sx) +
                ", " + toString(sy) + ")")
        }
        i = i + 1
    }
}

// Shrink the left component of a failing pair, holding the right fixed.
func shrinkPairLeft(
        x:    in Int,
        y:    in Int,
        min:  in Int,
        prop: in (Int, Int) -> Bool): Int {
    val candidates = shrinkInt(x, min)
    var best = x
    var j = 0
    while j < candidates.count {
        val c = candidates[j]
        if not prop(c, y) {
            best = shrinkPairLeft(c, y, min, prop)
            j = candidates.count  // first smaller failure wins; skip the rest
        } else {
            j = j + 1
        }
    }
    best
}

// Shrink the right component of a failing pair, holding the left fixed.
func shrinkPairRight(
        x:    in Int,
        y:    in Int,
        min:  in Int,
        prop: in (Int, Int) -> Bool): Int {
    val candidates = shrinkInt(y, min)
    var best = y
    var j = 0
    while j < candidates.count {
        val c = candidates[j]
        if not prop(x, c) {
            best = shrinkPairRight(x, c, min, prop)
            j = candidates.count  // first smaller failure wins; skip the rest
        } else {
            j = j + 1
        }
    }
    best
}
