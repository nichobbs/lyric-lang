//! generic_interface_self_test.l - runtime regression test for generic
//! interfaces (#7791): an impl of a concrete instantiation, a generic impl
//! over a generic record, calls through an interface-typed value, and an
//! interface method that has type parameters of its own.  Run on every target
//! that lowers them (`lyric test`, `--target dotnet` and `--target jvm`).
@test_module
package Lyric.GenericInterfaceSelfTest

import Std.Core
import Std.Collections
import Std.Testing

interface Holder[T] {
  func get(self: in Self): T
  func put(self: in Self, x: in T): Unit
}

interface Mapper[A, B] {
  func apply(self: in Self, x: in A): B
}

interface Echo {
  func id[U](self: in Self, x: in U): U
}

interface Named[T] {
  func label(self: in Self): String
  func tagged(self: in Self, x: in T): String = label() + ":" + "tagged"
}

ref record IntBox {
  var v: Int
}

impl Holder[Int] for IntBox {
  func get(self: in IntBox): Int = self.v
  func put(self: in IntBox, x: in Int): Unit {
    self.v = x
  }
}

ref record Box[T] {
  var v: T
}

impl[T] Holder[T] for Box[T] {
  func get(self: in Box[T]): T = self.v
  func put(self: in Box[T], x: in T): Unit {
    self.v = x
  }
}

record Doubler {
  k: Int
}

impl Mapper[Int, String] for Doubler {
  func apply(self: in Doubler, x: in Int): String = toString(x * self.k)
}

record Label {
  s: String
}

impl Echo for Label {
  func id[V](self: in Label, x: in V): V = x
}

impl Named[Int] for Label {
  func label(self: in Label): String = self.s
}

impl Named[String] for IntBox {
  func label(self: in IntBox): String = "box"
}

ref record LongBox {
  var v: Long
}

impl Holder[Long] for LongBox {
  func get(self: in LongBox): Long = self.v
  func put(self: in LongBox, x: in Long): Unit {
    self.v = x
  }
}

func swapIn[T](h: in Holder[T], x: in T): T {
  val before = h.get()
  h.put(x)
  before
}

func readIt(h: in Holder[Int]): Int = h.get()

func bump(h: in Holder[Int]): Int {
  h.put(h.get() + 1)
  h.get()
}

func readAny[T](h: in Holder[T]): T = h.get()

func through(m: in Mapper[Int, String], x: in Int): String = m.apply(x)

func echoTwice(e: in Echo, n: in Int, s: in String): String = toString(e.id(n)) + e.id(s)

test "an impl of a concrete instantiation of a generic interface runs" {
  val b = IntBox(v = 7)
  assertEqualInt(b.get(), 7, "direct call")
  b.put(9)
  assertEqualInt(b.get(), 9, "after put")
}

test "a call through a generic-interface-typed value dispatches" {
  val b = IntBox(v = 40)
  assertEqualInt(readIt(b), 40, "read through Holder[Int]")
  assertEqualInt(bump(b), 41, "put then get through Holder[Int]")
  assertEqualInt(b.v, 41, "the record saw the write")
}

test "a generic impl over a generic record runs at two instantiations" {
  val i = Box(v = 5)
  val s = Box(v = "five")
  assertEqualInt(readAny(i), 5, "Box[Int] as Holder[Int]")
  assertEqual(readAny(s), "five", "Box[String] as Holder[String]")
  s.put("six")
  assertEqual(s.get(), "six", "put on Box[String]")
  assertEqualInt(bump(i), 6, "Box[Int] passed as Holder[Int]")
}

test "an interface with two type parameters dispatches" {
  val d = Doubler(k = 3)
  assertEqual(d.apply(4), "12", "direct")
  assertEqual(through(d, 5), "15", "through Mapper[Int, String]")
}

test "a method-generic interface method runs" {
  val l = Label(s = "x")
  assertEqual(echoTwice(l, 3, "a"), "3a", "through Echo")
  assertEqualInt(l.id(8), 8, "direct, Int")
  assertEqual(l.id("z"), "z", "direct, String")
}

test "different records implement different instantiations of one interface" {
  val l = Label(s = "lbl")
  val b = IntBox(v = 1)
  assertEqual(l.label(), "lbl", "Label as Named[Int]")
  assertEqual(b.label(), "box", "IntBox as Named[String]")
}

test "a default method of a generic interface runs" {
  val l = Label(s = "lbl")
  assertEqual(l.tagged(1), "lbl:tagged", "Named[Int].tagged")
}

test "a generic function over a generic interface runs at each implementor's instantiation" {
  val b = LongBox(v = 5000000000)
  assertEqualLong(swapIn[Long](b, 7), 5000000000, "old value")
  assertEqualLong(b.get(), 7, "new value")
  val i = IntBox(v = 1)
  assertEqualInt(swapIn(i, 2), 1, "Int implementor")
}
