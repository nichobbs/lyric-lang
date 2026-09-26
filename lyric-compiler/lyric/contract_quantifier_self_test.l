//! Contract quantifiers under a runtime-checked build (#7228).
//!
//! A `forall`/`exists` ranges over a type, so it cannot be evaluated at
//! runtime.  It used to be lowered as the constant `true`, which is only sound
//! in a positive position: `not exists ...` became `false` and a precondition
//! written that way failed on every call.  Now the `and`-conjunct containing
//! the quantifier is skipped (with W0002) and the rest of the clause is still
//! checked.  Runs on every target.
@runtime_checked
@test_module
package ContractQuantifierSelfTest

import Std.Core
import Std.Testing

func negatedExists(n: in Int): Int
  requires: not (exists (i: Int) { i * i == n and n < 0 })
{
  n + 1
}

func conjunctStillChecked(n: in Int): Int
  requires: n > 0 and forall (i: Int) where i > 0 and i < n { i < n }
{
  n
}

func ensuresWithQuantifier(n: in Int): Int
  ensures: result == n * 2 and not (forall (i: Int) { i == result })
{
  n * 2
}

func loopWithQuantifiedInvariant(n: in Int): Int {
  var i = 0
  while i < n
    invariant: i >= 0 and not (exists (k: Int) { k == i and k < 0 })
  {
    i = i + 1
  }
  i
}

record Positive {
  value: Int
  invariant: value > 0 and not (exists (k: Int) { k == value and k < 0 })
}

test "a negated quantifier does not fail the precondition" {
  assertTrue(negatedExists(4) == 5, "negatedExists(4)")
  assertTrue(negatedExists(0) == 1, "negatedExists(0)")
}

test "the conjunct next to a quantifier is still checked" {
  assertTrue(conjunctStillChecked(3) == 3, "n = 3 satisfies n > 0")
  assertPanics("n = 0 violates n > 0", { -> val _ = conjunctStillChecked(0) })
}

test "ensures and loop invariants with quantifiers" {
  assertTrue(ensuresWithQuantifier(5) == 10, "ensures with a negated forall")
  assertTrue(loopWithQuantifiedInvariant(3) == 3, "loop invariant with a negated exists")
}

test "a type invariant with a quantifier keeps its other conjuncts" {
  val p = Positive(value = 2)
  assertTrue(p.value == 2, "Positive(2)")
  assertPanics("Positive(0) violates value > 0", { -> val _ = Positive(value = 0) })
}
