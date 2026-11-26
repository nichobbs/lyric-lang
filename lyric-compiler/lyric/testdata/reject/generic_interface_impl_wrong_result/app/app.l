package App

interface Holder[T] {
  func get(self: in Self): T
}

record IntBox {
  v: Int
}

impl Holder[Int] for IntBox {
  func get(self: in IntBox): String = "x"
}

func main(): Int = 0
