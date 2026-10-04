//! Std.SecureRandom on `--target native`: lengths, ranges, and that the bytes
//! are not constant.
//!
//!   lyric test --target native lyric-stdlib/tests/secure_random_native_tests.l
@test_module
package Std.SecureRandom.NativeTests

import Std.Core
import Std.Collections
import Std.SecureRandom
import Std.Testing

test "secureGetBytes returns the requested number of bytes" {
  assertEqualInt(secureGetBytes(0).length, 0, "zero bytes")
  assertEqualInt(secureGetBytes(32).length, 32, "32 bytes")
}

test "two draws of 32 bytes differ" {
  val a = secureGetBytes(32)
  val b = secureGetBytes(32)
  var same = true
  var i = 0
  while i < 32 {
    if a[i] != b[i] {
      same = false
    }
    i = i + 1
  }
  assertFalse(same, "32 random bytes do not repeat")
}

test "secureNextInt stays below its bound" {
  var i = 0
  var ok = true
  while i < 500 {
    val v = secureNextInt(7)
    if v < 0 or v >= 7 {
      ok = false
    }
    i = i + 1
  }
  assertTrue(ok, "every draw is in [0, 7)")
  assertEqualInt(secureNextInt(1), 0, "a bound of 1 always gives 0")
}

test "secureNextIntRange stays within its range and reaches both ends" {
  var i = 0
  var ok = true
  var sawLow = false
  var sawHigh = false
  while i < 2000 {
    val v = secureNextIntRange(-3, 3)
    if v < -3 or v >= 3 {
      ok = false
    }
    if v == -3 {
      sawLow = true
    }
    if v == 2 {
      sawHigh = true
    }
    i = i + 1
  }
  assertTrue(ok, "every draw is in [-3, 3)")
  assertTrue(sawLow and sawHigh, "both ends of the range occur")
}
