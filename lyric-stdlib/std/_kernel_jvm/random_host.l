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
//! nextIntRange routes through a Lyric-level shim because java.util.Random
//! only exposes `nextInt(bound)` (i.e. [0, bound)); [min, max) is
//! synthesised as `min + nextInt(max - min)` — a non-positive `max - min`
//! throws `IllegalArgumentException` from the JDK call itself, matching
//! the .NET kernel's "min >= max panics at the boundary" contract.
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

/// Random integer in `[0, max)`. Negative `max` panics at the JDK boundary.
pub func hostNextIntBelow(rng: in Random, max: in Int): Int {
  rng.nextInt(max)
}

/// Random integer in `[min, max)`. `min >= max` panics at the JDK boundary.
pub func hostNextIntRange(rng: in Random, min: in Int, max: in Int): Int {
  min + rng.nextInt(max - min)
}

pub func hostNextLong(rng: in Random): Long {
  rng.nextLong()
}

pub func hostNextDouble(rng: in Random): Double {
  rng.nextDouble()
}
