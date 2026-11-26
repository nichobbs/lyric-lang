package App

interface Holder[T] {
  func get(self: in Self): T
  func put(self: in Self, x: in T): Unit
}

record IntBox {
  v: Int
}

impl Holder[Int] for IntBox {
  func get(self: in IntBox): Int = self.v
}

func main(): Int = 0
