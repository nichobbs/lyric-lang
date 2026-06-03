// loop_invariant_self_test.l — regression coverage for loop `invariant:`
// runtime checking on the self-hosted MSIL target (epic #1470, Band 2 / docs/41
// M7).
//
// A loop `invariant:` clause is lowered by the contract elaborator into an
// `assert(inv)` at the top of the loop body (it fires on entry and at the start
// of each iteration); codegen then drops the now-redundant `SInvariant` marker
// (so codegen's `SInvariant -> {}` is correct, not a gap).  This test pins that
// behaviour, which previously had no native self-test: a holding invariant does
// not interfere, and a violated invariant panics at runtime.
//
// The violation case is observed with a `try`/`catch` *expression* (rather than
// `assertPanics`, whose closure argument hits an unrelated lambda/test-synth
// limitation) — itself exercising the value-producing try/catch fixed in #1823.
//
// Run via native `lyric test --target dotnet`.  Imports only `Std.*`.
//
//   lyric test lyric-compiler/lyric/loop_invariant_self_test.l

@test_module
package Lyric.LoopInvariantSelfTest

import Std.Core
import Std.Testing

// Invariant holds on every iteration → loop runs to completion.
func sumWithHoldingInvariant(): Int {
  var i = 0
  var sum = 0
  while i < 5
    invariant: sum >= 0
    invariant: i <= 5
  {
    sum = sum + i
    i = i + 1
  }
  sum
}

// Invariant `i < 2` is violated once `i` reaches 2 → the elaborated `assert`
// panics; the try/catch captures that as `true`.
func violationIsCaught(): Bool {
  try {
    var i = 0
    while i < 5
      invariant: i < 2
    {
      i = i + 1
    }
    false
  } catch Bug as _ {
    true
  }
}

test "a loop invariant that holds does not interfere with execution" {
  assertEqualInt(sumWithHoldingInvariant(), 10, "0+1+2+3+4")
}

test "a violated loop invariant panics at runtime" {
  assertTrue(violationIsCaught(), "i < 2 invariant violated at i = 2 -> panic caught")
}

