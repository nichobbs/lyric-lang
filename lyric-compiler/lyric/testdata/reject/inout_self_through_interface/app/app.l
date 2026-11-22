package App

record Box {
  n: Int
}

interface Absorber {
  func absorb(self: in Self, other: inout Self): Int
}

impl Absorber for Box {
  func absorb(self: in Box, other: inout Box): Int {
    val total = self.n + other.n
    other = Box(n = 0)
    total
  }
}

func main(): Int {
  val a: Absorber = Box(n = 3)
  var other = Box(n = 7)
  a.absorb(other)
}
