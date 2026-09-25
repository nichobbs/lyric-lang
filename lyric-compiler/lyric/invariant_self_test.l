//! invariant_self_test.l — runtime regression test for record and opaque-type
//! `invariant:` clauses (#7222).
//!
//! Before the fix, `invariant:` on a `record` or `opaque type` was parsed and
//! dropped: every backend's `RMInvariant`/`OMInvariant` arm was empty, so a
//! value violating its type's invariant was constructed without complaint.
//! Each such type now gets a construction checker synthesized in its package
//! (`__lyric_checked_<Type>`), and every construction the type checker sees —
//! a constructor call or a `.copy(...)` — is routed through it.
//!
//! Run by the native `lyric test` on BOTH targets:
//!   lyric test --target dotnet lyric-compiler/lyric/invariant_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/invariant_self_test.l
//! Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.InvariantSelfTest

import Std.Core
import Std.Testing

record Range {
  lo: Int
  hi: Int
  invariant: lo <= hi
}

record Percent {
  value: Int = 50
  invariant: value >= 0 and value <= 100
}

@pure
func isLower(s: in String): Bool {
  s == s.toLower()
}

record Tag {
  name: String
  invariant: name.length > 0
  invariant: isLower(name)
}

record Tagged[T] {
  label: String
  item: T
  invariant: label.length > 0
}

opaque type Money {
  cents: Long
  invariant: cents >= 0
}

func money(cents: in Long): Money {
  Money(cents = cents)
}

func moneyCents(m: in Money): Long {
  m.cents
}

func span(r: in Range): Int {
  r.hi - r.lo
}

test "a construction satisfying the invariant succeeds" {
  assertEqualInt(span(Range(lo = 1, hi = 4)), 3, "valid range")
  assertEqualInt(Percent().value, 50, "default field value satisfies the invariant")
  assertEqual(Tag(name = "ok").name, "ok", "every invariant clause holds")
}

test "a construction violating the invariant panics with InvariantViolated" {
  assertPanicsWith(
    "lo > hi",
    "InvariantViolated: Lyric.InvariantSelfTest.Range invariant lo <= hi",
    { -> val _ = span(Range(lo = 5, hi = 1)) }
  )
}

test "each invariant clause is checked" {
  assertPanicsWith("empty name", "invariant name.length > 0", { -> val _ = Tag(name = "") })
  assertPanicsWith("upper-case name", "invariant isLower(name)", { -> val _ = Tag(name = "Up") })
}

test "a copy that breaks the invariant panics" {
  val p = Percent(value = 10)
  assertEqualInt(p.copy(value = 90).value, 90, "valid copy")
  assertPanics("copy out of range", { -> val _ = p.copy(value = 101) })
}

test "a generic record's invariant is checked" {
  assertEqualInt(Tagged(label = "n", item = 7).item, 7, "valid generic construction")
  assertPanics("empty label", { -> val _ = Tagged(label = "", item = 7) })
}

test "an opaque type's invariant is checked at its constructor" {
  assertEqualLong(moneyCents(money(250i64)), 250i64, "valid money")
  assertPanicsWith("negative money", "InvariantViolated: Lyric.InvariantSelfTest.Money", { -> val _ = money(-1i64) })
}

test "a construction nested in an expression is checked" {
  val bad = true
  assertPanics(
    "construction inside a match arm",
    { ->
      val r = match bad { case true -> Range(lo = 2, hi = 0); case false -> Range(lo = 0, hi = 2) }
      val _ = span(r)
    }
  )
}
