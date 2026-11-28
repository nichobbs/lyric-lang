//! genericifaces_union_impl.l - `impl[T] Holder[T] for Wrap[T]` over a generic union on native (N0105, D891): the
//! union is a heap object and its vtable is laid out per instance, as a generic record's is (D864).  Called through
//! the interface at two instantiations, on the union value, and as an inherited default.
package GenericIfacesUnionImpl

import Std.Core

pub interface Holder[T] {
  func get(self: in Self): T
  func twice(self: in Self, x: in T): T = x
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

func useInt(h: in Holder[Int]): Int = h.get() + h.twice(10)

func useStr(h: in Holder[String]): String = h.get() + h.twice("!")

func main(): Int {
  val w: Wrap[Int] = Full(v = 4)
  println(toString(w.get()))
  println(toString(w.twice(9)))
  println(toString(useInt(w)))
  val s: Wrap[String] = Full(v = "ab")
  println(useStr(s))
  val h: Holder[Int] = w
  println(toString(h.get()))
  0
}
