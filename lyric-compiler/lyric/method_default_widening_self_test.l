//! A method default that widens zero-extends (#7820): `x: in ULong = someUInt`
//! takes the `UInt` value without sign extension.
//!
//! Runs on dotnet and the JVM; `UInt`/`ULong` on native is #7891, after which
//! this file joins the native lane with `method_default_args_self_test.l`.
@test_module
package MethodDefaultWideningSelfTest

import Std.Core
import Std.Testing

val bigU: UInt = 4000000000u32

record Acc {
  n: Int

  func wide(self: in Acc, x: in ULong = bigU): ULong {
    x
  }
}

test "record method: a widening default zero-extends" {
  val w = Acc(n = 0).wide()
  assertTrue(w == 4000000000u64, "ULong default from a UInt module value: " + toString(w))
}
