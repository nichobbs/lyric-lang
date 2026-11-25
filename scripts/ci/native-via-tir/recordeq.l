//! recordeq.l - `==` and `!=` on records with array and Float leaves lowered from TIR (docs/70 phase 3c,
//! D506): an array leaf is compared element by element and a Float leaf is equal when `==` holds or both are
//! `NaN` (D172).  `native-via-tir-e2e.sh` runs it both ways.
package RecordEqViaTir

import Std.Core
import Std.Console as Console

record Sample {
  id: Int
  xs: array[3, Int]
  w: Double
}

record Grid {
  cells: array[2, Sample]
}

func sample(id: in Int, last: in Int, w: in Double): Sample {
  Sample(id = id, xs = [1, 2, last], w = w)
}

func nan(): Double {
  var z = 0.0
  z / z
}

func show(b: in Bool): String {
  if b {
    "yes"
  } else {
    "no"
  }
}

func main(): Unit {
  val a = sample(1, 3, 1.5)
  val same = sample(1, 3, 1.5)
  val otherElem = sample(1, 4, 1.5)
  val otherId = sample(2, 3, 1.5)
  println(show(a == same))
  println(show(a == otherElem))
  println(show(a != otherElem))
  println(show(a == otherId))
  println(show(sample(1, 3, nan()) == sample(1, 3, nan())))
  println(show(sample(1, 3, nan()) == a))
  val g1 = Grid(cells = [a, otherId])
  val g2 = Grid(cells = [same, otherId])
  val g3 = Grid(cells = [same, otherElem])
  println(show(g1 == g2))
  println(show(g1 == g3))
  println(show(g1 != g3))
}
