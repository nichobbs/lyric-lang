//! generic_opaque_self_test.l - generic opaque types (#8187).
//!
//! On `--target dotnet` a generic, non-projectable `opaque type` lowers as a
//! reified generic class like a generic record (docs/43), with internal
//! fields, so a value-type payload (`Opq[Int]`) is stored unboxed and one
//! declaration serves every instantiation.  Runs on all targets in CI.
@test_module
package GenericOpaqueSelfTest

import Std.Core
import Std.Testing

pub opaque type Opq[T] {
  v: T
}

pub opaque type Pair[A, B] {
  first: A
  var second: B
}

pub func Opq.get[T](self: in Opq[T]): T = self.v

pub func mkInt(x: in Int): Opq[Int] = Opq(v = x)

pub func mkText(x: in String): Opq[String] = Opq(v = x)

pub func Pair.swapCount[A, B](self: in Pair[A, B], next: in B): Int {
  self.second = next
  1
}

pub func Pair.readSecond[A, B](self: in Pair[A, B]): B = self.second

test "a value-type payload is stored and read back" {
  assertEqualInt(mkInt(3).get(), 3, "Int payload")
}

test "a reference payload is stored and read back" {
  assertEqual(mkText("hi").get(), "hi", "String payload")
}

test "one declaration serves several instantiations" {
  val b: Opq[Bool] = Opq(v = true)
  assertTrue(b.get(), "Bool payload")
  assertEqualInt(mkInt(7).get(), 7, "Int payload again")
}

test "a mutable field of a two-parameter opaque type is updated" {
  val p: Pair[Int, String] = Pair(first = 1, second = "a")
  assertEqualInt(p.swapCount("b"), 1, "call ran")
  assertEqual(p.readSecond(), "b", "field updated")
}
