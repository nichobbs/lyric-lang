@proof_required
package ProveDemo

// Demonstrates the Phase 4 verifier (M4.1 / M4.2 fragment).
// Run with:
//
//     lyric prove examples/prove_demo.l --verbose
//
// Simple identity / tautology goals discharge via the trivial
// syntactic checker alone (no external solver needed).  Arithmetic
// goals (`bumped`, `addsOk`, `makeAmount`) require Z3 and are marked
// Unknown when no solver is available — pass `--allow-unverified` to
// suppress V0007 errors in that case.  `absish` (disjunctive post on
// a match) may remain Unknown even with Z3.

pub func id(x: Int): Int
  ensures: result == x
  = x

pub func tautology(): Bool
  ensures: result == true
  = true

pub func bumped(x: Int): Int
  requires: x >= 0
  ensures: result > x
  = x + 1

pub func wrappedId(x: Int): Int
  ensures: result == x
{
  return id(x)
}

pub func addsOk(a: Int range 0 ..= 100, b: Int range 0 ..= 100): Int
  ensures: result >= 0
  = a + b

// `assert φ` in body: φ becomes a side-goal *and* is added to the
// assumed hypotheses for the rest of the block (Hoare encoding).
pub func usingAssert(x: Int): Int
  ensures: result == x
{
  assert(x == x)
  return x
}

// `match` over literal + bare-binding patterns.  `case n` always
// matches; the `result == x or result == 0` post follows by case
// analysis.
pub func absish(x: Int): Int
  ensures: result == x or result == 0
  = match x {
      case 0 -> 0
      case n -> n
    }

// Decision 3a / 4a: loop with an `invariant:` clause and a `var`
// counter.  The wp emits establish + preserve + post sub-goals;
// the var-mutation flows through forward env-substitution; the
// post-loop env havoc's `i` so the conclude wp uses a fresh
// `i$loopout` constrained only by `i >= 0` and `not (i < 10)`.
pub func sumZero(): Int
  ensures: result >= 0
{
  var i: Int = 0
  while i < 10
    invariant: i >= 0
  {
    i = i + 1
  }
  return i
}

// Decision 1c / 2: record construction + field access reasoning.
// `Amount` is encoded as an SMT-LIB datatype `(declare-datatypes
// ((Amount 0)) (((Amount (value Int)))))`; the post-condition
// reduces to a structural identity Z3 closes immediately.
pub record Amount { value: Int }

pub func makeAmount(c: Int): Amount
  requires: c > 0
  ensures: result.value == c
{
  return Amount(value = c)
}
