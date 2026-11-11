package App

record Inner { n: Int }

func f(b: in Inner): Int {
  b.n = 9
  b.n
}

func main(): Int { 0 }
