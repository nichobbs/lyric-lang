//! std/_kernel_jvm/secure_random_host.l — JVM host boundary for
//! java.security.SecureRandom (CSPRNG).
//!
//! Mirrors _kernel/secure_random_host.l for the JVM target. Pure Lyric over
//! the JVM auto-FFI (`java.security.SecureRandom`) — no
//! `lyric.stdlib.jvm.SecureRandomHost` shim class (that class never existed
//! at runtime; every function here was a phantom `@externTarget` stub that
//! panicked with a bytecode verification error the moment it was actually
//! called — the same elimination already applied to `time_host.l` /
//! `collections_host.l` / `file_host.l` / `random_host.l`, D-progress-543).
//!
//! All methods route through a process-wide `SecureRandom` instance backed
//! by the OS-level cryptographic entropy source (`/dev/urandom` on Linux,
//! `BCryptGenRandom` on Windows, `SecRandomCopyBytes` on macOS via JDK).
//!
//! Internal: only Std.SecureRandom should import this.
@axiom("java.security.SecureRandom conforms to its documented JDK contracts and produces cryptographically strong output")
package Std.SecureRandomHost

import Std.Core
import Std.Collections

extern type JSecureRandom = "java.security.SecureRandom"

extern type JByteBuffer = "java.nio.ByteBuffer"

val sharedSecureRandom: JSecureRandom = JSecureRandom.new()

/// Cryptographically strong random integer in [0, max).
/// max must be positive; the JDK throws IllegalArgumentException otherwise.
pub func hostSecureNextInt(max: in Int): Int {
  sharedSecureRandom.nextInt(max)
}

/// Cryptographically strong random integer in [min, max), exactly uniform.
/// min must be strictly less than max.
///
/// `SecureRandom extends Random`, so it too implements
/// `java.util.random.RandomGenerator` (JDK 17+) and inherits its default
/// `nextInt(origin, bound)` — an unbiased rejection algorithm, not modulo
/// reduction — without overriding it (#7487). Security-sensitive draws
/// (tokens, OTP digits) need this exact uniformity: a modulo-reduced draw
/// is biased by roughly `range / 2^63`, and this also widens internally so
/// a wide range (`min` near `Int.MinValue`, `max` near `Int.MaxValue`)
/// cannot overflow the Int32 `max - min` subtraction the way
/// `min + nextInt(max - min)` used to (#7252).
pub func hostSecureNextIntRange(min: in Int, max: in Int): Int {
  sharedSecureRandom.nextInt(min, max)
}

// Fill the buffer's backing byte[] in place. Handing `nextBytes` the array
// straight from `array()` matters: a `slice[Byte]` local passed to a JDK
// `byte[]` parameter is coerced through a fresh copy, so `nextBytes` filled
// that temporary and the caller received all zeros (#7283). Tail position
// because a discarded auto-FFI call on a parameter receiver emits no invoke
// on this backend (#5379).
func fillRandom(buffer: in JByteBuffer): Unit {
  sharedSecureRandom.nextBytes(buffer.array())
}

/// Fill a new byte slice of the given length with cryptographically strong
/// random bytes.  count must be >= 0.
pub func hostSecureGetBytes(count: in Int): slice[Byte]
  requires: count >= 0
{
  val buffer: JByteBuffer = JByteBuffer.allocate(count)
  fillRandom(buffer)
  buffer.array()
}
