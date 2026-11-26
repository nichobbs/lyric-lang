package GenericIfacesGenericImpl

import Std.Core

pub interface Holder[T] {
  func get(self: in Self): T
  func twice(self: in Self, x: in T): T = x
}

record Box[T] {
  v: T
}

impl[T] Holder[T] for Box[T] {
  func get(self: in Box[T]): T = self.v
}

func useInt(h: in Holder[Int]): Int = h.get() + h.twice(10)

func useStr(h: in Holder[String]): String = h.get() + h.twice("!")

func main(): Int {
  val b: Box[Int] = Box(v = 4)
  println(toString(b.get()))
  println(toString(useInt(b)))
  val s: Box[String] = Box(v = "ab")
  println(useStr(s))
  val h: Holder[Int] = b
  println(toString(h.get()))
  0
}
