//! curried_generic_union_jvm_self_test.l — `--target jvm` runtime regression
//! test (#8351): `+` on two results of a curried call whose parameter is a
//! generic union.  The chained call's `String` result type used to be lost
//! when the outer function's parameter was a generic union, so the `+`
//! lowering saw two erased operands (J008).
//!
//!   lyric test --target jvm lyric-compiler/jvm/curried_generic_union_jvm_self_test.l
@test_module
package Lyric.CurriedGenericUnionJvmSelfTest

import Std.Core
import Std.Testing

union Either[A, B] {
  case Left(a: A)
  case Right(b: B)
}

test "curried call over a generic union parameter" {
  val f: (Either[Int, String]) -> () -> String = { e: Either[Int, String] ->
    { -> match e { case Left(a) -> toString(a); case Right(b) -> b } }
  }
  assertEqual(f(Left(a = 1))() + f(Right(b = "x"))(), "1x", "chained")
}
