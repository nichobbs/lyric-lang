//! `add(x)` binds this file's `add`, not `b.l`'s `add(x, y = 100)`.
@proof_required
package P

pub func add(x: in Int): Int
  requires: x >= 0 and x <= 1000
  ensures: result == x
{
  x
}
