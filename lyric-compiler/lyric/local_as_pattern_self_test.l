//! local_as_pattern_self_test.l — dual-target runtime regression test for a
//! local `val` whose pattern is an `@` binding over a tuple (#7803).
//!
//! `val whole @ (a, b) = pair` bound neither name: the backends' local-binding
//! lowering matched `PBinding(name, _)` and dropped the inner pattern, so the
//! synthesised `__lyric_tp_<n>` names from the tuple-pattern desugar were never
//! bound (T0115 on dotnet, J008 on JVM).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/local_as_pattern_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/local_as_pattern_self_test.l
@test_module
package Lyric.LocalAsPatternSelfTest

import Std.Core
import Std.Testing

func sumPair(t: in (Int, Int)): Int {
  match t {
    case (x, y) -> x + y
  }
}

func secondOf(t: in (String, Int)): Int {
  match t {
    case (_, n) -> n
  }
}

test "val whole @ (a, b) binds the whole value and the elements" {
  val pair = (3, 4)
  val whole @ (a, b) = pair
  assertEqualInt(a, 3, "first element")
  assertEqualInt(b, 4, "second element")
  assertEqualInt(sumPair(whole), 7, "whole tuple")
}

test "nested @ binding inside a tuple pattern" {
  val nested = ((1, 2), 10)
  val (inner @ (p, q), r) = nested
  assertEqualInt(p + q + r, 13, "elements")
  assertEqualInt(sumPair(inner), 3, "inner tuple")
}

test "@ binding of a String-carrying tuple" {
  val pair = ("x", 5)
  val whole @ (s, n) = pair
  assertEqual(s, "x", "string element")
  assertEqualInt(n, 5, "int element")
  assertEqualInt(secondOf(whole), 5, "whole tuple")
}
