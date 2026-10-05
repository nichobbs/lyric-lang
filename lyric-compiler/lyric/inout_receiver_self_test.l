//! inout_receiver_self_test.l — runtime regression test for methods whose
//! receiver is `self: inout T` (#8179), on every target.
//!
//! A method's receiver is passed like any other parameter (docs/01 §5.2), so
//! an `inout` receiver is the caller's place: assigning `self`, or one of its
//! fields, writes that place.  A backend method takes its receiver as the
//! host `this`, which cannot be rebound, so on `--target dotnet` an
//! assignment to `self` was silently lost and on the JVM and native it failed
//! in codegen.  The middle end now lowers such a method to the dot-named
//! function it stands for (D037) and each call of it to a plain call with the
//! receiver as an ordinary `inout` argument (`Lyric.Pipeline`'s
//! `byref_receivers.l`).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/inout_receiver_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/inout_receiver_self_test.l
//!   lyric test --target native lyric-compiler/lyric/inout_receiver_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.InoutReceiverSelfTest

import Std.Core
import Std.Testing

// A value record (no `var` field): it is replaced, never mutated.
record Pt {
  x: Int
  y: Int

  func reset(self: inout Pt): Unit {
    self = Pt(x = 0, y = 0)
  }

  // Bare field names read the receiver, as in any method.
  func moved(self: inout Pt, d: in Int): Unit {
    self = Pt(x = x + d, y = y + d)
  }

  // A bare call of a sibling method is a call on the receiver.
  func resetThenMove(self: inout Pt, d: in Int): Unit {
    reset()
    moved(d)
  }

  func sum(self: in Pt): Int = self.x + self.y

  func copyOf(self: in Pt): Pt = Pt(x = self.x, y = self.y)
}

// The dot-named spelling of the same method (D037).
func Pt.scaled(self: inout Pt, k: in Int): Unit {
  self = Pt(x = self.x * k, y = self.y * k)
}

// A mutable record: its fields are written through the receiver.
record Counter {
  var n: Int

  // Returns the old count and advances the counter.
  func next(self: inout Counter): Int {
    val prev = n
    self = Counter(n = n + 1)
    prev
  }

  func bump(self: inout Counter, d: in Int): Unit {
    self.n = self.n + d
  }

  func bumpBare(self: inout Counter, d: in Int): Unit {
    n = n + d
  }

  func checkedAdd(self: inout Counter, d: in Int): Unit
    requires: d >= 0
    ensures: self.n == old(self.n) + d
  {
    self = Counter(n = self.n + d)
  }
}

record Holder {
  var p: Pt
  var c: Counter
}

record Outer {
  var h: Holder
}

record Box[T] {
  v: T

  func set(self: inout Box[T], v: in T): Unit {
    self = Box(v = v)
  }

  // An `in` receiver with an `inout T` parameter (#8182).
  func into(self: in Box[T], x: inout T): Unit {
    x = self.v
  }

  func swapWith(self: inout Box[T], other: inout Box[T]): Unit {
    val t = self
    self = other
    other = t
  }
}

// A function whose first parameter is `self: inout T` is the method's UFCS
// form; it is called with the receiver as its first argument.
func doubled(self: inout Pt): Unit {
  self = Pt(x = self.x * 2, y = self.y * 2)
}

// An `inout` parameter is a place, so it can be passed on as a receiver.
func resetVia(q: inout Pt): Unit {
  q.reset()
}

func addTwo(a: in Int, b: in Int): Int = a * 10 + b

func parseNum(s: in String): Result[Int, String] {
  if s == "five" {
    Ok(value = 5)
  } else {
    Err(error = "not a number: " + s)
  }
}

func moveByParsed(s: in String): Result[Int, String] {
  var p = Pt(x = 1, y = 2)
  p.moved(parseNum(s)?)
  Ok(value = p.x * 100 + p.y)
}

func dotMoveByParsed(s: in String): Result[Int, String] {
  var p = Pt(x = 1, y = 2)
  Pt.scaled(p, parseNum(s)?)
  Ok(value = p.x * 100 + p.y)
}

test "assigning `self` whole replaces the caller's variable" {
  var p = Pt(x = 5, y = 6)
  p.reset()
  assertEqualInt(p.x, 0, "x after reset")
  assertEqualInt(p.y, 0, "y after reset")
}

test "bare field names inside an `inout` method read the receiver" {
  var p = Pt(x = 5, y = 6)
  p.moved(3)
  assertEqualInt(p.x, 8, "x after moved")
  assertEqualInt(p.y, 9, "y after moved")
}

test "a bare sibling call inside an `inout` method acts on the same receiver" {
  var p = Pt(x = 5, y = 6)
  p.resetThenMove(4)
  assertEqualInt(p.x, 4, "x")
  assertEqualInt(p.y, 4, "y")
}

test "the type-qualified call form passes the receiver by reference" {
  var p = Pt(x = 5, y = 6)
  Pt.reset(p)
  assertEqualInt(p.sum(), 0, "sum after Pt.reset(p)")
  Pt.moved(p, 2)
  assertEqualInt(p.sum(), 4, "sum after Pt.moved(p, 2)")
}

