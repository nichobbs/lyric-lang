package App

interface Holder[T] {
  func get(self: in Self): T
}

record IntBox {
  v: Int
}

impl Holder[Int] for IntBox {
  func get(self: in IntBox): Int = self.v
}

func read[T](x: in T): Int
  where T: Holder[Int]
{
  x.get()
}

func main(): Int = 0
