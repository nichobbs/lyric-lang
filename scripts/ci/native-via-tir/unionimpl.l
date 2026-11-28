package UnionImpl

import Std.Core

pub interface Sized {
  func size(self: in Self): Int
  func doubled(self: in Self): Int = size() * 2
}

union Shape {
  case Circle(r: Int)
  case Sq(s: Int)
}

impl Sized for Shape {
  func size(self: in Shape): Int = match self {
    case Circle(r) -> r
    case Sq(s) -> s * s
  }
}

func sizeOf(s: in Sized): Int = s.size()

func main(): Int {
  println(toString(sizeOf(Circle(r = 3))))
  println(toString(sizeOf(Sq(s = 4))))
  println(toString(Circle(r = 5).size()))
  val s: Shape = Sq(s = 3)
  println(toString(s.doubled()))
  0
}
