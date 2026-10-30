//! Calls under explicit type arguments (#8282).
//!
//! `f[T](args)` is checked against the signature the arguments instantiate
//! (the checker side is in `typechecker_self_test.l`), a package-qualified
//! callee works on every target (native could not resolve `Core.f[T](..)`),
//! and overloads of one generic name keep their own specialisation.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/explicit_type_args_checked_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/explicit_type_args_checked_self_test.l
//!   lyric test --target native lyric-compiler/lyric/explicit_type_args_checked_self_test.l
@test_module
package Lyric.ExplicitTypeArgsCheckedSelfTest

import Std.Core as Core
import Std.Collections
import Std.Testing

func firstOf[T](xs: in List[T], k: in Int): T {
  xs[k]
}

func f[T](x: in T, y: in T): T {
  x
}

func f[T](x: in T, y: in T, z: in T): T {
  z
}

test "an explicit type argument instantiates the call" {
  val xs: List[Int] = newList()
  xs.add(7)
  xs.add(8)
  assertEqualInt(firstOf[Int](xs, 1), 8, "Int")
  val ss: List[String] = newList()
  ss.add("a")
  assertEqual(firstOf[String](ss, 0), "a", "String")
}

test "overloads of one name keep their own specialisation under explicit type arguments" {
  assertEqualInt(f[Int](1, 2), 1, "two arguments")
  assertEqualInt(f[Int](1, 2, 3), 3, "three arguments")
}

test "a package-qualified callee takes explicit type arguments" {
  val o: Option[Int] = None
  assertEqualInt(Core.unwrapOr[Int](o, 5), 5, "qualified")
}
