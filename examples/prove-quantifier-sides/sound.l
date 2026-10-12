//! The guarded twins of `unsound.l`: each side condition holds wherever the
//! body runs, so `lyric prove` proves every obligation (#8223), in each
//! form a quantifier's body is written in (#8305).
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

func callsNonZeroBytesBare(): Bool
  ensures: forall (k: Byte) where k != 0u8 inv(k) == inv(k)
{
  true
}

func dividesByNonZeroBytesImplies(): Bool
  ensures: forall (k: Byte) where k > 0u8 implies 10u8 / k >= 0u8
{
  true
}
