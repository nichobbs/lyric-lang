//! A quantifier whose body is not a proposition (#8322): the type checker
//! rejects it, so `lyric prove` attempts no obligation.
@proof_required
package NonBoolQuantifier

func everyByte(): Unit
  ensures: forall (k: Byte) where k > 0u8 { k + 1u8 }
{
}
