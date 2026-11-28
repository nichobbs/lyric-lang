package ByValueIface

import Std.Core

pub interface Named {
  func name(self: in Self): Int
  func plus(self: in Self, n: in Int): Int = name() + n
}

pub interface Holder[T] {
  func get(self: in Self): T
}

record P {
  x: Int
}

record Q {
  a: Int
  b: Int
}

impl Named for P {
  func name(self: in P): Int = self.x
}

impl Holder[Int] for Q {
  func get(self: in Q): Int = self.a + self.b
}

func nameOf(n: in Named): Int = n.name()

func firstOf(h: in Holder[Int]): Int = h.get() + h.get()

func main(): Int {
  println(toString(nameOf(P(x = 7))))
  val n: Named = P(x = 5)
  println(toString(n.plus(3)))
  println(toString(firstOf(Q(a = 2, b = 3))))
  println(toString(P(x = 9).plus(1)))
  0
}
