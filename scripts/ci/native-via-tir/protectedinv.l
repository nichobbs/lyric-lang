//! protectedinv.l - a protected type's `invariant:` is asserted at the exit of each member (docs/70 phase 3c,
//! D509), lowered from TIR.  `native-via-tir-e2e.sh` runs it both ways and compiles a variant whose last call
//! breaks the invariant, comparing the panic message.
package ProtectedInvViaTir

import Std.Core
import Std.Console as Console

protected type Gauge {
  var level: Int = 0
  invariant: level >= 0
  entry raise(by: in Int): Int {
    level = level + by
    return level
  }
  entry lower(by: in Int): Int {
    level = level - by
    return level
  }
}

func main(): Unit {
  val g = Gauge()
  println(toString(g.raise(5)))
  println(toString(g.lower(2)))
}
