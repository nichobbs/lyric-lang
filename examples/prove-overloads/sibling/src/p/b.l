//! `add(x)` in `useIt` binds `a.l`'s `add(x)`: the proof must not take this
//! file's `add(x, y = 100)` contract for it (#8341), so it fails closed.
@proof_required
package P

pub func add(x: in Int, y: in Int = 100): Int
  requires: x >= 0 and x <= 1000 and y >= 0 and y <= 1000
  ensures: result == x + y
{
  x + y
}

pub func useIt(x: in Int): Int
  requires: x >= 0 and x <= 1000
  ensures: result == x + 100
{
  add(x)
}
