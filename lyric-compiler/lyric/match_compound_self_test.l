//! match_compound_self_test.l — executable regression tests for two
//! self-hosted MSIL backend correctness fixes from #1481 (epic #1470, Band 2):
//!
//!   Item 1 — Float literal *match* patterns.  Previously a `case 1.5 ->`
//!   pattern fell to the `_` wildcard arm in `codegen.l` and `pop`ped the
//!   scrutinee, so EVERY Float literal pattern matched unconditionally.  The
//!   fix emits a real `ldc.r8; ceq` comparison.  (Char/Long/Bool/String
//!   literal patterns already compared correctly; only Float was broken.)
//!
//!   Item 2 — Compound assignment honouring the operator.  Previously
//!   `s += x` on a String emitted a numeric `add` (invalid for object refs),
//!   `r.f op= v` on a record field ignored the operator entirely (stored only
//!   `v`), and `a[i] op= v` hard-failed.  The fix reads the current value,
//!   applies the operator at the target's static type (String `+=` →
//!   `String.Concat`), and stores it back — for local, `result`, field, List
//!   element, and Map value targets.
//!
//! Why this lives here and runs via native `lyric test` (not in
//! `lyric-stdlib/tests/*_tests.l`): those files are compiled by the F#
//! stage-0 emitter, which is on a deletion schedule and is NOT the surface
//! under test here.  `lyric test` synthesises a runnable program from the
//! `test` blocks and compiles it IN-PROCESS through the self-hosted
//! `Msil.Bridge` (lexer → parser → type-checker → mode-checker → codegen →
//! MSIL PE), then executes it and asserts every embedded assertion.  This is
//! the only path that exercises `lyric-compiler/msil/codegen.l`.  Imports only
//! `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
//!
//!   lyric test lyric-compiler/lyric/match_compound_self_test.l
//!
//! JVM parity for these fixes is tracked under epic #1470's JVM-deferral note;
//! this epic targets `--target dotnet`.
@test_module
package Lyric.MatchCompoundSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// Item 1 — Float literal match patterns.
// ─────────────────────────────────────────────────────────────────────────────
func classifyFloat(x: Double): Int {
  match x {
    case 1.5 -> 10
    case 2.5 -> 20
    case _ -> 99
  }
}

test "Float literal patterns compare instead of always-matching" {
  // Before the fix the `case 1.5` arm popped the scrutinee and matched every
  // value, so classifyFloat(2.5) and classifyFloat(3.5) both returned 10.
  assertEqualInt(classifyFloat(1.5), 10, "match 1.5 -> first arm")
  assertEqualInt(classifyFloat(2.5), 20, "match 2.5 -> second arm")
  assertEqualInt(classifyFloat(3.5), 99, "match 3.5 -> wildcard")
}

// ─────────────────────────────────────────────────────────────────────────────
// Item 2 — Compound assignment to a local variable.
// ─────────────────────────────────────────────────────────────────────────────
test "String += concatenates (not numeric add)" {
  var s = "ab"
  s += "cd"
  assertEqual(s, "abcd", "string += once")
  s += "ef"
  assertEqual(s, "abcdef", "string += twice")
}

test "Numeric compound operators on a local honour the operator" {
  var n = 10
  n += 5
  assertEqualInt(n, 15, "n += 5")
  n -= 3
  assertEqualInt(n, 12, "n -= 3")
  n *= 2
  assertEqualInt(n, 24, "n *= 2")
  n /= 4
  assertEqualInt(n, 6, "n /= 4")
  n %= 4
  assertEqualInt(n, 2, "n %= 4")
}

// ─────────────────────────────────────────────────────────────────────────────
// Item 2 — Compound assignment to a record field.
// ─────────────────────────────────────────────────────────────────────────────
record Acc {
  var total: Int
  var note: String
}

test "Compound assignment to a record field honours the operator" {
  var a = Acc(total = 0, note = "x")
  a.total += 7
  a.total += 3
  assertEqualInt(a.total, 10, "field += accumulates")
  a.total *= 2
  assertEqualInt(a.total, 20, "field *=")
  a.total -= 5
  assertEqualInt(a.total, 15, "field -=")
  a.note += "y"
  a.note += "z"
  assertEqual(a.note, "xyz", "field string += concatenates")
}

// ─────────────────────────────────────────────────────────────────────────────
// Item 2 — Compound assignment to a List element and a Map value.
// ─────────────────────────────────────────────────────────────────────────────
// Note on read-back: List[ValueType] elements unbox correctly on read so
// the List[Int] case below asserts the post-write value directly.  Map
// values still erase to `object` (primitive-element-erasure gap #1442), so
// the Map test continues to observe writes via `toString` on the boxed
// element while the underlying unbox lands.  Either way the compound-
// assignment WRITE path under test here is independent of the read path.
test "Compound assignment to a List[Int] element" {
  val xs: List[Int] = newList()
  xs.add(10)
  xs.add(20)
  xs[0] += 5
  xs[1] -= 4
  xs[0] *= 2
  // List[ValueType] elements unbox correctly on read (#1779/#1785), so the
  // numeric result is asserted directly.
  assertEqualInt(xs[0], 30, "list[0] += then *=")
  assertEqualInt(xs[1], 16, "list[1] -=")
}

test "Compound assignment to a List[String] element concatenates" {
  val ss: List[String] = newList()
  ss.add("ab")
  ss[0] += "cd"
  ss[0] += "ef"
  assertEqual(toString(ss[0]), "abcdef", "list string +=")
}

test "Compound assignment to a Map[String, Int] value" {
  val m: Map[String, Int] = newMap()
  m.add("a", 100)
  m["a"] += 23
  m["a"] -= 3
  // Map value reads still erase the element type to `object` (the List unbox
  // of #1785 has no Map analogue yet), so the result is observed via `toString`
  // on the boxed value — a correct, #1481-only observation of the WRITE path.
  assertEqual(toString(m["a"]), "120", "map[a] += then -=")
}
