//! list_literal_index_self_test.l — runtime regression test for indexed reads
//! of unannotated list literals (#5620 MSIL, #5686 JVM parity).
//!
//! Before the MSIL fix, an unannotated list literal (`val xs = [9, 7]`) with no
//! surrounding type hint lowered on MSIL to a legacy `List<object>` tracked as
//! bare `MObject`; the indexed read `xs[0]` returned the boxed element ref
//! without unboxing, mislabeled as a raw value, so downstream `+`/`println`
//! read it as garbage (a silent miscompile).  The fix builds a genuine
//! `List<e>` when the literal is homogeneous over one concrete element type, so
//! the read recovers the real element type — matching the already-correct
//! annotated `val xs: List[Int] = newList()` path.
//!
//! The JVM backend had the same root cause in a separate code path: its
//! `EList` lowering always builds an untyped `ArrayList` with no element-type
//! tracking, so an unannotated literal's indexed elements erased to `Object`
//! and a relational/arithmetic use panicked loudly (not the MSIL
//! silent-garbage flavor).  #5686 fixes this by peeking a homogeneous
//! literal's element type (`inferHomogeneousListElemTypeJvm`,
//! jvm/codegen/02_exprs.l) and recording it against the binding through the
//! same `ctx.varGenericArgs` registry an explicit `List[Int]` annotation
//! already populates, so `indexedElemTypeOverride` narrows the indexed read
//! from erased `Object` to the real element type.  The runtime
//! representation stays a plain `ArrayList` — only the compiler's own type
//! tracking changed.
//! #6782/#6973 addendum: `u16`/`u32`/`u64`-suffixed unannotated list literals
//! hit a THIRD, independent instance of this same defect class on MSIL —
//! `listLiteralElemTypeMsil` had no `U16`/`U32`/`U64` arms, so
//! `[1u16, 2u16]` etc. fell back to the legacy `List<object>` path and
//! `xs[0] + xs[1]` faulted with `InvalidProgramException` (a compile-time-
//! adjacent panic on MSIL, unlike the JVM twin's `#5686`-era `Object`-erasure
//! symptom). `Jvm.Codegen.listLiteralElemTypeJvm` already had the matching
//! fix (`#6741`), exercised by the JVM-only
//! `lyric-compiler/jvm/list_literal_uint_elem_jvm_self_test.l`; the cases
//! below are its MSIL-target regression-test counterpart (`#6782`'s own
//! fix instructions specified BOTH the codegen fix and this test), added
//! here — the established dual-target home for this defect family — rather
//! than widening that JVM-directory file to run cross-target.
//!
//! Runs on both `--target dotnet` and `--target jvm`.
//!   lyric test --target dotnet lyric-compiler/lyric/list_literal_index_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/list_literal_index_self_test.l
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
  // Explicit `i64` suffix so the checker types the literal `slice[Long]` (a
  // bare no-suffix literal is `slice[Int]` regardless of magnitude), exercising
  // the MLong element path.
  val xs = [10000000000i64, 20000000000i64]
  xs[0] + xs[1] == 30000000000i64
}

func litBytes(): Bool {
  // `i8`-suffixed literals are `Byte`, so this must build `Byte[]`, not
  // `Int32[]` (#5703).
  val xs = [1i8, 2i8, 3i8]
  xs[0] + xs[1] + xs[2] == 6i8
}

// Element type recovered from a bare local variable, not a syntactic literal
// (the #5690 extension: `[a, b]` builds `List<Int>`, not `List<object>`).
func litVars(): Int {
  val a = 9
  val b = 7
  val xs = [a, b]
  xs[0] + xs[1]
}

func litU16(): Bool {
  val xs = [1u16, 2u16]
  xs[0] + xs[1] == 3u16
}

func litU32(): Bool {
  val xs = [100000u32, 1u32]
  xs[0] + xs[1] == 100001u32
}

func litU64(): Bool {
  val xs = [1000000000000u64, 1u64]
  xs[0] + xs[1] == 1000000000001u64
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

test "unannotated list literals recover Double/Bool/Char/Long/Byte element types" {
  assertTrue(litDoubles(), "Double: xs[0] + xs[1] == 4.0")
  assertTrue(litBools(), "Bool: xs[0] and not xs[1]")
  assertTrue(litChars(), "Char: xs[0] == 'a' and xs[1] == 'b'")
  assertTrue(litLongs(), "Long (i64): xs[0] + xs[1] == 30000000000")
  assertTrue(litBytes(), "Byte (i8): builds Byte[], not Int32[] (#5703)")
}

test "list literal over local variables recovers the element type (#5690)" {
  assertEqualInt(litVars(), 16, "[a, b] with Int locals indexes as Int")
}

test "unannotated U16/U32/U64 list literal elements infer for indexed arithmetic on MSIL (#6782/#6973)" {
  assertTrue(litU16(), "u16: xs[0] + xs[1] == 3u16")
  assertTrue(litU32(), "u32: xs[0] + xs[1] == 100001u32")
  assertTrue(litU64(), "u64: xs[0] + xs[1] == 1000000000001u64")
}
