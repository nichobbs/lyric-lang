//! arrays.l - inline `array[N, T]` of by-value elements lowered from TIR (docs/70 phase 4a, D520):
//! element reads and writes through the element's address, compound assignment, nested arrays, an
//! array held by a by-value and by a heap record, `for` over an array, `.length`, an element passed
//! `inout` and an array of by-value records.  `native-via-tir-e2e.sh` runs it both ways.
package ArraysViaTir

import Std.Core
import Std.Console as Console

record Vec {
  x: Int
  y: Int
}

record Mesh {
  cells: array[3, Int]
  n: Int
}

ref record Tally {
  var hits: array[4, Int]
}

func inc(x: inout Int): Unit {
  x = x + 1
}

func sum(a: in array[4, Int]): Int {
  var s = 0
  for x in a {
    s = s + x
  }
  s
}

func squares(): array[4, Int] {
  var a: array[4, Int]
  var i = 0
  while i < a.length {
    a[i] = i * i
    i = i + 1
  }
  a
}

func bump(t: in Tally, i: in Int): Unit {
  t.hits[i] += 1
}

func grid(): Int {
  var g: array[2, array[3, Int]] = [[1, 2, 3], [4, 5, 6]]
  g[1][2] = 9
  g[0][1] += 10
  g[1][2] + g[0][1]
}

func meshTotal(m: in Mesh): Int {
  m.cells[0] + m.cells[1] + m.cells[2] + m.n
}

func vecs(): Int {
  var vs: array[2, Vec] = [Vec(x = 1, y = 2), Vec(x = 3, y = 4)]
  vs[1].x + vs[0].y
}

func bumpElem(): Int {
  var a: array[3, Int] = [10, 20, 30]
  inc(a[1])
  a[1]
}

func at(a: in array[3, Int], i: in Int): Int {
  a[i]
}

func main(): Unit {
  println(toString(sum(squares())))
  val sq = squares()
  println(toString(sq[3]))
  val t = Tally(hits = [0, 0, 0, 0])
  bump(t, 2)
  bump(t, 2)
  bump(t, 0)
  println(toString(sum(t.hits)))
  println(toString(t.hits[2]))
  println(toString(grid()))
  println(toString(meshTotal(Mesh(cells = [1, 2, 3], n = 4))))
  println(toString(vecs()))
  println(toString(bumpElem()))
  println(toString(at([7, 8, 9], 2)))
}
