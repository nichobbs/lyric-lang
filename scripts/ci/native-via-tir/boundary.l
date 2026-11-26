//! boundary.l - a `pub` function that writes an `inout` parameter of an invariant type re-checks it at exit
//! (docs/70 phase 3c, D507), lowered from TIR.  `native-via-tir-e2e.sh` runs it both ways and compiles a variant
//! whose call breaks the invariant, comparing the panic message.
package BoundaryViaTir

import Std.Core
import Std.Console as Console

pub ref record Span {
  var lo: Int
  var hi: Int
  invariant: lo <= hi
}

pub func make(lo: in Int, hi: in Int): Span {
  Span(lo = lo, hi = hi)
}

pub func grow(s: inout Span, by: in Int): Unit {
  s.hi = s.hi + by
}

pub func shrink(s: inout Span, by: in Int): Unit {
  s.hi = s.hi - by
}

func main(): Unit {
  var s = make(1, 4)
  grow(s, 3)
  println(toString(s.hi))
  shrink(s, 2)
  println(toString(s.hi))
}
