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
