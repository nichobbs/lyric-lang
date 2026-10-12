//! slice_func_unit_elem_self_test.l — runtime regression test for
//! `Unit`-returning function values in a slice or list (#8299).
//!
//! On `--target dotnet` a `(T1, ..., TN) -> Unit` type is a real
//! `System.Action`.  A lambda literal inside a slice or list literal of that
//! element type was built as a `Func<..., object>`, so a `List[(Int) -> Unit]`
//! literal failed in `List.Add` with `ArrayTypeMismatchException`, and a
//! slice's element was read as `object` and invoked as an `Action` that it was
//! not (ilverify: StackUnexpected).  The literal is now built as the `Action`,
//! and an indexed read or a `for` loop narrows the element to it.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/slice_func_unit_elem_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/slice_func_unit_elem_self_test.l
//!
//! `scripts/ilverify-selfhosted.sh` verifies the dotnet test DLL.  Not run on
//! `--target native`, whose codegen does not yet accept a `Unit`-returning
//! function type as a type argument (N0007) or a lambda that assigns a
//! captured `var`.
@test_module
package Lyric.SliceFuncUnitElemSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func unitCall(fs: in slice[(Int) -> Unit], x: in Int): Unit {
  val f = fs[0]
  f(x)
  fs[1](x)
}

func unitLoop(fs: in slice[(Int) -> Unit], x: in Int): Unit {
  for f in fs {
    f(x)
  }
}

func unitListCall(fs: in List[(Int) -> Unit], x: in Int): Unit {
  val f = fs[0]
  f(x)
}

test "Unit-returning function elements of a slice, indexed" {
  var total = 0
  val us: slice[(Int) -> Unit] = [{ a: Int -> total = total + a }, { a: Int -> total = total + a * 100 }]
  unitCall(us, 3)
  assertEqualInt(total, 303, "unitCall")
}

test "Unit-returning function elements of a slice, iterated" {
  var total = 0
  val named: (Int) -> Unit = { a: Int -> total = total + a * 10 }
  val us: slice[(Int) -> Unit] = [named, { a: Int -> total = total + a }]
  unitLoop(us, 2)
  assertEqualInt(total, 22, "unitLoop")
}

test "a Unit-returning lambda literal in a list literal" {
  var total = 0
  val ls: List[(Int) -> Unit] = [{ a: Int -> total = total + a + 1 }]
  unitListCall(ls, 4)
  assertEqualInt(total, 5, "unitListCall")
}
