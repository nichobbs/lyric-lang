@proof_required
package ProveDemo

// Demonstrates the M4.1 fragment of the Phase 4 verifier.
// Run with:
//
//     lyric prove examples/prove_demo.l --verbose
//
// All four functions discharge via the trivial syntactic checker
// alone (no external solver needed).  When `z3` is on `$PATH` the
// `bumped` and `addsOk` proofs are also handled by Z3 directly.

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
