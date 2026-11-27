//! Types whose invariants a `var` field write can break after construction.
package Inv.Types

import Std.Core

pub ref record Counter {
  var count: Int
  invariant: count >= 0
}

pub func newCounter(start: in Int): Counter {
  Counter(count = start)
}

/// A public function of the declaring package: its `inout` parameter is
/// re-checked on exit even though the package may break the invariant
/// internally.
pub func breakLocal(c: inout Counter) {
  c.count = -3
}

/// A generic type: its checker takes the type argument from the value it is given.
pub ref record Cell[T] {
  var n: Int
  var tag: T
  invariant: n >= 0
}

pub func newCell(start: in Int, tag: in String): Cell[String] {
  Cell(n = start, tag = tag)
}
