//! The type-correct twin of `illtyped.l`: `lyric prove` proves it.
@proof_required
package WellTyped

func pick(x: in Int): Int
  requires: x != 0
  ensures: result == x
{
  x
}
