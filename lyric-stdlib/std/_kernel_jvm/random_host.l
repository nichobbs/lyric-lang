//! std/_kernel_jvm/random_host.l — JVM host boundary for java.util.Random (PRNG).
//!
//! Mirrors _kernel/random_host.l for the JVM target.
//! Internal: only Std.Random should import this.
//!
//! Package name MUST match the .NET kernel (`Std.RandomHost`) because
//! the consumer in `std/random.l` does `import Std.RandomHost` regardless
//! of target.  A previous version of this file declared
//! `package Std.Random` directly, colliding with the consumer package and
//! leaving every `Std.Random.*` call on `--target jvm` unresolved.
//!
//! nextIntRange routes through a JVM shim because java.util.Random
//! only exposes `nextInt(bound)` (i.e. [0, bound)); [min, max) is
//! synthesised as `min + nextInt(max - min)`.
@axiom("java.util.Random conforms to its documented JDK contracts; lyric.stdlib.jvm.RandomHost wraps a process-wide instance")
package Std.RandomHost

extern type Random = "java.util.Random"

// Returns a shared Random instance (process-wide singleton).
@externTarget("lyric.stdlib.jvm.RandomHost.shared")
pub func hostSharedRandom(): Random = ()

// java.util.Random(long seed) constructor.
@externTarget("lyric.stdlib.jvm.RandomHost.make")
pub func hostMakeRandom(seed: in Int): Random = ()

// java.util.Random.nextInt() — unbounded.
@externTarget("java.util.Random.nextInt")
pub func hostNextInt(rng: in Random): Int = ()

// java.util.Random.nextInt(int bound) — [0, max).
// Negative bound throws IllegalArgumentException at the JVM boundary.
@externTarget("java.util.Random.nextInt")
pub func hostNextIntBelow(rng: in Random, max: in Int): Int = ()

// Shim: min + rng.nextInt(max - min).  min >= max panics in the shim.
@externTarget("lyric.stdlib.jvm.RandomHost.nextIntRange")
pub func hostNextIntRange(rng: in Random, min: in Int, max: in Int): Int = ()

// java.util.Random.nextLong() — unbounded.
@externTarget("java.util.Random.nextLong")
pub func hostNextLong(rng: in Random): Long = ()

// java.util.Random.nextDouble() — [0, 1).
@externTarget("java.util.Random.nextDouble")
pub func hostNextDouble(rng: in Random): Double = ()
