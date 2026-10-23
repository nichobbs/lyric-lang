//! record_method_option_param_self_test.l — dual-target runtime regression test
//! for an `Option[T]` parameter of a record method (#8273).
//!
//! On dotnet a bare `None` (or a `None` bound to an `Option[Int]` local)
//! passed to a record method's `Option[Int]` parameter was built as the erased
//! `Option_None<object>` instead of the closed `Option_None<int32>` the
//! method's `match` tests for, so no arm matched and the call panicked with
//! "match not exhaustive".  A free function with the same body worked.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/record_method_option_param_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/record_method_option_param_self_test.l
@test_module
package Lyric.RecordMethodOptionParamSelfTest

import Std.Core
import Std.Testing

record Acc {
  var total: Int

  func addInt(self: in Acc, o: in Option[Int]): Int {
    match o {
      case Some(v) -> v
      case None -> -1
    }
  }

  func addStr(self: in Acc, o: in Option[String]): String {
    match o {
      case Some(v) -> v
      case None -> "none"
    }
  }
}

test "Some and bare None reach an Option[Int] record-method parameter" {
  val a = Acc(total = 0)
  assertEqualInt(a.addInt(Some(value = 5)), 5, "Some")
  assertEqualInt(a.addInt(None), -1, "bare None")
}

test "an Option[Int] local bound to None reaches the parameter" {
  val a = Acc(total = 0)
  val o: Option[Int] = None
  assertEqualInt(a.addInt(o), -1, "None local")
}

test "Option[String] record-method parameter" {
  val a = Acc(total = 0)
  assertEqual(a.addStr(Some(value = "x")), "x", "Some")
  assertEqual(a.addStr(None), "none", "bare None")
}
