//! generic_member_calls_std_self_test.l -- a generic standard-library function
//! called from a generic record's method with a lambda typed by the record's
//! own type parameter (#8301).  Runs on dotnet, the JVM and native (#8448).
@test_module
package Lyric.GenericMemberCallsStdSelfTest

import Std.Core
import Std.Testing

record Holder[T] {
  value: T
  func viaOpt(self: in Holder[T]): Int {
    val o: Option[T] = Some(value = value)
    match mapOption(o, { v: T -> 3 }) {
      case Some(n) -> n
      case None -> 0
    }
  }
  func orElse(self: in Holder[T], d: in T): T {
    val o: Option[T] = Some(value = value)
    unwrapOr(o, d)
  }
}

test "a stdlib generic higher-order function called from a generic member (#8301)" {
  val h: Holder[Int] = Holder(value = 7)
  assertEqualInt(h.viaOpt(), 3, "mapOption with a T-typed lambda")
  assertEqualInt(h.orElse(1), 7, "unwrapOr at T")
  val hs: Holder[String] = Holder(value = "s")
  assertEqual(hs.orElse("d"), "s", "unwrapOr at String")
}
