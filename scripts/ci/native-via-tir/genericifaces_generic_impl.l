package GenericIfacesGenericImpl

import Std.Core

pub interface Holder[T] {
  func get(self: in Self): T
}

record Box[T] {
  v: T
}

impl[T] Holder[T] for Box[T] {
  func get(self: in Box[T]): T = self.v
}

func main(): Int {
  val b: Box[Int] = Box(v = 1)
  println(toString(b.get()))
  0
}
