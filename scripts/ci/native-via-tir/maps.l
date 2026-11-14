//! maps.l - `Map[K, V]` lowered from TIR (docs/70 phase 4a, D520): `newMap`, `add`,
//! `containsKey`, `remove`, `count`, `m[k]` and `m[k] = v` over `String` and scalar keys with
//! scalar and reference values.  `native-via-tir-e2e.sh` runs it both ways and under
//! AddressSanitizer.
package MapsViaTir

import Std.Core
import Std.Collections
import Std.Console as Console

record Item {
  label: String
  qty: Int
}

func counts(words: in slice[String]): Map[String, Int] {
  val m: Map[String, Int] = newMap()
  for w in words {
    if m.containsKey(w) {
      m[w] = m[w] + 1
    } else {
      m.add(w, 1)
    }
  }
  m
}

func items(): Map[Int, Item] {
  val m: Map[Int, Item] = newMap()
  m.add(1, Item(label = "one", qty = 10))
  m.add(2, Item(label = "two", qty = 20))
  m[3] = Item(label = "three", qty = 30)
  m
}

func lookup(m: in Map[Int, Item], k: in Int): String {
  if m.containsKey(k) {
    m[k].label + ":" + toString(m[k].qty)
  } else {
    "none"
  }
}

func shrink(): Int {
  val m = items()
  val gone = m.remove(2)
  val again = m.remove(2)
  if gone and not again { m.count } else { -1 }
}

func main(): Unit {
  val c = counts(["a", "b", "a", "c", "a", "b"])
  println(toString(c["a"]) + toString(c["b"]) + toString(c["c"]) + toString(c.count))
  val m = items()
  println(lookup(m, 2))
  println(lookup(m, 3))
  println(lookup(m, 9))
  println(toString(shrink()))
}
