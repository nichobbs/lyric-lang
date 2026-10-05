//! False at run time for two distinct `Option(isSome = false, ...)`
//! values; `lyric prove` must not discharge it.
@proof_required
package P

func f(o: in Option[Int], p: in Option[Int]): Bool
  ensures: result
{
  o.isSome or p.isSome or o == p
}
