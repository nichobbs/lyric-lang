//! Public functions over `Inv.Types.Counter`, a type of another package.
package Inv.Api

import Std.Core
import Inv.Types

pub func readCount(c: in Counter): Int {
  c.count
}

pub func makeBroken(): Counter {
  val c = newCounter(1)
  c.count = -5
  c
}

pub func breakInPlace(c: inout Counter) {
  c.count = -2
}

pub func untouched(c: inout Counter): Int {
  c.count
}
