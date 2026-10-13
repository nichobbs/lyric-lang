//! A generic record is one parametric datatype: its fields are read at the
//! instance the receiver is, in a generic function, a method and at a
//! closed instance alike, and a constructor's value is the instance its
//! fields give it (#8340).
@proof_required
package Boxes

pub record Box[T] {
  n: Int
  v: T

  func size(self: in Box[T]): Int
    ensures: result == self.n
  {
    n
  }
}

pub func size[T](b: in Box[T]): Int
  ensures: result == b.n
{
  b.n
}

pub func mk(x: in Int): Box[Int]
  ensures: result.v == x and result.n == 1
{
  Box(n = 1, v = x)
}

pub func nonNegative(b: in Box[Int]): Int
  requires: b.v >= 0
  ensures: result >= 0
{
  b.v
}
