//! Explicit type arguments on a call to a generic function
//! (`identity[Int](4)`), including a type parameter that appears only in the
//! return type.  Runs on every target; the native backend binds the
//! arguments in declaration order before consulting the call's arguments.
//!
//!   lyric test --target native lyric-compiler/lyric/explicit_type_args_self_test.l
@test_module
package Lyric.ExplicitTypeArgsSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func identity[T](x: in T): T = x

func empty[T](): List[T] {
  val l: List[T] = newList()
  l
}

func pair[A, B](a: in A, b: in B): A = a

func apply[T](x: in T, f: in (T) -> T): T = f(x)

test "explicit type arguments bind a parameter the arguments also determine" {
  assertEqualInt(identity[Int](4), 4, "identity[Int]")
  assertEqual(identity[String]("s"), "s", "identity[String]")
}

test "explicit type arguments bind a parameter only the return type mentions" {
  val l = empty[String]()
  assertEqualInt(l.count, 0, "empty[String]() is an empty list")
  l.add("x")
  assertEqualInt(l.count, 1, "and holds Strings")
}

test "explicit type arguments bind in declaration order" {
  assertEqualInt(pair[Int, String](7, "z"), 7, "pair[Int, String]")
}

test "an explicit type argument types a lambda argument" {
  val r = apply[Int](2, { v: Int -> v * 10 })
  assertEqualInt(r, 20, "apply[Int] with a lambda")
}

func lazyOf[T](x: in T): () -> T {
  return { -> val inner: T = x; inner }
}

func wrapList[T](x: in T): () -> List[T] {
  return { -> val items: List[T] = newList(); items.add(x); items }
}

test "a lambda in a generic function names the function's type parameters" {
  val f = lazyOf[Int](9)
  assertEqualInt(f(), 9, "val inner: T inside the lambda")
  val g = wrapList[String]("a")
  assertEqualInt(g().count, 1, "List[T] inside the lambda")
}
