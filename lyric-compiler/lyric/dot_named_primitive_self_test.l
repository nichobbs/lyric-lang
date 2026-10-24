//! dot_named_primitive_self_test.l — runtime regression test for method calls
//! on a dot-named function of a primitive type (`func Int.twice(self: in
//! Int)` called as `k.twice()`, #8217), on every target.
//!
//! A method call on a primitive receiver resolves among the dot-named
//! functions declared for that primitive exactly as one on a user type does
//! (docs/01 §5.1), and lowers to the same call as the type-qualified form
//! `Int.twice(k)`: the middle end rewrites it into a plain call of the
//! function, the receiver first (`Lyric.Pipeline`'s `byref_receivers.l`).
//! Before, the type checker accepted the call and every backend failed it:
//! dotnet at codegen or run time, the JVM and native at codegen.  This file
//! covers `in` and `inout` receivers of several primitives, a receiver that is
//! a literal, a call result or a field, chained calls, named arguments in and
//! out of order (evaluated in source order, D171), a generic function, a
//! function declared through an alias, a distinct type's, and built-in methods (`toString`, `shl`, `toInt`, `trim`), which keep their
//! meaning in method syntax beside a dot-named function of the same name.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/dot_named_primitive_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/dot_named_primitive_self_test.l
//!   lyric test --target native lyric-compiler/lyric/dot_named_primitive_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.DotNamedPrimitiveSelfTest

import Std.Core
import Std.Collections
import Std.Testing

val trace: List[String] = newList()

func note(s: in String, v: in Int): Int {
  trace.add(s)
  v
}

// The evaluations logged since `start`, comma-separated.
func since(start: in Int): String {
  var acc = ""
  var i = start
  while i < trace.count {
    acc = if acc.length == 0 { trace[i] } else { acc + "," + trace[i] }
    i = i + 1
  }
  acc
}

func Int.twice(self: in Int): Int = self * 2

func Int.inc(self: inout Int): Unit {
  self = self + 1
}

func Int.addTo(self: in Int, target: inout Int): Unit {
  target = target + self
}

func Int.between(self: in Int, lo: in Int, hi: in Int): Int = if self < lo { lo } else if self > hi { hi } else { self }

func Int.scaled(self: in Int, by: in Int = 10): Int = self * by

func Int.repeated[T](self: in Int, x: in T): List[T] {
  val l: List[T] = newList()
  var i = 0
  while i < self {
    l.add(x)
    i = i + 1
  }
  l
}

func Long.half(self: in Long): Long = self / 2i64

func Double.squared(self: in Double): Double = self * self

func Bool.flipped(self: in Bool): Bool = not self

func Char.isVowel(self: in Char): Bool = self == 'a' or self == 'e' or self == 'i' or self == 'o' or self == 'u'

func String.shout(self: in String): String = self + "!"

func String.wrapped(self: inout String, left: in String, right: in String): Unit {
  self = left + self + right
}

// Same-named as built-in methods, which keep their meaning in method syntax.
func Int.shl(self: in Int, n: in Int): Int = -1

func Int.toString(self: in Int): String = "dot-named"

func Long.toInt(self: in Long): Int = -2

func String.trim(self: in String): String = "dot-named"

// Declared through an alias: the function of the aliased type, `Int.neg`.
alias Num = Int

func Num.neg(self: in Num): Num = 0 - self

// A distinct type has its own dot-named functions, and reaches the
// underlying type's through `.value`.
type Age = Int

func Age.older(self: in Age): Age = Age.from(self.value + 1)

ref record Counter {
  var n: Int
}

func three(): Int {
  trace.add("three")
  3
}

test "an in receiver of each primitive" {
  val k = 3
  assertEqualInt(k.twice(), 6, "Int")
  val l = 9000000000i64
  assertEqualLong(l.half(), 4500000000i64, "Long")
  val d = 1.5
  assertTrue(d.squared() == 2.25, "Double")
  val b = true
  assertFalse(b.flipped(), "Bool")
  val c = 'e'
  assertTrue(c.isVowel(), "Char")
  val s = "hi"
  assertEqual(s.shout(), "hi!", "String")
}

