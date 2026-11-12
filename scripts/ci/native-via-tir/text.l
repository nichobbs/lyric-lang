//! text.l - string interpolation, matching a String against literals, a Double literal pattern
//! and string indexing lowered from TIR (docs/70 phase 4a, D520).  `native-via-tir-e2e.sh` runs it
//! both ways and then under AddressSanitizer.
package TextViaTir

import Std.Core
import Std.Console as Console

func label(n: in Int, s: in String): String {
  "n=${n} s=${s}!"
}

func byName(s: in String): Int {
  match s {
    case "alpha" -> 1
    case "beta" -> 2
    case _ -> 0
  }
}

func half(x: in Double): Double {
  match x {
    case 1.0 -> 0.5
    case _ -> x / 2.0
  }
}

func first(s: in String): Char {
  s[0]
}

func main(): Unit {
  println(label(7, "q"))
  println(toString(byName("beta")))
  println(toString(byName("gamma")))
  println(toString(half(1.0)))
  println(toString(half(5.0)))
  println(toString(first("zed")))
}
