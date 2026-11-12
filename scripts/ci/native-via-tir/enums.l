//! enums.l - enum values and matches lowered from TIR (docs/70 phase 4a, D520): an enum is its
//! ordinal, a case pattern compares it.  `native-via-tir-e2e.sh` runs it both ways.
package EnumsViaTir

import Std.Core
import Std.Console as Console

enum Color {
  case Red
  case Green
  case Blue
}

func code(c: in Color): Int {
  match c {
    case Red -> 10
    case Green -> 20
    case Blue -> 30
  }
}

func next(c: in Color): Color {
  match c {
    case Red -> Green
    case Green -> Blue
    case Blue -> Red
  }
}

func main(): Unit {
  println(toString(code(Red)))
  println(toString(code(next(Red))))
  println(toString(code(next(next(Green)))))
}
