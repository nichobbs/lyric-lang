//! module_val_destructure_self_test.l — #7763: a module-level `val` whose
//! pattern destructures binds every name it names.
//!
//! The grammar's `ValDecl` takes a pattern, but the type checker registered a
//! module `val` only when its pattern was a single name: `val (a, b) = (1, 2)`
//! compiled with no error at the declaration and every use of `a`/`b` was an
//! unknown name.  The front end now rewrites an irrefutable destructuring
//! module `val` into one `val` per bound name before checking (a tuple
//! literal element by element, anything else through one private temporary
//! that is evaluated once), so the backends only ever see single-name values.
//!
//! Run via native `lyric test` on both targets.  Imports only `Std.*`.
//!
//!   lyric test lyric-compiler/lyric/module_val_destructure_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/module_val_destructure_self_test.l
@test_module
package Lyric.ModuleValDestructureSelfTest

import Std.Core
import Std.Collections
import Std.Testing

pub record Counter {
  var n: Int
}

func makePair(): (Int, String) {
  (7, "seven")
}

func makeCounters(): (Counter, Counter) {
  (Counter(n = 1), Counter(n = 2))
}

// A tuple literal binds element by element.
val (litA, litB) = (1, "two")

// Anything else is evaluated once and projected.
val (callN, callS) = makePair()

// Nested tuples and wildcards.
val (nestA, (nestB, _)) = (10, (true, "ignored"))

// A tuple annotation types each element.
val (annInt, annLong): (Int, Long) = (1, 2)

// `name @ pattern` binds the whole value and its parts.
val whole @ (first, second) = makeCounters()

// Visibility carries to every bound name.
pub val (pubLo, pubHi): (Int, Int) = (3, 4)

// A later module value may use the names, in declaration order.
val (baseN, _) = makePair()

val derived = baseN + litA

test "a tuple-literal module val binds each element (#7763)" {
  assertEqualInt(litA, 1, "litA")
  assertEqual(litB, "two", "litB")
}

test "a call-initialised module val projects each element (#7763)" {
  assertEqualInt(callN, 7, "callN")
  assertEqual(callS, "seven", "callS")
}

test "nested and wildcard module val patterns bind their names (#7763)" {
  assertEqualInt(nestA, 10, "nestA")
  assertTrue(nestB, "nestB")
}

test "an annotated module val types each element (#7763)" {
  assertEqualInt(annInt, 1, "annInt")
  val big: Long = annLong + 3000000000i64
  assertTrue(big == 3000000002i64, "annLong is a Long")
}

test "an @-binding module val evaluates its initializer once (#7763)" {
  assertEqualInt(first.n, 1, "first")
  assertEqualInt(second.n, 2, "second")
  first.n = 5
  val wholeFirst = match whole { case (w, _) -> w.n }
  assertEqualInt(wholeFirst, 5, "whole shares first's object")
}

test "a pub destructuring module val binds pub names (#7763)" {
  assertEqualInt(pubLo + pubHi, 7, "pubLo + pubHi")
}

test "a later module val reads destructured names (#7763)" {
  assertEqualInt(derived, 8, "baseN + litA")
}
