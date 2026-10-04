//! std/_kernel_native/secure_random_host.l - native twin of
//! `_kernel/secure_random_host.l`: a CSPRNG over the OS entropy source
//! (getrandom(2) on Linux, getentropy(3) on macOS and WASI) through lyric-rt.
//!
//! Safe for security-sensitive values (tokens, keys, nonces, session IDs).  A
//! failing entropy source ends the process: a "random" value from a broken
//! RNG is a correctness bug, not a recoverable condition.  Ranges are drawn by
//! rejection sampling over 32-bit values, so every value in a range is
//! equally likely.  Invalid arguments panic, as the .NET twin's
//! `ArgumentOutOfRangeException` does.
//!
//! Internal: only Std.SecureRandom should import this.
@axiom("lyric_secure_random_list (lyric-rt) draws from the OS entropy source and returns the requested number of cryptographically strong bytes")
@io
package Std.SecureRandomHost

import Std.Core

extern func rtSecureBytes(n: Long): slice[Byte] = "lyric_secure_random_list"

/// Fill a new byte slice of the given length with cryptographically strong
/// random bytes.  count must be >= 0.
pub func hostSecureGetBytes(count: in Int): slice[Byte] {
  if count < 0 {
    panic("hostSecureGetBytes: count must not be negative")
  }
  rtSecureBytes(count.toLong())
}

// A uniform value in [0, span) for 0 < span <= 2^32, by rejection sampling.
func uniformBelow(span: in Long): Long {
  val total = 4294967296i64
  val limit = total - total % span
  while true {
    val b = rtSecureBytes(4i64)
    val v = b[0].toInt().toLong() * 16777216i64 + b[1].toInt().toLong() * 65536i64 + b[2].toInt().toLong() * 256i64 +
      b[3].toInt().toLong()
    if v < limit {
      return v % span
    }
  }
  0i64
}

/// Cryptographically strong random integer in [0, max).  max must be positive.
pub func hostSecureNextInt(max: in Int): Int {
  if max <= 0 {
    panic("hostSecureNextInt: max must be positive")
  }
  uniformBelow(max.toLong()).toInt()
}

/// Cryptographically strong random integer in [min, max).  min must be < max.
pub func hostSecureNextIntRange(min: in Int, max: in Int): Int {
  if min >= max {
    panic("hostSecureNextIntRange: min must be less than max")
  }
  min + uniformBelow(max.toLong() - min.toLong()).toInt()
}
