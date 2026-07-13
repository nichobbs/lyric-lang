//! list_literal_index_self_test.l — runtime regression test for indexed reads
//! of unannotated list literals (#5620).
//!
//! Before the fix, an unannotated list literal (`val xs = [9, 7]`) with no
//! surrounding type hint lowered on MSIL to a legacy `List<object>` tracked as
//! bare `MObject`; the indexed read `xs[0]` returned the boxed element ref
//! without unboxing, mislabeled as a raw value, so downstream `+`/`println`
//! read it as garbage (a silent miscompile).  The fix builds a genuine
//! `List<e>` when the literal is homogeneous over one concrete element type, so
//! the read recovers the real element type — matching the already-correct
//! annotated `val xs: List[Int] = newList()` path.
//!
//! Runs on `--target dotnet` (the MSIL fix, #5620).  The JVM backend has the
//! same root cause in a separate code path — its EList lowering always builds
//! an untyped `ArrayList` with no element-type tracking, so an unannotated
//! literal's indexed elements erase to `Object` and a relational/arithmetic use
//! panics loudly (not the MSIL silent-garbage flavor).  Fixing that needs
//! element-type tracking in the JVM emitter and is a tracked parity follow-up,
//! so this test is not wired for `--target jvm`.
//!   lyric test --target dotnet lyric-compiler/lyric/list_literal_index_self_test.l
//! Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.ListLiteralIndexSelfTest

import Std.Core
import Std.Testing

func litIndex0(): Int {
  val xs = [9, 7]
  xs[0]
}

func litSum(): Int {
  val xs = [9, 7]
  xs[0] + xs[1]
}

func litCompare(): Bool {
  val xs = [3, 5, 8]
  xs[0] < xs[1] and xs[1] < xs[2]
}

func newListSum(): Int {
  val xs: List[Int] = newList()
  xs.add(9)
  xs.add(7)
  xs[0] + xs[1]
}

func litStrings(): String {
  val xs = ["a", "b"]
  xs[0] + xs[1]
}

func litDoubles(): Bool {
  val xs = [1.5, 2.5]
  xs[0] + xs[1] == 4.0
}

func litBools(): Bool {
  val xs = [true, false]
  xs[0] and not xs[1]
}

func litChars(): Bool {
  val xs = ['a', 'b']
  xs[0] == 'a' and xs[1] == 'b'
}

func litLongs(): Bool {
  // Magnitudes beyond Int32 range infer as Long, so this exercises the MLong
  // element path.
  val xs = [10000000000, 20000000000]
  xs[0] + xs[1] == 30000000000
}

// Element type recovered from a bare local variable, not a syntactic literal
// (the #5690 extension: `[a, b]` builds `List<Int>`, not `List<object>`).
func litVars(): Int {
  val a = 9
  val b = 7
  val xs = [a, b]
  xs[0] + xs[1]
}

test "unannotated Int list literal indexes as Int, not garbage (#5620)" {
  assertEqualInt(litIndex0(), 9, "xs[0] == 9")
  assertEqualInt(litSum(), 16, "xs[0] + xs[1] == 16 (integer add, not object-ref garbage)")
}

test "unannotated Int list literal elements compare as Int" {
  assertTrue(litCompare(), "3 < 5 < 8 over unannotated literal elements")
}

test "annotated newList()+.add baseline stays correct" {
  assertEqualInt(newListSum(), 16, "annotated newList()+.add == 16")
}

test "unannotated String list literal indexes as String" {
  assertEqual(litStrings(), "ab", "xs[0] + xs[1] == \"ab\"")
}

test "unannotated list literals recover Double/Bool/Char/Long element types" {
  assertTrue(litDoubles(), "Double: xs[0] + xs[1] == 4.0")
  assertTrue(litBools(), "Bool: xs[0] and not xs[1]")
  assertTrue(litChars(), "Char: xs[0] == 'a' and xs[1] == 'b'")
  assertTrue(litLongs(), "Long: xs[0] + xs[1] == 30000000000")
}

test "list literal over local variables recovers the element type (#5690)" {
  assertEqualInt(litVars(), 16, "[a, b] with Int locals indexes as Int")
}
