//! A record invariant whose quantified conjunct is not a proposition
//! (#8322): the conjunct has no runtime check, so the type checker checks it
//! at the clause, and `lyric prove` attempts no obligation.
@proof_required
package NonBoolInvariant

record Bag {
  n: Int
  invariant: n > 0 and forall (k: Byte) where k > 0u8 { k + 1u8 }
}

func make(): Bag {
  Bag(n = 1)
}
