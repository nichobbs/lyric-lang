//! methods.l - methods declared in a record's body lowered from TIR (docs/70 phase 4a, D520):
//! the receiver is the first parameter, and direct calls of the methods lower from TIR as well.
//! `native-via-tir-e2e.sh` runs it both ways and under AddressSanitizer.
package MethodsViaTir

import Std.Core
import Std.Console as Console

ref record Counter {
  var n: Int
  label: String

  func bump(by: in Int): Int {
    self.n = self.n + by
    self.n
  }

  func show(): String {
    self.label + "=" + toString(self.n)
  }

  func twice(): Int {
    self.bump(1) + self.bump(1)
  }
}

record Pt {
  x: Int
  y: Int

  func sum(): Int {
    self.x + self.y
  }

  func scaled(k: in Int): Pt {
    Pt(x = self.x * k, y = self.y * k)
  }
}

func main(): Unit {
  val c = Counter(n = 0, label = "c")
  println(toString(c.bump(5)))
  println(c.show())
  println(toString(c.twice()))
  println(c.show())
  val p = Pt(x = 2, y = 3)
  println(toString(p.sum()))
  println(toString(p.scaled(4).sum()))
}
