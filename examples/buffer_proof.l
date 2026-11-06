//! A `@proof_required` program over `buffer[T]` (#8394, #8753): `lyric prove`
//! applies `Std.Buffer`'s contracts at each call, models element writes and
//! proves a `for` loop over the value it started with.
//!
//!   lyric prove examples/buffer_proof.l
@proof_required(unbounded_arithmetic)
package BufferProof

import Std.Buffer

/// The last of three copies of `7`.
func lastOfFilled(): Int
  ensures: result == 7
{
  val b = filled(3, 7)
  b[2]
}

/// `x` grown by one element, then that element set.
func appended(x: in buffer[Int], v: in Int): Int
  requires: x.length > 0
  ensures: result == v
{
  var b: buffer[Int] = grow(x, x.length + 1, 0)
  b[x.length] = v
  b[b.length - 1]
}

/// The first element survives `truncate`.
func firstKept(x: in buffer[Int]): Int
  requires: x.length >= 2
  ensures: result == x[0]
{
  val t = truncate(x, 1)
  t[0]
}

/// A sum of elements that are each at most 10.
type Small = Int range 0 ..= 10

func sumNonNegative(x: in array[4, Small]): Int
  ensures: result >= 0
{
  var total = 0
  for v in x
    invariant: total >= 0
  {
    total = total + v.value
  }
  total
}

func main(): Unit {
  println(toString(lastOfFilled()))
}
