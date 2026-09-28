//! std/_kernel_jvm/random_host.l — JVM host boundary for java.util.Random (PRNG).
//!
//! Mirrors _kernel/random_host.l for the JVM target. Pure Lyric over the
//! JVM auto-FFI (`java.util.Random`) — no `lyric.stdlib.jvm.RandomHost`
//! shim class (that class never existed at runtime; every function here
//! was a phantom `@externTarget` stub that panicked with a bytecode
//! verification error the moment it was actually called — the same
//! elimination already applied to `time_host.l` / `collections_host.l` /
//! `file_host.l`, D-progress-543).
//!
//! Internal: only Std.Random should import this.
//!
//! Package name MUST match the .NET kernel (`Std.RandomHost`) because
//! the consumer in `std/random.l` does `import Std.RandomHost` regardless
//! of target.
//!
//! `Random` implements `java.util.random.RandomGenerator` (JDK 17+), whose
//! default `nextInt(int origin, int bound)` method `hostNextIntRange` calls
//! directly — it is exactly uniform over `[origin, bound)` (an unbiased
//! rejection algorithm, not modulo reduction), handles the full `Int` domain
//! (`origin = Int.MinValue`, `bound = Int.MaxValue`) without overflowing,
//! and throws `IllegalArgumentException` when `origin >= bound`, matching
//! the .NET kernel's "min >= max panics at the boundary" contract. `Random`
//! itself does not override this default, so it dispatches through the
//! resolved `RandomGenerator` default method (auto-FFI walks the JDK
//! interface chain to find it; see `Jvm.AutoFfi.findBestInstanceMethod`).
@axiom("java.util.Random conforms to its documented JDK contracts")
package Std.RandomHost

extern type Random = "java.util.Random"

// Process-wide shared instance, matching the .NET kernel's `Random.Shared`.
val sharedRandom: Random = Random.new()

pub func hostSharedRandom(): Random {
  sharedRandom
}

pub func hostMakeRandom(seed: in Int): Random {
  Random.new(seed.toLong())
}

// java.util.Random.nextInt() returns the full signed 32-bit range, but
// Std.Random.nextInt's documented contract is "non-negative" (matching
// .NET's System.Random.Next(), which is always [0, Int32.MaxValue)) — mask
// off the sign bit rather than returning the raw (possibly negative) value.
pub func hostNextInt(rng: in Random): Int {
  rng.nextInt().and(2147483647)
}

/// Random integer in `[0, max)`. `max <= 0` panics at the JDK boundary
/// (`java.util.Random.nextInt(bound)` requires `bound > 0`) — a narrower
/// precondition than the .NET kernel's `System.Random.Next(max)`, which
/// accepts `max == 0` and returns `0` without throwing.
pub func hostNextIntBelow(rng: in Random, max: in Int): Int {
  rng.nextInt(max)
}

/// Random integer in `[min, max)`, exactly uniform. `min >= max` panics at
/// the JDK boundary.
///
/// Delegates to `RandomGenerator.nextInt(origin, bound)` (#7487) rather than
/// computing `min + nextInt(max - min)` or reducing a wide draw with `%`:
/// the JDK's default implementation is exactly uniform and internally
/// widens to avoid the Int32 `max - min` overflow that a wide range (e.g.
/// `min` near `Int.MinValue` and `max` near `Int.MaxValue`) used to hit
/// feeding `nextInt(bound)` directly (#7252), so no manual overflow
/// handling is needed here either.
pub func hostNextIntRange(rng: in Random, min: in Int, max: in Int): Int {
  rng.nextInt(min, max)
}

pub func hostNextLong(rng: in Random): Long {
  rng.nextLong()
}

pub func hostNextDouble(rng: in Random): Double {
  rng.nextDouble()
}
