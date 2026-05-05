// std/random.l - Pseudorandom number generation.
//
// Wraps the BCL's `System.Random` shared instance plus a thin
// constructor for seeded instances.  Lyric users see ordinary
// `randomInt` / `randomDouble` helpers; the BCL handles state.

@runtime_checked
package Std.Random

extern type Random = "System.Random"

// =====================================================================
// Construction.
// =====================================================================

@externTarget("System.Random.Shared")
pub func sharedRandom(): Random = ()

@externTarget("Lyric.Stdlib.RandomHost.Make")
pub func makeRandom(seed: in Int): Random = ()

// =====================================================================
// Random integers.
// =====================================================================

@externTarget("System.Random.Next")
pub func nextInt(rng: in Random): Int = ()

/// Random integer in `[0, max)`.  Negative `max` panics at the BCL
/// boundary.
@externTarget("System.Random.Next")
pub func nextIntBelow(rng: in Random, max: in Int): Int = ()

/// Random integer in `[min, max)`.  `min >= max` panics at the BCL
/// boundary.
@externTarget("System.Random.Next")
pub func nextIntRange(rng: in Random, min: in Int, max: in Int): Int = ()

@externTarget("System.Random.NextInt64")
pub func nextLong(rng: in Random): Long = ()

// =====================================================================
// Random doubles in [0, 1).
// =====================================================================

@externTarget("System.Random.NextDouble")
pub func nextDouble(rng: in Random): Double = ()

// =====================================================================
// Random booleans.
// =====================================================================

@externTarget("Lyric.Stdlib.RandomHost.NextBool")
pub func nextBool(rng: in Random): Bool = ()
