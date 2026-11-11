package App

record Inner { n: Int }

func f(): Int {
  val b = Inner(n = 1)
  b.n = 2
  b.n
}

func main(): Int { f() }
