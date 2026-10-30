//! A stdlib generic called from a generic member (#8301).
//!
//! `mapOption(o, { v: T -> 3 })` inside a method of `Box[T]` names the record's
//! own `T` in the lambda and calls a generic of `Std.Core`. On `--target native`
//! the body of a generic record or impl method is lowered per instantiation, and
//! the reachability pass that decides which stdlib functions to link never
//! walked it, so `mapOption` and `isSome` were unresolved (N0007).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generic_member_stdlib_native_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/generic_member_stdlib_native_self_test.l
//!   lyric test --target native lyric-compiler/lyric/generic_member_stdlib_native_self_test.l
@test_module
package Lyric.GenericMemberStdlibNativeSelfTest

import Std.Core
import Std.Testing

record Box[T] {
  value: T
  func viaOpt(self: in Box[T]): Int {
    val o: Option[T] = Some(value = self.value)
    match mapOption(o, { v: T -> 3 }) {
      case Some(n) -> n
      case None -> 0
    }
  }
  func has(self: in Box[T]): Bool {
    val o: Option[T] = Some(value = self.value)
    isSome(o)
  }
}

test "a lambda typed by the record's T passed to a stdlib generic" {
  val b: Box[Int] = Box(value = 7)
  assertEqual(toString(b.viaOpt()), "3", "Int")
  val s: Box[String] = Box(value = "x")
  assertEqual(toString(s.viaOpt()), "3", "String")
}

test "a stdlib predicate called from a generic record method" {
  val b: Box[Int] = Box(value = 7)
  assertTrue(b.has(), "has")
}
