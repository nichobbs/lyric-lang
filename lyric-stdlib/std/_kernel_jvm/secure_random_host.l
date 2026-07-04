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

val sharedSecureRandom: JSecureRandom = JSecureRandom.new()

/// Cryptographically strong random integer in [0, max).
/// max must be positive; the JDK throws IllegalArgumentException otherwise.
pub func hostSecureNextInt(max: in Int): Int {
  sharedSecureRandom.nextInt(max)
}

/// Cryptographically strong random integer in [min, max).
/// min must be strictly less than max (a non-positive `max - min` throws
/// IllegalArgumentException from the JDK call itself).
pub func hostSecureNextIntRange(min: in Int, max: in Int): Int {
  min + sharedSecureRandom.nextInt(max - min)
}

/// Fill a new byte slice of the given length with cryptographically strong
/// random bytes.  count must be >= 0.
pub func hostSecureGetBytes(count: in Int): slice[Byte]
  requires: count >= 0
{
  val zeros: List[Byte] = newListWithCapacity(count)
  var i = 0
  while i < count {
    zeros.add(0)
    i = i + 1
  }
  val arr = zeros.toArray()
  sharedSecureRandom.nextBytes(arr)
  arr
}
