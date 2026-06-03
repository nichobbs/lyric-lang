// std/_kernel/random_host.l - host boundary for System.Random (PRNG).
//
// WARNING: System.Random is a PRNG, NOT a cryptographically secure RNG.
// Do NOT expose this directly for security-sensitive uses. See
// secure_random_host.l for cryptographic randomness.
//
// Internal: only Std.Random should import this.

@axiom("System.Random conforms to its documented .NET contracts; the Shared property returns a thread-safe shared instance (documented since .NET 6)")
package Std.RandomHost

extern type Random = "System.Random"

@externTarget("System.Random.Shared")
pub func hostSharedRandom(): Random = ()

@externTarget("System.Random..ctor")
pub func hostMakeRandom(seed: in Int): Random = ()

@externTarget("System.Random.Next")
pub func hostNextInt(rng: in Random): Int = ()

/// Random integer in `[0, max)`.  Negative `max` panics at the BCL boundary.
@externTarget("System.Random.Next")
pub func hostNextIntBelow(rng: in Random, max: in Int): Int = ()

/// Random integer in `[min, max)`.  `min >= max` panics at the BCL boundary.
@externTarget("System.Random.Next")
pub func hostNextIntRange(rng: in Random, min: in Int, max: in Int): Int = ()

@externTarget("System.Random.NextInt64")
pub func hostNextLong(rng: in Random): Long = ()

@externTarget("System.Random.NextDouble")
pub func hostNextDouble(rng: in Random): Double = ()
