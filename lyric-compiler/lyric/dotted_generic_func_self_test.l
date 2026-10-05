//! Generic functions named after a record (`func Box.get[T](self: in Box[T])`,
//! #8173): a method call `b.get()` and a type-qualified call `Box.get(b)` are
//! both specialised per instantiation, including over a value parameter
//! (`func Ints.sum[N: Nat]`), and a free function's `self` parameter is typed
//! by its declaration.  Run on dotnet, the JVM and native.
@test_module
package Lyric.DottedGenericFuncSelfTest

import Std.Testing

record Box[T] {
  v: T
}

record Ints[N: Nat] {
  var data: array[N, Int]
}

func Box.get[T](self: in Box[T]): T = self.v

func Box.orElse[T](self: in Box[T], other: in T, useOther: in Bool): T {
  if useOther {
    other
  } else {
    self.v
  }
}

func Ints.sum[N: Nat](self: in Ints[N]): Int {
  var t = 0
  for x in self.data {
    t = t + x
  }
  t
}

func Ints.first[N: Nat](self: in Ints[N]): Int = self.data[0]

func Ints.size[N: Nat](self: in Ints[N]): Int = N

func total3(self: in Ints[3]): Int {
  var t = 0
  for x in self.data {
    t = t + x
  }
  t
}

test "a method call specialises per type argument" {
  val b = Box(v = 41)
  assertEqualInt(b.get() + 1, 42, "Box[Int]")
  val s = Box(v = "hi")
  assertEqual(s.get(), "hi", "Box[String]")
  assertEqualInt(b.orElse(7, true), 7, "extra arguments follow the receiver")
  assertEqualInt(b.orElse(7, false), 41, "the receiver")
}

test "a type-qualified call specialises per type argument" {
  val b = Box(v = 41)
  assertEqualInt(Box.get(b) + 1, 42, "Box.get(b)")
  assertEqual(Box.get(Box(v = "x")), "x", "Box[String]")
  assertEqualInt(Box.orElse(b, 9, true), 9, "Box.orElse")
}

test "a value-generic function named after a record specialises per length" {
  val a: array[3, Int] = [1, 2, 3]
  val v = Ints(data = a)
  assertEqualInt(v.sum(), 6, "length 3")
  assertEqualInt(v.size(), 3, "N is a constant")
  assertEqualInt(v.first(), 1, "an index read")
  val c: array[2, Int] = [5, 5]
  val w = Ints(data = c)
  assertEqualInt(w.sum(), 10, "length 2")
  assertEqualInt(Ints.size(w), 2, "a type-qualified call")
}

func firstOf3(v: in Ints[3]): Int = v.data[0]

func makeInts3(x: in Int): Ints[3] {
  val a: array[3, Int] = [x, x, x]
  Ints(data = a)
}

test "a free function's self parameter has its declared type" {
  val a: array[3, Int] = [4, 5, 6]
  assertEqualInt(total3(Ints(data = a)), 15, "for over self.data")
}

test "a non-generic function over a record instance is called by its type" {
  val a: array[3, Int] = [7, 8, 9]
  assertEqualInt(firstOf3(Ints(data = a)), 7, "a parameter")
  assertEqualInt(total3(makeInts3(2)), 6, "a return")
}
