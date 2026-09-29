//! impl_generic_target_self_test.l — dual-target runtime regression test for
//! an `impl` block whose target is a generic record (`impl[T] I for Box[T]`,
//! #7704).
//!
//! Before #7704 no such impl compiled: the type checker resolved the impl's
//! target and its methods' signatures without the impl's own type parameters
//! in scope (T0010 "unknown type name 'T'"), the jvm backend refused the
//! generic target shape outright (J008), and the dotnet backend named the
//! target `<pkg>.__impl_target`.  Past those, both backends lowered the impl
//! methods with an empty type-parameter list, so none of the handling a
//! method declared inside `record Box[T]` gets applied: on dotnet, `T` in the
//! signature and in body annotations must be the class's `!0` and `self` the
//! open instantiation `Box`1<!0>` (`FuncCtx.reifiedGenerics`, #7695); on jvm,
//! `T` must erase to `Object` in the descriptor and in body annotations
//! (`FuncCtx.typeParams`).  An impl for a single instantiation
//! (`impl I for Box[Int]`) is rejected as T0145.
//!
//! The `Counted` impl's body declares `T`-typed locals (`List[T]`, `val y: T`)
//! and reads the `T` field both bare and through `self`; it is instantiated with
//! `Int`, `String` and a record and called on the concrete receiver and through
//! an interface-typed binding.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/impl_generic_target_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/impl_generic_target_self_test.l
//!
//! The dotnet DLL is also verified by `scripts/ilverify-selfhosted.sh`.
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ImplGenericTargetSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Pair {
  a: Int
  b: String
}

interface Counted {
  func countWith(extra: in Int): Int
}

record Box[T] {
  value: T
}

impl[T] Counted for Box[T] {
  func countWith(extra: in Int): Int {
    val xs: List[T] = newList()
    xs.add(self.value)
    var i = 0
    while i < extra {
      val y: T = value
      xs.add(y)
      i = i + 1
    }
    xs.count
  }
}

test "Box[Int]: T-typed locals and fields in an impl method" {
  assertEqualInt(Box(value = 41).countWith(2), 3, "countWith(2)")
}

test "Box[String]: T-typed locals and fields in an impl method" {
  assertEqualInt(Box(value = "mine").countWith(0), 1, "countWith(0)")
}

test "Box[Pair]: T-typed locals and fields in an impl method" {
  assertEqualInt(Box(value = Pair(a = 1, b = "one")).countWith(3), 4, "countWith(3)")
}

test "Box[T] impl dispatched through interface-typed bindings" {
  val c1: Counted = Box(value = 5)
  assertEqualInt(c1.countWith(1), 2, "Counted Box[Int]")
  val c2: Counted = Box(value = "s")
  assertEqualInt(c2.countWith(2), 3, "Counted Box[String]")
  val c3: Counted = Box(value = Pair(a = 3, b = "three"))
  assertEqualInt(c3.countWith(0), 1, "Counted Box[Pair]")
}
