//! secure_random_self_test.l — `Std.SecureRandom` on dotnet and the JVM.
//!
//! The JVM kernel's `hostSecureGetBytes` now fills a `byte[]` allocated with
//! `ByteBuffer.allocate(n).array()` instead of boxing `n` zeros through an
//! `ArrayList` (#7283); these cases pin the observable contract.
//!
//! #7487: `secureNextIntRange` on the JVM used to reduce a 63-bit draw with
//! `%`, which is biased by roughly `range / 2^63` — negligible in magnitude,
//! but a real weakness for the security-sensitive draws (tokens, OTP
//! digits) `Std.SecureRandom` documents exact uniformity for. The kernel now
//! delegates to `RandomGenerator.nextInt(origin, bound)`'s unbiased
//! rejection algorithm on the JVM (`RandomNumberGenerator.GetInt32` was
//! already unbiased on dotnet). The full-domain, single-value-range, and
//! invalid-range cases below are deterministic boundary/contract checks,
//! not a statistical uniformity test — a chi-square test would need a large
//! sample to keep its false-failure probability low and could still flake
//! occasionally, while a modulo-biased draw is still always in bounds, so
//! bounds checks alone are what a broken reduction would actually violate
//! (an out-of-range or panic-free-on-an-invalid-range result).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/secure_random_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/secure_random_self_test.l
@test_module
package Lyric.SecureRandomSelfTest

import Std.Core
import Std.SecureRandom
import Std.Testing

test "secureGetBytes returns the requested number of bytes" {
  assertEqualInt(secureGetBytes(0).length, 0, "zero")
  assertEqualInt(secureGetBytes(1).length, 1, "one")
  assertEqualInt(secureGetBytes(4096).length, 4096, "4096")
}

test "secureGetBytes fills the buffer" {
  // 64 zero bytes from a CSPRNG has probability 2^-512.
  val bytes = secureGetBytes(64)
  var nonZero = 0
  for b in bytes {
    if b != 0u8 {
      nonZero = nonZero + 1
    }
  }
  assertTrue(nonZero > 0, "not all zero")
}

test "secureNextInt and secureNextIntRange stay in range" {
  var i = 0
  var ok = true
  while i < 200 {
    val a = secureNextInt(10)
    val b = secureNextIntRange(-5, 5)
    if a < 0 or a >= 10 or b < -5 or b >= 5 {
      ok = false
    }
    i = i + 1
  }
  assertTrue(ok, "all draws in range")
}

test "secureNextIntRange stays in bounds over the full Int domain" {
  var i = 0
  var ok = true
  while i < 200 {
    val v = secureNextIntRange(-2147483648, 2147483647)
    if v < -2147483648 or v >= 2147483647 {
      ok = false
    }
    i = i + 1
  }
  assertTrue(ok, "all draws stay within [Int.MinValue, Int.MaxValue)")
}

test "secureNextIntRange on a single-value range always returns that value" {
  var i = 0
  var ok = true
  while i < 20 {
    if secureNextIntRange(5, 6) != 5 {
      ok = false
    }
    i = i + 1
  }
  assertTrue(ok, "secureNextIntRange(5, 6) always returns 5")
}

test "secureNextIntRange panics on an invalid range" {
  assertPanics("secureNextIntRange(5, 5) panics on an empty range", { -> val ignored = secureNextIntRange(5, 5) })
  assertPanics("secureNextIntRange(5, 3) panics on an inverted range", { -> val ignored = secureNextIntRange(5, 3) })
}
