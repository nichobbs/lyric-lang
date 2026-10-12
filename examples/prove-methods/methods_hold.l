//! Record and `impl` methods whose contracts hold: a field read by its bare
//! name is the receiver's field, and an `impl` method satisfies the clauses
//! of the interface it implements as well as its own (#8231).
@proof_required
package MethodsHold

interface Sized {
  func size(self: in Self): Int
    ensures: result >= 0
}

record Stock {
  count: Int

  func clamped(self: in Stock): Int
    ensures: result >= 0 and result >= count
  {
    if count < 0 {
      0
    } else {
      count
    }
  }
}

impl Sized for Stock {
  func size(self: in Stock): Int {
    if self.count < 0 {
      0
    } else {
      self.count
    }
  }
}
