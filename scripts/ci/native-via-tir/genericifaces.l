package GenericIfaces

import Std.Core

pub interface Holder[T] {
  func get(self: in Self): T
  func twice(self: in Self, x: in T): T = x
  func put(self: in Self, x: in T): Int
}

pub interface Pair[A, B] {
  func first(self: in Self): A
  func second(self: in Self): B
}

record IntBox {
  v: Int
}

record StrBox {
  s: String
}

record Both {
  a: Int
  b: String
}

impl Holder[Int] for IntBox {
  func get(self: in IntBox): Int = self.v
  func put(self: in IntBox, x: in Int): Int = self.v + x
}

impl Holder[String] for StrBox {
  func get(self: in StrBox): String = self.s
  func put(self: in StrBox, x: in String): Int = x.length
}

impl Pair[Int, String] for Both {
  func first(self: in Both): Int = self.a
  func second(self: in Both): String = self.b
}

func useInt(h: in Holder[Int]): Int = h.get() + h.twice(10) + h.put(1)

func useStr(h: in Holder[String]): String = h.get() + h.twice("!")

func main(): Int {
  println(toString(useInt(IntBox(v = 4))))
  println(useStr(StrBox(s = "ab")))
  val p: Pair[Int, String] = Both(a = 7, b = "x")
  println(toString(p.first()) + p.second())
  val hs: Holder[String] = StrBox(s = "qq")
  println(toString(hs.put("four")))
  println(toString(IntBox(v = 2).twice(9)))
  println(StrBox(s = "z").twice("w"))
  0
}
