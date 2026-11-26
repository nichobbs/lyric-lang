package App

interface Holder[T] {
  func put(self: in Self, x: in T): Unit
}

func f(h: in Holder[Int]): Unit {
  h.put("s")
}

func main(): Int = 0
