//! No argument meets `pick`'s precondition, so every proof of `pick` would
//! hold vacuously: `lyric prove` reports the clause (V0035).  The check is
//! not an obligation of `pick`, so the count is of its one postcondition
//! (#8223).
@proof_required
package QuantifierVacuous

func pick(x: in Byte): Byte
  requires: x > 5u8 and x < 3u8
  ensures: result == 7u8
{
  x
}
