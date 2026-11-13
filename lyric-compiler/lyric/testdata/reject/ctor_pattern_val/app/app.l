package App

union Pair {
  case Pair2(a: Int, b: Int)
}

func first(p: in Pair): Int {
  val Pair2(a) = p
  a
}

func main(): Int {
  first(Pair2(a = 1, b = 2))
}