test "a literal, a call result and a chain as the receiver" {
  assertEqualInt((4).twice(), 8, "literal")
  assertEqual("ok".shout(), "ok!", "string literal")
  val t0 = trace.count
  assertEqualInt(three().twice(), 6, "call result")
  assertEqual(since(t0), "three", "the receiver runs once")
  assertEqualInt((1).twice().twice().twice(), 8, "chain")
  assertEqual("a".shout().shout(), "a!!", "string chain")
}

test "the method's value in expression position" {
  val k = 5
  val sum = k.twice() + (2).twice()
  assertEqualInt(sum, 14, "operands")
  val chosen = if k.twice() > 9 { "big" } else { "small" }
  assertEqual(chosen, "big", "condition")
  val xs: List[Int] = newList()
  xs.add(k.twice())
  assertEqualInt(xs[0], 10, "argument")
}

test "an inout receiver writes the caller's place" {
  var m = 5
  m.inc()
  m.inc()
  assertEqualInt(m, 7, "a local")
  val c = Counter(n = 1)
  c.n.inc()
  assertEqualInt(c.n, 2, "a field")
  var s = "x"
  s.wrapped("[", "]")
  assertEqual(s, "[x]", "a String local")
}

test "an inout argument of a method on an in receiver" {
  var total = 10
  val k = 4
  k.addTo(total);
  (6).addTo(total)
  assertEqualInt(total, 20, "written through the argument")
}

test "named arguments in and out of order, and a default" {
  val k = 12
  assertEqualInt(k.between(1, 5), 5, "positional")
  assertEqualInt(k.between(hi = 20, lo = 15), 15, "named out of order")
  val t0 = trace.count
  assertEqualInt(k.between(hi = note("hi", 9), lo = note("lo", 2)), 9, "named with effects")
  assertEqual(since(t0), "hi,lo", "source order")
  assertEqualInt(k.scaled(), 120, "a default")
  assertEqualInt(k.scaled(by = 2), 24, "a named default")
}

test "a generic dot-named function of a primitive" {
  val k = 3
  val xs = k.repeated("ab")
  assertEqualInt(xs.count, 3, "count")
  assertEqual(xs[2], "ab", "a String element")
  val ys = (2).repeated(7000000000i64)
  assertEqualLong(ys[1], 7000000000i64, "a Long element")
}

test "a built-in method beside a dot-named one" {
  val k = 21
  assertEqual(k.twice().toString(), "42", "toString of the result")
  assertEqualLong(k.toLong(), 21i64, "a conversion method")
  assertEqualInt("abc".shout().length, 4, "length of the result")
}

test "a built-in method keeps its meaning over a same-named dot-named function" {
  val k = 3
  assertEqualInt(k.shl(2), 12, "bitwise shl")
  assertEqualInt(Int.shl(k, 2), -1, "the dot-named shl through its type")
  assertEqual(k.toString(), "3", "toString")
  assertEqual(Int.toString(k), "dot-named", "the dot-named toString through its type")
  val l = 5i64
  assertEqualInt(l.toInt(), 5, "a conversion")
  assertEqualInt(Long.toInt(l), -2, "the dot-named conversion through its type")
  assertEqual(" x ".trim(), "x", "a String method")
  assertEqual(String.trim(" x "), "dot-named", "the dot-named String method through its type")
}

test "the method call and the type-qualified call agree" {
  val k = 7
  assertEqualInt(k.twice(), Int.twice(k), "in")
  var a = 1
  var b = 1
  a.inc()
  Int.inc(b)
  assertEqualInt(a, b, "inout")
}

test "a dot-named function declared through an alias" {
  val n: Num = 4
  assertEqualInt(n.neg(), -4, "an alias-typed receiver")
  val k = 5
  assertEqualInt(k.neg(), -5, "an Int receiver")
  assertEqualInt(Num.neg(k) + Int.neg(k), -10, "through the alias and through the type")
}

test "a distinct type's own function and its underlying type's through value" {
  val a = Age.from(3)
  assertEqualInt(a.older().value, 4, "the distinct type's function")
  assertEqualInt(a.value.twice(), 6, "the underlying type's through value")
}
