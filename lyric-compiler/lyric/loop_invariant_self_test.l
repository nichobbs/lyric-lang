//! loop_invariant_self_test.l — regression coverage for loop `invariant:`
//! runtime checking on the self-hosted MSIL target (epic #1470, Band 2 / docs/41
//! M7).
//!
//! A loop `invariant:` clause is lowered by the contract elaborator into an
//! `assert(inv)` at the top of the loop body (it fires on entry and at the start
//! of each iteration); codegen then drops the now-redundant `SInvariant` marker
//! (so codegen's `SInvariant -> {}` is correct, not a gap).  This test pins that
//! behaviour, which previously had no native self-test: a holding invariant does
//! not interfere, and a violated invariant panics at runtime.
//!
//! The violation case is observed with a `try`/`catch` *expression* (rather than
//! `assertPanics`, whose closure argument hits an unrelated lambda/test-synth
//! limitation) — itself exercising the value-producing try/catch fixed in #1823.
//!
//! The invariant is also checked when the loop exits normally (its condition
//! went false or its iterator ran out, including a loop whose body never ran),
//! but not when it exits through `break` (#7224).
//!
//! Run via native `lyric test` on both targets.  Imports only `Std.*`.
//!
//!   lyric test lyric-compiler/lyric/loop_invariant_self_test.l
@test_module
package Lyric.LoopInvariantSelfTest

import Std.Core
import Std.Collections
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

// The invariant fails only in the exit state (i == 3): the top-of-body check
// never sees it, so before #7224 this loop passed silently.
func exitOnlyViolation(): Bool {
  try {
    var i = 0
    while i < 3
      invariant: i < 3
    {
      i = i + 1
    }
    false
  } catch Bug as _ {
    true
  }
}

// A loop whose body never runs must still establish its invariant.
func zeroIterationViolation(): Bool {
  try {
    val i = 5
    while i < 3
      invariant: i < 3
    {
    }
    false
  } catch Bug as _ {
    true
  }
}

// `break` leaves without the exit obligation.
func breakSkipsExitCheck(): Int {
  var i = 0
  while i < 10
    invariant: i < 3
  {
    if i == 2 {
      i = 7
      break
    }
    i = i + 1
  }
  i
}

// An unlabelled `break` inside a nested loop leaves only that loop; the outer
// loop still exits normally, so its exit check runs (and fails, n == 2).
func innerBreakKeepsOuterExitCheck(): Bool {
  try {
    var n = 0
    while n < 2
      invariant: n < 2
    {
      while true {
        break
      }
      n = n + 1
    }
    false
  } catch Bug as _ {
    true
  }
}

// `break outer` from a nested loop leaves the labelled loop, so the outer
// loop's exit check does not run (#7349).
func labelledInnerBreakSkipsOuterExitCheck(): Int {
  var i = 0
  outer: while i < 10
    invariant: i < 3
  {
    while true {
      if i == 2 {
        i = 7
        break outer
      }
      break
    }
    i = i + 1
  }
  i
}

func sumTo(xs: in List[Int]): Int {
  var total = 0
  for x in xs
    invariant: total < 6
  {
    total = total + x
  }
  total
}

func forExitViolation(): Bool {
  val xs: List[Int] = newList()
  xs.add(1)
  xs.add(2)
  xs.add(3)
  try {
    val _ = sumTo(xs)
    false
  } catch Bug as _ {
    true
  }
}

// An invariant over the loop's own element has no meaning after the loop:
// it is checked on every iteration but not on exit (#7381).
func countBelow(n: in Int): Int {
  var count = 0
  for i in 0 ..< n
    invariant: i < n
  {
    count = count + 1
  }
  count
}

// The exit check must not read an outer binding the pattern shadows.
func shadowedElementInvariant(): Int {
  val x = 100
  var total = x
  for x in [1, 2, 3]
    invariant: x < 10
  {
    total = total + x
  }
  total
}

// A clause over outer state is still checked on exit next to one over the
// element.
func mixedClausesExitViolation(): Bool {
  val xs: List[Int] = newList()
  xs.add(1)
  xs.add(2)
  xs.add(3)
  try {
    var total = 0
    for x in xs
      invariant: x > 0
      invariant: total < 6
    {
      total = total + x
    }
    false
  } catch Bug as _ {
    true
  }
}

test "a loop invariant is checked when the condition goes false (#7224)" {
  assertTrue(exitOnlyViolation(), "i < 3 fails only at exit")
}

test "a loop that never runs still checks its invariant (#7224)" {
  assertTrue(zeroIterationViolation(), "i = 5 violates i < 3 on entry")
}

test "break exits the loop without the invariant check (#7224)" {
  assertEqualInt(breakSkipsExitCheck(), 7, "i = 7 after break, no panic")
}

test "an inner break does not suppress the outer loop's exit check (#7224)" {
  assertTrue(innerBreakKeepsOuterExitCheck(), "outer loop exits normally with n == 2")
}

test "a for loop checks its invariant when the iterator runs out (#7224)" {
  assertTrue(forExitViolation(), "total == 6 at exit violates total < 6")
}

test "break outer from a nested loop skips the outer exit check (#7349)" {
  assertEqualInt(labelledInnerBreakSkipsOuterExitCheck(), 7, "i = 7 after break outer, no panic")
}

test "an invariant over the for pattern variable is not re-checked after the loop (#7381)" {
  assertEqualInt(countBelow(4), 4, "i < n holds on every iteration")
  assertEqualInt(countBelow(0), 0, "a loop that never runs has no element to check")
}

test "the exit check does not read an outer binding the pattern shadows (#7381)" {
  assertEqualInt(shadowedElementInvariant(), 106, "outer x = 100 is not checked against x < 10")
}

test "an outer-state clause is still checked on exit beside an element clause (#7381)" {
  assertTrue(mixedClausesExitViolation(), "total == 6 at exit violates total < 6")
}
