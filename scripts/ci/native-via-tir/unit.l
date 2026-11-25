//! unit.l - Unit parameters, locals, arguments and assignments lowered from TIR (docs/70 phase 4a,
//! D536): a Unit value owns no storage, so a Unit parameter keeps only its position, a Unit local
//! reads as Unit and an assignment to it only evaluates its right-hand side.
//! `native-via-tir-e2e.sh` runs it both ways and under AddressSanitizer.
package UnitViaTir

import Std.Core
import Std.Console as Console

func note(n: in Int): Unit {
  println("note " + toString(n))
}

func takes(u: in Unit, n: in Int): Int {
  n + 1
}

func passes(n: in Int): Int {
  val u = note(n)
  takes(u, n)
}

func reassigns(n: in Int): Int {
  var u = note(n)
  u = note(n + 1)
  takes(u, n)
}

func main(): Unit {
  println(toString(passes(1)))
  println(toString(reassigns(10)))
  println(toString(takes(note(7), 3)))
}
