//! elems.l - by-value elements in lists and maps, compound element assignment and map snapshots
//! lowered from TIR (docs/70 phase 4a, D520): a by-value record is held in a slot as a counted
//! box and copied in and out, `xs[i] += v` and `m[k] += v` read the element after the right-hand
//! side, and `mapKeys`/`mapValues` are the runtime's snapshots.  `native-via-tir-e2e.sh` runs it
//! both ways and under AddressSanitizer.
package ElemsViaTir

import Std.Core
import Std.Collections
import Std.Console as Console

record Vec {
  x: Int
  y: Int
}

func vecs(): List[Vec] {
  val xs: List[Vec] = newList()
  xs.add(Vec(x = 1, y = 2))
  xs.add(Vec(x = 3, y = 4))
  xs[0] = Vec(x = 10, y = 20)
  xs
}

func vecTotal(xs: in List[Vec]): Int {
  var t = 0
  for v in xs {
    t = t + v.x + v.y
  }
  t
}

func literal(): Int {
  val xs: List[Vec] = [Vec(x = 1, y = 1), Vec(x = 2, y = 2)]
  xs[1].y + xs.count
}

func table(): Int {
  val m: Map[Int, Vec] = newMap()
  m.add(1, Vec(x = 5, y = 6))
  m[2] = Vec(x = 7, y = 8)
  var s = 0
  for v in mapValues(m) {
    s = s + v.x
  }
  m[1].x + m[2].y + m.count + s
}

func bumps(): Int {
  val xs: List[Int] = [1, 2, 3]
  xs[1] += 10
  xs[2] *= 4
  val ss: List[String] = ["a", "b"]
  ss[0] += "!"
  val m: Map[String, Int] = newMap()
  m.add("k", 5)
  m["k"] += 2
  m["k"] -= 1
  xs[1] + xs[2] + ss[0].length + m["k"]
}

func snapshots(): String {
  val m: Map[String, Int] = newMap()
  m.add("only", 4)
  var acc = ""
  for k in mapKeys(m) {
    acc = acc + k
  }
  for v in mapValues(m) {
    acc = acc + toString(v)
  }
  acc
}

func main(): Unit {
  println(toString(vecTotal(vecs())))
  println(toString(literal()))
  println(toString(table()))
  println(toString(bumps()))
  println(snapshots())
}
