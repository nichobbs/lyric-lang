//! records.l - by-value records (no `var` field, scalar fields) lowered from TIR (docs/70
//! phase 4a, D520): construction is an `insertvalue` chain, a field read an `extractvalue`,
//! `.copy` inserts into the base.  `native-via-tir-e2e.sh` runs it both ways.
package RecordsViaTir

import Std.Core
import Std.Console as Console

record Point {
  x: Int
  y: Int
}

record Seg {
  a: Point
  b: Point
  weight: Double
}

func make(x: in Int, y: in Int): Point {
  Point(x = x, y = y)
}

func manhattan(p: in Point): Int {
  p.x + p.y
}

func shifted(p: in Point, dx: in Int): Point {
  p.copy(x = p.x + dx)
}

func span(s: in Seg): Int {
  val dx = s.b.x - s.a.x
  val dy = s.b.y - s.a.y
  dx + dy
}

func scaled(s: in Seg): Double {
  s.weight * 2.0
}

func main(): Unit {
  val p = make(3, 4)
  println(toString(manhattan(p)))
  val q = shifted(p, 10)
  println(toString(q.x))
  println(toString(q.y))
  println(toString(p.x))
  val s = Seg(a = make(1, 1), b = q, weight = 1.5)
  println(toString(span(s)))
  println(toString(scaled(s)))
}
