//! secure_random_self_test.l — `Std.SecureRandom` on dotnet and the JVM.
//!
//! The JVM kernel's `hostSecureGetBytes` now fills a `byte[]` allocated with
//! `ByteBuffer.allocate(n).array()` instead of boxing `n` zeros through an
//! `ArrayList` (#7283); these cases pin the observable contract.
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