test "a dot-named function with an `inout` receiver, both call forms" {
  var p = Pt(x = 1, y = 2)
  p.scaled(3)
  assertEqualInt(p.x * 10 + p.y, 36, "after p.scaled(3)")
  Pt.scaled(p, 2)
  assertEqualInt(p.x * 10 + p.y, 72, "after Pt.scaled(p, 2)")
}

test "a function whose first parameter is `self: inout`" {
  var p = Pt(x = 1, y = 2)
  doubled(p)
  assertEqualInt(p.x * 10 + p.y, 24, "after doubled(p)")
}

test "mutating fields of an `inout` receiver" {
  var c = Counter(n = 1)
  c.bump(4)
  assertEqualInt(c.n, 5, "after bump")
  c.bumpBare(10)
  assertEqualInt(c.n, 15, "after bumpBare")
}

test "an `inout` method that returns a value" {
  var c = Counter(n = 7)
  val a = c.next()
  val b = c.next()
  assertEqualInt(a, 7, "first next")
  assertEqualInt(b, 8, "second next")
  assertEqualInt(c.n, 9, "count after two calls")
}

test "contract clauses of an `inout` method see the receiver" {
  var c = Counter(n = 2)
  c.checkedAdd(3)
  assertEqualInt(c.n, 5, "after checkedAdd")
}

test "a field path as the receiver" {
  var h = Holder(p = Pt(x = 5, y = 6), c = Counter(n = 1))
  h.p.reset()
  assertEqualInt(h.p.sum(), 0, "h.p after reset")
  h.c.bump(2)
  assertEqualInt(h.c.n, 3, "h.c after bump")
  val v = h.c.next()
  assertEqualInt(v, 3, "h.c.next() result")
  assertEqualInt(h.c.n, 4, "h.c after next")
}

test "a nested field path as the receiver" {
  var o = Outer(h = Holder(p = Pt(x = 1, y = 1), c = Counter(n = 0)))
  o.h.p.moved(5)
  assertEqualInt(o.h.p.x, 6, "o.h.p.x")
  o.h.c.bump(9)
  assertEqualInt(o.h.c.n, 9, "o.h.c.n")
}

test "receivers in nested calls are evaluated in order" {
  var c = Counter(n = 1)
  val r = addTwo(c.next(), c.next())
  assertEqualInt(r, 12, "addTwo(c.next(), c.next())")
  assertEqualInt(c.n, 3, "count after the call")
}

test "an argument reading the receiver sees its value before the call" {
  var p = Pt(x = 2, y = 3)
  p.moved(p.sum())
  assertEqualInt(p.x, 7, "x")
  assertEqualInt(p.y, 8, "y")
}

test "an `inout` receiver call as an argument of another `inout` receiver call" {
  var a = Counter(n = 10)
  var b = Counter(n = 1)
  a.bump(b.next())
  assertEqualInt(a.n, 11, "a after a.bump(b.next())")
  assertEqualInt(b.n, 2, "b after b.next()")
}

test "an `inout` parameter passed on as a receiver" {
  var p = Pt(x = 3, y = 4)
  resetVia(p)
  assertEqualInt(p.sum(), 0, "after resetVia")
}

test "a generic record's `inout` method" {
  var b = Box(v = 1)
  b.set(42)
  assertEqualInt(b.v, 42, "Box[Int] after set")
  var s = Box(v = "a")
  s.set("zz")
  assertEqual(s.v, "zz", "Box[String] after set")
  Box.set(b, 7)
  assertEqualInt(b.v, 7, "Box[Int] after Box.set(b, 7)")
}

test "a generic record's `inout` method with a second `inout` parameter" {
  var a = Box(v = 1)
  var b = Box(v = 2)
  a.swapWith(b)
  assertEqualInt(a.v, 2, "a")
  assertEqualInt(b.v, 1, "b")
}

test "a generic record's `in` method with an `inout T` parameter (#8182)" {
  val b = Box(v = 42)
  var x = 1
  b.into(x)
  assertEqualInt(x, 42, "x after b.into(x)")
}

test "a method call next to `?`" {
  match moveByParsed("five") {
    case Ok(v) -> assertEqualInt(v, 607, "moved by the parsed value")
    case Err(e) -> assertTrue(false, "unexpected error: " + e)
  }
  match moveByParsed("x") {
    case Ok(_) -> assertTrue(false, "expected the `?` to return early")
    case Err(e) -> assertEqual(e, "not a number: x", "error passed through")
  }
}

test "a type-qualified call next to `?`" {
  match dotMoveByParsed("five") {
    case Ok(v) -> assertEqualInt(v, 510, "scaled by the parsed value")
    case Err(e) -> assertTrue(false, "unexpected error: " + e)
  }
}

test "an `in` method on the replaced value still works" {
  var p = Pt(x = 1, y = 2)
  val before = p.copyOf()
  p.reset()
  assertEqualInt(before.sum(), 3, "the copy taken before the call")
  assertEqualInt(p.sum(), 0, "the receiver after the call")
}
