package GenericIfacesUnsupportedImpl

import Std.Core

pub interface Holder[T] {
  func get(self: in Self): T
}

record Pair2[A, B] {
  a: A
  b: B
}

impl[T] Holder[T] for Pair2[T, Int] {
  func get(self: in Pair2[T, Int]): T = self.a
}

func main(): Int {
  val p: Pair2[String, Int] = Pair2(a = "x", b = 1)
  println(p.get())
  0
}
