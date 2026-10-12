//! `lyric build` rejects this file (T0032: `x != 0` compares a `Small` with
//! an `Int`); `lyric prove` must stop with that diagnostic rather than prove
//! the obligations of a program that does not type-check (#8227).
@proof_required
package IllTyped

type Small = Int range 0 ..= 10

func pick(x: in Small): Small
  requires: x != 0
  ensures: result == x
{
  x
}
