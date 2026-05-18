// std/_kernel_jvm/random.l - JVM host boundary for java.util.Random.
//
// Mirrors _kernel/random.l for the JVM target.
//
// sharedRandom routes through a shim that returns a process-wide
// java.util.Random instance (ThreadLocalRandom is preferred for
// throughput but exposes a different API; the shim picks the right
// implementation).
//
// nextIntRange requires a shim because java.util.Random.nextInt(bound)
// only supports [0, bound); [min, max) is synthesised as
// min + nextInt(max - min).
//
// nextBool routes directly to java.util.Random.nextBoolean (unlike
// .NET which needed a Lyric.Stdlib shim).
@runtime_checked
package Std.Random

extern type Random = "java.util.Random"

// =====================================================================
// Construction.
// =====================================================================

// Returns a shared Random instance (process-wide singleton).
@externTarget("lyric.stdlib.jvm.RandomHost.shared")
pub func sharedRandom(): Random = ()

// java.util.Random(long seed) constructor.
@externTarget("lyric.stdlib.jvm.RandomHost.make")
pub func makeRandom(seed: in Int): Random = ()

// =====================================================================
// Random integers.
// =====================================================================

// java.util.Random.nextInt() — unbounded.
@externTarget("java.util.Random.nextInt")
pub func nextInt(rng: in Random): Int = ()

// java.util.Random.nextInt(int bound) — [0, max).
// Negative bound throws IllegalArgumentException at the JVM boundary.
@externTarget("java.util.Random.nextInt")
pub func nextIntBelow(rng: in Random, max: in Int): Int = ()

// Shim: min + rng.nextInt(max - min).  min >= max panics in the shim.
@externTarget("lyric.stdlib.jvm.RandomHost.nextIntRange")
pub func nextIntRange(rng: in Random, min: in Int, max: in Int): Int = ()

// java.util.Random.nextLong() — unbounded.
@externTarget("java.util.Random.nextLong")
pub func nextLong(rng: in Random): Long = ()

// =====================================================================
// Random doubles in [0, 1).
// =====================================================================

// java.util.Random.nextDouble().
@externTarget("java.util.Random.nextDouble")
pub func nextDouble(rng: in Random): Double = ()

// =====================================================================
// Random booleans.
// =====================================================================

// java.util.Random.nextBoolean() — direct binding (no shim needed).
@externTarget("java.util.Random.nextBoolean")
pub func nextBool(rng: in Random): Bool = ()
