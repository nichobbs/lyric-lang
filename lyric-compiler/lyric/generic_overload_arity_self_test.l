//! Generic functions of one name that differ in parameter count (#8461).
//!
//! `Lyric.Mono` named a specialisation after the generic and its type
//! arguments alone, so `two[T](x)` and `two[T](x, y)` collapsed onto one
//! `two__String` and only one body survived. Each overload of a same-package
//! set is now resolved per call site (by argument count and types, and, between
//! declarations the call fits, the one that leaves the fewest parameters to
//! their defaults) and specialised under its own name.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generic_overload_arity_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/generic_overload_arity_self_test.l
//!   lyric test --target native lyric-compiler/lyric/generic_overload_arity_self_test.l
@test_module
package Lyric.GenericOverloadAritySelfTest

import Std.Core
import Std.Collections
import Std.Testing

func two[T](x: in T): Int {
  1
}

func two[T](x: in T, y: in T): Int {
  2
}

func echo[T](x: in T): T {
  x
}

func echo[T](x: in T, times: in Int): List[T] {
  val acc: List[T] = newList()
  var i = 0
  while i < times {
    acc.add(x)
    i = i + 1
  }
  acc
}

func gen[T](x: in T, y: in Int = 1, z: in Int = 2): Int {
  y + z
}

func gen[T](x: in T, y: in Int = 1): Int {
  y * 100
}

test "overloads of different arity each run their own body" {
  assertEqual(toString(two("a")), "1", "arity 1 at String")
  assertEqual(toString(two("a", "b")), "2", "arity 2 at String")
  assertEqual(toString(two(5)), "1", "arity 1 at Int")
  assertEqual(toString(two(5, 6)), "2", "arity 2 at Int")
}

test "overloads with different result types" {
  assertEqual(echo("k"), "k", "arity 1")
  val xs = echo("k", 3)
  assertEqual(toString(xs.count), "3", "arity 2")
  assertEqual(xs[2], "k", "arity 2 element")
}

test "overloads that differ in their defaults" {
  assertEqual(toString(gen("a")), "100", "the declaration that fills the fewest defaults")
  assertEqual(toString(gen("a", 3)), "300", "one argument given")
  assertEqual(toString(gen("a", 3, 4)), "7", "all arguments given")
}
