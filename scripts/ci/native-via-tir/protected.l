//! protected.l - protected types lowered from TIR (docs/70 phase 4a, D520): an entry or function's
//! body (without the lock the AST path's wrapper takes) reads and writes the object's fields; the
//! wrapper and entries with a `when:` barrier stay on the AST path; construction (`main`) is lowered,
//! with the mutex the object's last field holds.
//! `native-via-tir-e2e.sh` runs it both ways and under AddressSanitizer.
package ProtectedViaTir

import Std.Core
import Std.Console as Console

protected type Counter {
  var n: Int = 0
  var label: String = "c"
  entry bump(by: in Int): Int {
    n = n + by
    return n
  }
  entry rename(to: in String): String {
    label = to
    return label
  }
  func peek(): Int {
    return n
  }
  entry describe(): String {
    return label + "=" + toString(n)
  }
}

func main(): Unit {
  val c = Counter()
  println(toString(c.bump(3)))
  println(toString(c.bump(4)))
  println(c.rename("total"))
  println(c.describe())
  println(toString(c.peek()))
}
