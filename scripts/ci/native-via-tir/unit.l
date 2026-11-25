//! unit.l - Unit parameters, locals and arguments lowered from TIR (docs/70 phase 4a,
//! D536): a Unit value owns no storage, so a Unit parameter keeps only its position, and a Unit local
//! reads as Unit.
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

union Step {
  case Tick(u: Unit)
  case Stop
}

func stepValue(s: in Step): Int {
  match s {
    case Tick(u) -> 1
    case Stop -> 0
  }
}

func main(): Unit {
  println(toString(passes(1)))
  println(toString(takes(note(7), 3)))
  println(toString(stepValue(Tick(note(3))) + stepValue(Stop)))
  println()
  println(toString(note(2)))
}
