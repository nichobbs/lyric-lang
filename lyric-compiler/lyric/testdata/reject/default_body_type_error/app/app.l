package App

interface Named {
  func label(self: in Self): String
  func tagged(self: in Self, n: in Int): Int {
    val q: Int = label()
    q + n
  }
}

// No impl at all: the default body is checked once, where it is declared.
func main(): Int {
  0
}
