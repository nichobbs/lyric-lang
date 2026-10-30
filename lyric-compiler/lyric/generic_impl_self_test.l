//! generic_impl_self_test.l -- `impl[T] I for R[T]` methods called directly on
//! an instance and through the interface, on every target (#8300).  Native
//! registers the impl's methods as generic functions of the record and emits
//! one vtable per instantiation on first upcast.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generic_impl_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/generic_impl_self_test.l
//!   lyric test --target native lyric-compiler/lyric/generic_impl_self_test.l
@test_module
package Lyric.GenericImplSelfTest

import Std.Testing

interface Shows {
  func first(): Int
  func plus(n: in Int): Int
}

record Pair[T] {
  a: Int
  b: T
}

impl[T] Shows for Pair[T] {
  func first(): Int {
    self.a * 2
  }
  func plus(n: in Int): Int {
    self.a + n
  }
}

record Box[T] {
  v: T
}

interface Named {
  func label(): String
}

impl[T] Named for Box[T] {
  func label(): String {
    "box"
  }
}

func viaIface(s: in Shows): Int {
  s.first() + s.plus(1)
}

test "a direct call on an impl[T] method specialises per instance" {
  val p: Pair[Int] = Pair(a = 4, b = 9)
  assertEqualInt(p.first(), 8, "Pair[Int].first")
  assertEqualInt(p.plus(3), 7, "Pair[Int].plus")
  val q: Pair[String] = Pair(a = 5, b = "s")
  assertEqualInt(q.first(), 10, "Pair[String].first")
}

test "a generic impl dispatches through the interface for each instantiation" {
  val p: Pair[Int] = Pair(a = 4, b = 9)
  val q: Pair[String] = Pair(a = 5, b = "s")
  assertEqualInt(viaIface(p), 8 + 5, "Pair[Int] as Shows")
  assertEqualInt(viaIface(q), 10 + 6, "Pair[String] as Shows")
  val s: Shows = q
  assertEqualInt(s.plus(10), 15, "bound interface value")
}

test "two interfaces implemented for the same generic record" {
  val b: Box[Int] = Box(v = 1)
  val n: Named = b
  assertEqual(n.label(), "box", "Named")
  assertEqual(b.label(), "box", "direct")
}
