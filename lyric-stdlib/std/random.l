//! std/random.l - Pseudorandom number generation.
//!
//! WARNING: System.Random is a PRNG (pseudorandom number generator), NOT a
//! cryptographically secure RNG (CSPRNG).  Do NOT use these functions for
//! security-sensitive purposes such as generating tokens, keys, nonces, or
//! passwords.  Use Std.SecureRandom for cryptographic randomness.
//!
//! All randomness state is managed by the BCL.  Use sharedRandom() for a
//! process-wide shared instance, or makeRandom(seed) for a seeded instance
//! (useful in tests and simulations that require determinism).
@runtime_checked
package Std.Random

import Std.Core
import Std.RandomHost

/// Re-export the Random opaque type so callers need only `import Std.Random`
/// for both the helpers and explicit type annotations.
pub alias Random = Std.RandomHost.Random

/// Return the process-wide shared Random instance.
/// Thread-safe per BCL documentation since .NET 6.
@stable(since = "1.0")
pub func sharedRandom(): Random {
  hostSharedRandom()
}

/// Create a new Random instance with the given integer seed.
/// Two instances with the same seed produce the same sequence.
@stable(since = "1.0")
pub func makeRandom(seed: in Int): Random {
  hostMakeRandom(seed)
}

/// Random non-negative integer.
@stable(since = "1.0")
pub func nextInt(rng: in Random): Int {
  hostNextInt(rng)
}

/// Random integer in `[0, max)`.  Negative `max` panics at the BCL boundary.
@stable(since = "1.0")
pub func nextIntBelow(rng: in Random, max: in Int): Int {
  hostNextIntBelow(rng, max)
}

/// Random integer in `[min, max)`.  `min >= max` panics at the BCL boundary.
@stable(since = "1.0")
pub func nextIntRange(rng: in Random, min: in Int, max: in Int): Int {
  hostNextIntRange(rng, min, max)
}

/// Random 64-bit integer.
@stable(since = "1.0")
pub func nextLong(rng: in Random): Long {
  hostNextLong(rng)
}

/// Random double in [0.0, 1.0).
@stable(since = "1.0")
pub func nextDouble(rng: in Random): Double {
  hostNextDouble(rng)
}

/// Random boolean.
@stable(since = "1.0")
pub func nextBool(rng: in Random): Bool {
  nextIntBelow(rng, 2) != 0
}
