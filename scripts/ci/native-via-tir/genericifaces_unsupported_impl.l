package GenericIfacesUnsupportedImpl

import Std.Core

pub interface Holder[T] {
  func get(self: in Self): T
}

union Wrap[T] {
  case Full(v: T)
  case Empty
}

impl[T] Holder[T] for Wrap[T] {
  func get(self: in Wrap[T]): T = match self {
    case Full(v) -> v
    case Empty -> panic("empty")
  }
}

func main(): Int {
  val w: Wrap[String] = Full(v = "x")
  println(w.get())
  0
}
