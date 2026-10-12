//! The interface `b.l` implements, in another file of the package.
package P

pub interface I {
  func f(self: in Self, k: in Int): Int
    ensures: result > 100
}
