//! generic_protected_calls_self_test.l -- generic function calls made from the
//! members of a generic protected type (#8271).
//!
//! `Lyric.Mono` skipped generic protected types altogether, so a generic call
//! in an entry or function dangled.  A call at the type's own parameter is
//! specialised into a function of the type.  Runs on dotnet and the JVM;
//! `--target native` defers generic protected types (D-N-017).
@test_module
package Lyric.GenericProtectedCallsSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func ident[A](x: in A): A = x

func pair[A](x: in A): List[A] {
  val l: List[A] = newList()
  l.add(ident(x))
  l.add(x)
  l
}

protected type Cell[T] {
  var value: T
  entry set(v: in T): Unit {
    value = ident(v)
  }
  func get(): T {
    ident(value)
  }
  func both(): List[T] {
    pair(value)
  }
}

test "a generic protected entry and function call a generic function at T" {
  val c: Cell[Int] = Cell(value = 1)
  c.set(5)
  assertEqualInt(c.get(), 5, "Cell[Int]")
  assertEqualInt(c.both().count, 2, "a nested generic call in the specialised function")
  val s: Cell[String] = Cell(value = "a")
  s.set("b")
  assertEqual(s.get(), "b", "Cell[String]")
}
