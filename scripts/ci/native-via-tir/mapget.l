//! mapget.l - `mapGet` and `mapSize` lowered from TIR (docs/70 phase 4a part 8, D857): `mapSize` is the kernel's
//! length, `mapGet` is `Some(v)` of a stored value (a reference value is retained by the `Some`) or `None`.
//! `native-via-tir-e2e.sh` runs it both ways and under AddressSanitizer.
package MapGetViaTir

import Std.Core
import Std.Collections
import Std.Console as Console

record Item {
  id: Int
  label: String
}

func lookup(m: in Map[Int, Item], k: in Int): String {
  match mapGet(m, k) {
    case Some(it) -> it.label
    case None -> "none"
  }
}

func countOf(m: in Map[String, Int]): Int {
  mapSize(m)
}

func total(m: in Map[String, Int], k: in String): Int {
  match mapGet(m, k) {
    case Some(n) -> n
    case None -> 0 - 1
  }
}

func main(): Unit {
  val items: Map[Int, Item] = newMap()
  items.add(1, Item(id = 1, label = "one" + "!"))
  items.add(2, Item(id = 2, label = "two"))
  println(lookup(items, 1))
  println(lookup(items, 3))
  val counts: Map[String, Int] = newMap()
  counts.add("a", 5)
  counts.add("b", 7)
  println(toString(countOf(counts)))
  println(toString(total(counts, "b")))
  println(toString(total(counts, "z")))
}
