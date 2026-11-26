package App

interface Holder[T] {
  func get(self: in Self): T
}

record LongBox { v: Long }

impl Holder[Long] for LongBox {
  func get(self: in LongBox): Long = self.v
}

func readInt(h: in Holder[Int]): Int = h.get()

func main(): Int {
  readInt(LongBox(v = 1))
}
