//! std/_kernel/random_host.l - host boundary for System.Random (PRNG).
//!
//! WARNING: System.Random is a PRNG, NOT a cryptographically secure RNG.
//! Do NOT expose this directly for security-sensitive uses. See
//! secure_random_host.l for cryptographic randomness.
//!
//! Internal: only Std.Random should import this.
@axiom("System.Random conforms to its documented .NET contracts; the Shared property returns a thread-safe shared instance (documented since .NET 6)")
package Std.RandomHost

extern type Random = "System.Random"

pub func hostSharedRandom(): Random {
  Random.Shared
}

pub func hostMakeRandom(seed: in Int): Random {
  Random.new(seed)
}

pub func hostNextInt(rng: in Random): Int {
  rng.Next()
}

/// Random integer in `[0, max)`.  Negative `max` panics at the BCL boundary.
pub func hostNextIntBelow(rng: in Random, max: in Int): Int {
  rng.Next(max)
}

/// Random integer in `[min, max)`.  `min >= max` panics at the BCL boundary.
pub func hostNextIntRange(rng: in Random, min: in Int, max: in Int): Int {
  rng.Next(min, max)
}

pub func hostNextLong(rng: in Random): Long {
  rng.NextInt64()
}

pub func hostNextDouble(rng: in Random): Double {
  rng.NextDouble()
}
