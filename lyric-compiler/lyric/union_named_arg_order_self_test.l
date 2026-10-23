//! union_named_arg_order_self_test.l — dual-target runtime regression test for
//! out-of-order named arguments to a union-case constructor (#7773).
//!
//! Named arguments were bound by position, not by name: a generic case
//! `GTwo(b = "g", a = 2)` inferred `GPair[String, Int]` and reported a false
//! T0043, and the non-generic `Three(z = true, x = 7, y = "q")` stored its
//! payload in call order, so the match read mismatched types
//! (`InvalidProgramException` on dotnet).  Asserts the stored values for fully
//! and partially reordered arguments over mixed payload types.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/union_named_arg_order_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/union_named_arg_order_self_test.l
@test_module
package Lyric.UnionNamedArgOrderSelfTest

import Std.Core
import Std.Testing

union GPair[A, B] {
  case GTwo(a: A, b: B)
  case GNone
}

union Mixed {
  case Three(x: Int, y: String, z: Bool)
}

test "generic case with fully reversed named arguments" {
  val g = GTwo(b = "g", a = 2)
  match g {
    case GTwo(a, b) -> {
      assertEqualInt(a, 2, "a")
      assertEqual(b, "g", "b")
    }
    case GNone -> assertTrue(false, "wrong case")
  }
}

test "non-generic case with fully reordered named arguments" {
  val m = Three(z = true, x = 7, y = "q")
  match m {
    case Three(x, y, z) -> {
      assertEqualInt(x, 7, "x")
      assertEqual(y, "q", "y")
      assertTrue(z, "z")
    }
  }
}

test "non-generic case with partially reordered named arguments" {
  val m = Three(y = "w", x = 8, z = false)
  match m {
    case Three(x, y, z) -> {
      assertEqualInt(x, 8, "x")
      assertEqual(y, "w", "y")
      assertFalse(z, "z")
    }
  }
}
