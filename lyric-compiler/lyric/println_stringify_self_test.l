//! println_stringify_self_test.l — dual-target runtime regression test for
//! `println` of a value that is not a `String` or one of the primitives
//! `Console`/`PrintStream` have a dedicated overload for (#7858).
//!
//! On dotnet, `println`'s catch-all handed any other value to
//! `Console.WriteLine(string)` unconverted: a record or list reference was read
//! as if it were a string (an access violation), and a value type was invalid
//! IL. On the JVM, any reference other than `String`/`Object` was passed to
//! `PrintStream.println(String)` and failed verification. Both now print what
//! `toString(x)` returns.
//!
//! `println` output cannot be captured in-process, so each case prints the
//! value and then its `toString`, between the `println-pairs-begin` and
//! `println-pairs-end` markers; `scripts/ci/println-stringify-e2e.sh` checks
//! that every pair is equal on both targets. A record's `toString` is the
//! target's default rendering (a JVM identity hash), so the pairs are compared
//! with each other rather than with fixed text.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/println_stringify_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/println_stringify_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.PrintlnStringifySelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Point {
  x: Int
  y: Int
}

union Shape {
  case Dot
  case Circle(radius: Int)
}

record Box[T] {
  value: T
}

func makeShape(r: in Int): Shape {
  if r == 0 {
    Dot
  } else {
    Circle(radius = r)
  }
}

func showViaGeneric[T](v: in T): String {
  toString(v)
}

test "println of a record, union, list, slice and generic payload" {
  val p = Point(x = 1, y = 2)
  val s = makeShape(3)
  val d = makeShape(0)
  val xs: List[Int] = newList()
  xs.add(4)
  val arr: slice[Int] = [5, 6]
  val bx = Box(value = p)
  val half = 0.5
  val whole = 1500.0
  println("println-pairs-begin")
  println(p)
  println(toString(p))
  println(s)
  println(toString(s))
  println(d)
  println(toString(d))
  println(xs)
  println(toString(xs))
  println(arr)
  println(toString(arr))
  println(bx.value)
  println(toString(bx.value))
  println(half)
  println(toString(half))
  println(whole)
  println(toString(whole))
  println("println-pairs-end")
  assertTrue(true, "printing a non-String value does not throw")
}

test "toString of a generic payload agrees with the direct call" {
  val whole = 1500.0
  assertEqual(showViaGeneric(whole), toString(whole), "Double through a generic")
  assertEqual(showViaGeneric(42), "42", "Int through a generic")
}
