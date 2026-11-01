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
import Std.Collections

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

// #8570: one `and` clause over two slice fields of an opaque type.
opaque type SpanIds {
  traceId: slice[Byte]
  spanId: slice[Byte]
  kind: Int
  invariant: traceId.length == 16 and spanId.length == 8
}

func zeroBytes(n: in Int): slice[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < n {
    acc.add(0u8)
    i = i + 1
  }
  acc.toArray()
}

func spanIds(traceLen: in Int, spanLen: in Int): SpanIds {
  SpanIds(traceId = zeroBytes(traceLen), spanId = zeroBytes(spanLen), kind = 1)
}

func spanIdsTotal(ids: in SpanIds): Int {
  ids.traceId.length + ids.spanId.length + ids.kind
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

test "an opaque type's combined invariant over two slice fields is checked (#8570)" {
  assertEqualInt(spanIdsTotal(spanIds(16, 8)), 25, "valid ids")
  assertPanicsWith(
    "short trace id",
    "invariant traceId.length == 16 and spanId.length == 8",
    { -> val _ = spanIds(15, 8) }
  )
  assertPanics("short span id", { -> val _ = spanIds(16, 7) })
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

protected type Stock {
  var level: Int = 5
  invariant: level >= 0
  entry add(n: in Int): Unit {
    level = level + n
  }
  func take(n: in Int): Int {
    level = level - n
    level
  }
  func peek(): Int = level
}

test "a protected func keeps the type invariant (#7529)" {
  val s = Stock()
  assertEqualInt(s.take(2), 3, "a func that keeps the invariant returns")
  assertEqualInt(s.peek(), 3, "state after the func")
  assertPanicsWith("over-draw", "InvariantViolated: Lyric.InvariantSelfTest.Stock", { -> val _ = s.take(10) })
}

test "a protected entry still keeps the type invariant (#7529)" {
  val s = Stock()
  assertPanics("entry driving the level negative", { -> s.add(-9) })
}
