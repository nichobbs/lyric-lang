//! invariants.l - records with `invariant:` clauses lowered on TIR (docs/70 phase 4a part 8, D854): constructions
//! and `.copy` call the type's checker (D505), a top-level `pub` function re-checks its result (D507), and a method
//! of the record checks `self` at its boundary (D512).  Every function lowers from TIR and prints what the AST
//! path prints; `native-via-tir-e2e.sh` also compiles a violated invariant and compares the panic message.
package InvariantsViaTir

import Std.Core
import Std.Console as Console

pub record Span {
  lo: Int
  hi: Int
  invariant: lo <= hi

  func width(self: in Span): Int {
    self.hi - self.lo
  }
}

pub func make(lo: in Int, hi: in Int): Span {
  Span(lo = lo, hi = hi)
}

pub func widen(s: in Span, by: in Int): Span {
  s.copy(hi = s.hi + by)
}

func total(a: in Span, b: in Span): Int {
  (a.hi - a.lo) + (b.hi - b.lo)
}

func main(): Unit {
  val a = make(1, 4)
  val b = widen(a, 3)
  println(toString(total(a, b)))
  println(toString(b.width()))
  println(toString(b.hi))
}
