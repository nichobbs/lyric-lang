//! The guarded twins of `unsound.l`: each side condition holds wherever the
//! body runs, so `lyric prove` proves every obligation (#8223).
@proof_required
package QuantifierSound

@pure
func inv(x: in Byte): Byte
  requires: x != 0u8
{
  100u8 / x
}

func callsNonZeroBytes(): Bool
  ensures: forall (k: Byte) where k != 0u8 { inv(k) == inv(k) }
{
  true
}

func dividesByNonZeroBytes(): Bool
  ensures: forall (k: Byte) where k > 0u8 { 10u8 / k >= 0u8 }
{
  true
}
