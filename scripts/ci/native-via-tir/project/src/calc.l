//! calc.l - the library package of the via-TIR project fixture.
package Calc

import Std.Core

pub record Pair {
  left: Int
  right: Int
}

pub union Op {
  case Add
  case Mul(by: Int)
}

pub func scale(x: in Int, k: in Int): Int {
  x * k
}

pub func swap(p: in Pair): Pair {
  Pair(left = p.right, right = p.left)
}

pub func apply(op: in Op, x: in Int): Int {
  match op {
    case Add -> x + x
    case Mul(by) -> x * by
  }
}
