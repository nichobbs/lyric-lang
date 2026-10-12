//! Functions overloaded by arity are each proved, and a call reaches the one
//! taking its argument count (#8341).
@proof_required
package Overloads

pub func add(x: in Int): Int
  ensures: result == x
{
  x
}

pub func add(x: in Int, y: in Int): Int
  ensures: result == x + y
{
  x + y
}

pub func twiceAndOne(x: in Int): Int
  ensures: result == 2 * x + 1
{
  add(x) + add(x, 1)
}
