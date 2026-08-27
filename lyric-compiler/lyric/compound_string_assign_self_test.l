//! compound_string_assign_self_test.l — runtime regression test for
//! compound-assignment `s += <rhs>` onto a `String` target (#5657, #5688).
//!
//! Before #5657's fix the type checker discarded the assignment operator in
//! `SAssign`, so `s += true` / `s += 3.5` / `s += 42` were all rejected by
//! T0063 (checked as if they were `s = <rhs>`) even though binary `+` already
//! accepts `"" + true` etc.  The fix special-cases `+=` onto a String target
//! to accept any RHS, mirroring binary `+`'s "any operand + String = String".
//! The MSIL/JVM compound-combine codegen was already correct for plain-variable
//! targets, so once the check passes these lower to the same lowercase-Bool /
//! no-trailing-`.0`-Double stringification as `+` (#5552/#4688).
//!
//! #5688 extends the same widening to field (`obj.f += x`) and indexed
//! (`xs[i] += x`) String targets, which #5657 deliberately left strict:
//! their compound-assign codegen inferred the element/field type from the
//! RHS rather than the container's own declared type, so a non-String RHS
//! would have unboxed/cast against the wrong type
//! (`InvalidCastException`/`ClassCastException`).  Both backends now thread
//! the container's real declared type through instead (MSIL: `recvTy`'s own
//! element type; JVM: `indexedElemTypeOverride`, the same resolver the
//! read-path `EIndex` arm uses), so the widening is sound for these shapes
//! too.
//!
//! Run by native `lyric test` on BOTH targets (like `bitwise_self_test.l`):
//!   lyric test --target dotnet lyric-compiler/lyric/compound_string_assign_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/compound_string_assign_self_test.l
//! Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.CompoundStringAssignSelfTest

import Std.Core
import Std.Collections
import Std.String
import Std.Testing

record Box {
  s: String
}

func boolAppend(): String {
  var s = "flag="
  s += true
  s
}

func boolAppendFalse(): String {
  var s = ""
  s += false
  s
}

func doubleAppendFrac(): String {
  var s = "n="
  s += 3.5
  s
}

func doubleAppendWhole(): String {
  var s = "n="
  s += 42.0
  s
}

func intAppend(): String {
  var s = "n="
  s += 42
  s
}

func stringAppend(): String {
  var s = "a"
  s += "b"
  s
}

// ── #5688: record-field String targets ──────────────────────────────────────
func fieldAppendBool(): String {
  val b = Box(s = "flag=")
  b.s += true
  b.s
}

func fieldAppendInt(): String {
  val b = Box(s = "n=")
  b.s += 42
  b.s
}

func fieldAppendDouble(): String {
  val b = Box(s = "n=")
  b.s += 3.5
  b.s
}

func fieldAppendString(): String {
  val b = Box(s = "a")
  b.s += "b"
  b.s
}

// ── #5688: List[String] indexed targets ─────────────────────────────────────
func indexedAppendBool(): String {
  val xs: List[String] = newList()
  xs.add("flag=")
  xs[0] += true
  xs[0]
}

func indexedAppendInt(): String {
  val xs: List[String] = newList()
  xs.add("n=")
  xs[0] += 42
  xs[0]
}

func indexedAppendDouble(): String {
  val xs: List[String] = newList()
  xs.add("n=")
  xs[0] += 3.5
  xs[0]
}

func indexedAppendRecord(): String {
  val xs: List[String] = newList()
  xs.add("box=")
  xs[0] += Box(s = "inner")
  xs[0]
}

func indexedAppendString(): String {
  val xs: List[String] = newList()
  xs.add("a")
  xs[0] += "b"
  xs[0]
}

test "s += Bool stringifies lowercase (#5657)" {
  assertEqual(boolAppend(), "flag=true", "s += true")
  assertEqual(boolAppendFalse(), "false", "s += false")
}

test "s += Double: fraction kept, whole value omits trailing .0 (#4688 parity)" {
  assertEqual(doubleAppendFrac(), "n=3.5", "s += 3.5")
  assertEqual(doubleAppendWhole(), "n=42", "s += 42.0 has no trailing .0")
}

test "s += Int" {
  assertEqual(intAppend(), "n=42", "s += 42")
}

test "s += String (same-type compound append still works)" {
  assertEqual(stringAppend(), "ab", "s += \"b\"")
}

test "obj.f += <non-String> (#5688: field target widening)" {
  assertEqual(fieldAppendBool(), "flag=true", "b.s += true")
  assertEqual(fieldAppendInt(), "n=42", "b.s += 42")
  assertEqual(fieldAppendDouble(), "n=3.5", "b.s += 3.5")
}

test "obj.f += String (#5688: field target same-type regression)" {
  assertEqual(fieldAppendString(), "ab", "b.s += \"b\"")
}

test "xs[i] += <non-String> (#5688: List[String] indexed target widening)" {
  assertEqual(indexedAppendBool(), "flag=true", "xs[0] += true")
  assertEqual(indexedAppendInt(), "n=42", "xs[0] += 42")
  assertEqual(indexedAppendDouble(), "n=3.5", "xs[0] += 3.5")
  // A record RHS's `ToString()`/`toString()` default differs across
  // targets (MSIL: qualified type name; JVM: `ClassName@hash`) — assert
  // only that the real prefix survived the combine, not the exact suffix.
  assertTrue(startsWith(indexedAppendRecord(), "box="), "xs[0] += <record> keeps the container's own prefix")
}

test "xs[i] += String (#5688: List[String] indexed target same-type regression)" {
  assertEqual(indexedAppendString(), "ab", "xs[0] += \"b\"")
}
