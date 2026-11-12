package App

record Counter {
  n: Int
  func bump(self: in Counter): Int {
    self.n = self.n + 1
    self.n
  }
}

func main(): Int { 0 }
