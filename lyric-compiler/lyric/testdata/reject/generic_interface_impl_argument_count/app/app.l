package App

interface Holder[T] {
  func get(self: in Self): T
}

record IntBox {
  v: Int
}

impl Holder[Int, Int] for IntBox {
  func get(self: in IntBox): Int = self.v
}

func main(): Int = 0
