package App

record Seed {
  n: Int
}

func Seed.base(x: in String): Int { 1 }
func Seed.base(x: in Int): Int { 2 }

func main(): Unit {
  println(toString(Seed.base(5)))
}
