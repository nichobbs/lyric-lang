//! A bare call in an interface's clause is a call of the interface's own
//! method on `self`, never the free function `limit` of the same name: `get`
//! returns 5, which need not be at least `self.limit()`, so the inherited
//! `ensures:` is refuted (#8231).
@proof_required
package InheritedBareCall

@pure
func limit(): Int {
  0
}

interface L {
  func limit(self: in Self): Int
  func get(self: in Self): Int
    ensures: result >= limit()
}

record R {
  n: Int
}

impl L for R {
  func limit(self: in R): Int {
    100
  }

  func get(self: in R): Int {
    5
  }
}
