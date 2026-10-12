//! Each body of these quantifiers runs for every `Byte`, 0 included: `inv`'s
//! `requires:` and the division's non-zero divisor fail at `k == 0`.  Before
//! #8223 the verifier dropped every side condition of a quantifier's body
//! and proved both postconditions; `lyric prove` must refute them.
@proof_required
package QuantifierUnsound

@pure
func inv(x: in Byte): Byte
  requires: x != 0u8
{
  100u8 / x
}

func callsEveryByte(): Bool
  ensures: forall (k: Byte) { inv(k) == inv(k) }
{
  true
}

func dividesByEveryByte(): Bool
  ensures: forall (k: Byte) { 10u8 / k >= 0u8 }
{
  true
}
