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
