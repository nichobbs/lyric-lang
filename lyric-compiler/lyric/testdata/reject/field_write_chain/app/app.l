package App

record Inner { n: Int }
record Outer { inner: Inner }

func f(): Int {
  val o = Outer(inner = Inner(n = 1))
  o.inner.n = 5
  o.inner.n
}

func main(): Int { f() }
