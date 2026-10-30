//! A record method with type parameters of its own (#8241).
//!
//! The method's `U` is erased in its body; on a generic record the record's `T`
//! is reified beside it. A method that takes its `U` by value, returns it, or
//! builds a `List[U]` runs on every target, with `Long` and `String`
//! arguments. A method taking `U` by reference (`out`/`inout`) is T0214: see
//! `typechecker_self_test.l`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/method_generic_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/method_generic_self_test.l
//!   lyric test --target native lyric-compiler/lyric/method_generic_self_test.l
@test_module
package Lyric.MethodGenericSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Box[T] {
  v: T
  func wrap[U](self: in Box[T], x: in U): List[U] {
    val l: List[U] = newList()
    l.add(x)
    l
  }
  func pair[U](self: in Box[T], x: in U): (T, U) {
    (self.v, x)
  }
}

record Plain {
  v: Int
  func ident[U](self: in Plain, x: in U): U {
    x
  }
  func wrap[U](self: in Plain, x: in U): List[U] {
    val l: List[U] = newList()
    l.add(x)
    l
  }
}

test "a method-level generic on a generic record" {
  val b = Box(v = 5000000000)
  val w = b.wrap(7i64)
  assertEqual(toString(w[0]), "7", "Long")
  val w2 = b.wrap("q")
  assertEqual(w2[0], "q", "String")
  val (a, c) = b.pair("z")
  assertEqual(toString(a) + c, "5000000000z", "pair")
}

test "a method-level generic on a plain record" {
  val p = Plain(v = 1)
  assertEqual(toString(p.ident(5i64)), "5", "ident Long")
  assertEqual(p.ident("s"), "s", "ident String")
  assertEqual(toString(p.wrap(7i64)[0]), "7", "wrap Long")
  assertEqual(p.wrap("q")[0], "q", "wrap String")
}
