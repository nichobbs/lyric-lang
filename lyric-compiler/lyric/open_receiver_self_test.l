//! A method call whose receiver leaves a type argument open (#8038).
//!
//! `emptyCell()` is `Cell[T]` for a `T` nothing in the call fixes by itself;
//! `.orDefault(5)` fixes it through the method's own parameter. The checker
//! types the receiver from the method it resolved, as it does for a receiver
//! hoisted ahead of an `await`, and `Lyric.Mono` builds it at that type.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/open_receiver_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/open_receiver_self_test.l
//!   lyric test --target native lyric-compiler/lyric/open_receiver_self_test.l
@test_module
package Lyric.OpenReceiverSelfTest

import Std.Core
import Std.Testing

record Cell[T] {
  v: Option[T]
  func orDefault(self: in Cell[T], d: in T): T {
    match self.v {
      case Some(x) -> x
      case None -> d
    }
  }
  func present(self: in Cell[T]): Bool {
    isSome(self.v)
  }
}

func emptyCell[T](): Cell[T] {
  Cell(v = None)
}

func fullCell[T](x: in T): Cell[T] {
  Cell(v = Some(value = x))
}

test "an open receiver is fixed by the method's argument" {
  assertEqual(toString(emptyCell().orDefault(5)), "5", "Int")
  assertEqual(emptyCell().orDefault("d"), "d", "String")
}

test "a closed receiver is unchanged" {
  assertEqual(toString(fullCell(3).orDefault(5)), "3", "Int")
  assertTrue(fullCell("x").present(), "present")
}
