package App

union Pair {
  case Pair2(a: Int, b: Int)
}

func total(ps: in slice[Pair]): Int {
  var t = 0
  for Pair2(a) in ps {
    t = t + a
  }
  t
}

func main(): Int {
  0
}
