package App

interface Named {
  func label(self: in Self): String
  func tagged(self: in Self, n: in Int): String = nosuchfn(n)
}

func main(): Int {
  0
}
