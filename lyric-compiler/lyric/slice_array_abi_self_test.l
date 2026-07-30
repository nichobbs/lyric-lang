//! slice_array_abi_self_test.l — regression test for the cross-emitter slice
//! ABI fork (#2592): a self-hosted-compiled caller must be able to hand a
//! `slice[T]` literal to an F#-compiled, genuinely array-based stdlib function
//! and have it bind as a real CLR `T[]`.
//!
//! `Lyric.Stdlib.dll` is built by the F# stage-0 emitter, which lowers a
//! `slice[T]` parameter to a real `T[]` array (`TypeMap.fs` `MakeArrayType()`).
//! Before the fix, the self-hosted emitter built a `slice[T]` literal as a
//! `List`-backed value and passed it to e.g. `Std.Core.sumInts(Int[])`; the
//! array-based F# body then operated on the wrong representation (wrong result
//! or fault).  The fix (codegen.l `EList` `MArray` arm) builds a slice literal
//! in a slice-typed context as a genuine `T[]` via `newarr` + `stelem`, so the
//! call binds correctly.
//!
//! These functions (`Std.Core.sumInts`/`maxInt`/`countEq`, `Std.String.join`)
//! are part of the bootstrap smoke set, so they ship inside the F#-built
//! stdlib and exercise the exact same array boundary as the `Std.Sort.*`
//! functions named in #2592 (which are not built into the bootstrap toolchain).
//!
//! Run via the native `lyric test`, which compiles this module in-process
//! through the self-hosted `Msil.Bridge` and links the F#-built stdlib DLLs:
//!
//!   lyric test lyric-compiler/lyric/slice_array_abi_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.SliceArrayAbiSelfTest

import Std.Core
import Std.String as Str
import Std.Testing

test "Int slice literal binds as Int[] across the F# stdlib boundary" {
  // sumInts iterates a real Int[] in the F#-built stdlib.  A List-backed
  // argument would sum wrong / fault; a genuine Int[] sums correctly.
  assertEqualInt(sumInts([1, 2, 3, 4]), 10, "sumInts([1,2,3,4]) == 10")
  assertEqualInt(sumInts([]), 0, "sumInts([]) == 0")
  assertEqualInt(sumInts([42]), 42, "sumInts([42]) == 42")
}

test "Int slice literal indexes correctly via maxInt" {
  assertEqualInt(maxInt([3, 9, 2, 7]), 9, "maxInt([3,9,2,7]) == 9")
  assertEqualInt(maxInt([5]), 5, "maxInt([5]) == 5")
}

test "Int slice literal element scan via countEq" {
  assertEqualInt(countEq([1, 2, 2, 3, 2], 2), 3, "countEq(.., 2) == 3")
  assertEqualInt(countEq([1, 2, 3], 9), 0, "countEq(.., 9) == 0")
}

test "String slice literal binds as String[] across the F# stdlib boundary" {
  assertTrue(Str.join(",", ["a", "b", "c"]) == "a,b,c", "join produces a,b,c")
  assertTrue(Str.join("-", ["x"]) == "x", "join single element")
}

// ── #2623: uncovered element-type branches in arrayElemTokenOpt ───────────────
// Each of the following exercises a branch of `arrayElemTokenOpt` not covered
// by the Int/String cases above.  Pure-Lyric helper functions (no F# stdlib
// boundary needed) verify the correct representation by reading elements back.
func sumLongSlice(xs: in slice[Long]): Long {
  var acc = 0i64
  var i = 0
  while i < xs.count {
    acc = acc + xs[i]
    i = i + 1
  }
  acc
}

func sumDoubleSlice(xs: in slice[Double]): Double {
  var acc = 0.0
  var i = 0
  while i < xs.count {
    acc = acc + xs[i]
    i = i + 1
  }
  acc
}

func countTrueSlice(xs: in slice[Bool]): Int {
  var c = 0
  var i = 0
  while i < xs.count {
    if xs[i] {
      c = c + 1
    }
    i = i + 1
  }
  c
}

func sumCharCodesSlice(xs: in slice[Char]): Int {
  var acc = 0
  var i = 0
  while i < xs.count {
    acc = acc + xs[i].toInt()
    i = i + 1
  }
  acc
}

func sumByteSlice(xs: in slice[Byte]): Int {
  var acc = 0
  var i = 0
  while i < xs.count {
    acc = acc + xs[i].toInt()
    i = i + 1
  }
  acc
}

test "Long slice literal builds as genuine Long[] (arrayElemTokenOpt MLong branch)" {
  assertTrue(sumLongSlice([10i64, 20i64, 30i64]) == 60i64, "sumLong([10,20,30]) == 60L")
  assertTrue(sumLongSlice([]) == 0i64, "sumLong([]) == 0L")
}

test "Double slice literal builds as genuine Double[] (arrayElemTokenOpt MDouble branch)" {
  assertTrue(sumDoubleSlice([1.5, 2.5, 3.0]) == 7.0, "sumDouble([1.5,2.5,3.0]) == 7.0")
}

test "Bool slice literal builds as genuine Bool[] (arrayElemTokenOpt MBool branch)" {
  assertEqualInt(countTrueSlice([true, false, true, true]), 3, "countTrue == 3")
  assertEqualInt(countTrueSlice([false, false]), 0, "countTrue == 0")
}

test "Char slice literal builds as genuine Char[] (arrayElemTokenOpt MChar branch)" {
  // 'A'=65, 'B'=66 => sum=131
  assertEqualInt(sumCharCodesSlice([65.toChar(), 66.toChar()]), 131, "sumCharCodes == 131")
}

test "Byte slice literal builds as genuine Byte[] (arrayElemTokenOpt MByte branch)" {
  assertEqualInt(sumByteSlice([10.toByte(), 20.toByte(), 30.toByte()]), 60, "sumByte == 60")
}

// ── #5563 item 1: `slice[Char]` writes fail strict ILVerify ──────────────────
// Every element-write site that builds/mutates a genuine `Char[]` (array
// literal, `.append`, a hoisted `var` cell) emitted a generic `stelem <System.
// Char>` (`MStelem`) paired with the `ldc.i4` a `Char` literal pushes.  The CLR
// JIT tolerates the mismatch at runtime (Char and Int32 share a verification-
// friendly bit pattern), so these bugs were invisible to a plain `dotnet exec`
// run — only `ilverify` catches them (`StackUnexpected [found Char]`).  The
// fix routes a `Char` element through the token-less `stelem.i2` opcode
// instead, matching the existing `MLdelemU2` char-array read.  These tests
// assert the (unaffected) runtime values; `scripts/ilverify-selfhosted.sh`
// (or a direct `ilverify` run against the emitted DLL) is what actually
// catches a regression here — a bare `dotnet exec`/`lyric test` pass does not.
func firstCharCode(xs: in slice[Char]): Int {
  xs[0].toInt()
}

test "Char slice literal element write (EList MArray branch, #5563)" {
  val cs: slice[Char] = ['a', 'b', 'c']
  assertEqualInt(cs.count, 3, "3-element Char slice")
  assertEqualInt(firstCharCode(cs), 97, "cs[0] == 'a' (97)")
}

test "slice[Char].append builds a new Char[] via stelem (#5563)" {
  val cs: slice[Char] = ['x', 'y']
  val cs2 = cs.append('z')
  assertEqualInt(cs2.count, 3, "appended slice has 3 elements")
  assertEqualInt(cs2[0].toInt(), 120, "cs2[0] == 'x'")
  assertEqualInt(cs2[2].toInt(), 122, "cs2[2] == 'z' (appended element)")
}

func mutateHoistedChar(): Int {
  var c = 'a'
  val bump = { -> c = 'b' }
  bump()
  c.toInt()
}

test "hoisted `var: Char` reassigned from a closure (finishHoistedCellMsil/emitCellAssignMsil, #5563)" {
  assertEqualInt(mutateHoistedChar(), 98, "hoisted Char cell reassigned to 'b' (98)")
}

// ── #6322: slice[record].append local reassignment survives OSR promotion ──
// A record element type has no array token (`arrayElemTokenOpt` -> `None`
// above), so `slice[record]` codegen always falls back to a boxed
// `List<object>` runtime instance — but the LOCAL's LocalVarSig entry was
// still unconditionally encoded as SZARRAY<record>, disagreeing with the
// actual stored `List<object>` value.  The tolerant tier-0 quick JIT
// tolerated the mismatch; OSR promotion of a long-running loop (or the
// optimizing JIT under `DOTNET_TieredCompilation=0`) miscompiled the store
// (OverflowException / AccessViolation / "COM is not supported").  A loop
// long enough to trigger OSR promotion reproduces this deterministically
// even under default tiering.
record PlanItem6322 {
  note: String
  status: String
}

func appendPlanItemsLoop(total: in Int): Int {
  var acc: slice[PlanItem6322] = []
  var i = 0
  while i < total {
    acc = acc.append(PlanItem6322(note = "hit", status = "pending"))
    i = i + 1
  }
  acc.length.toInt()
}

test "#6322: slice[record] local survives many .append reassignments (OSR promotion)" {
  assertEqualInt(appendPlanItemsLoop(50000), 50000, "50000 record appends land in a 50000-length slice")
}

// ── #6332: slice[record] as a RECORD FIELD / function PARAMETER or RETURN —
// the same LocalVarSig-vs-runtime-value mismatch #6322 fixed for locals, but
// in the FieldSig / MethodDef signature builders instead. A `slice[Record]`
// field/param/return still encoded SZARRAY<Record> while the actual runtime
// value is the boxed `List<object>` fallback (record elements have no array
// token — `arrayElemTokenOpt` -> `None`, same root cause as #6322).
// Deterministic under `DOTNET_TieredCompilation=0` (verified manually against
// the built assembly — `field.count`/`param+return.count` read as garbage /
// threw `IndexOutOfRangeException` before this fix, both fixed after it).
// These tests assert value correctness under default tiering; the loop in
// `exerciseFieldParamReturn6332` calls the small helpers below enough times
// to promote them via call-count tiering, exercising the same crash class
// under the harness's own default-tiering run (mirroring how #6322's
// OSR-triggering loop exercises its local-variable case above).
record Item6332 {
  note: String
}

record Holder6332 {
  items: slice[Item6332]
}

func makeHolder6332(n: in Int): Holder6332 {
  var acc: slice[Item6332] = []
  acc = acc.append(Item6332(note = "item" + n.toString()))
  Holder6332(items = acc)
}

func passThrough6332(xs: in slice[Item6332]): slice[Item6332] {
  var acc: slice[Item6332] = []
  var i = 0
  while i < xs.count {
    acc = acc.append(xs[i])
    i = i + 1
  }
  acc
}

func exerciseFieldParamReturn6332(total: in Int): Int {
  var lastCount = 0
  var i = 0
  while i < total {
    val h = makeHolder6332(i)
    val ys = passThrough6332(h.items)
    lastCount = ys.count
    i = i + 1
  }
  lastCount
}

test "#6332: slice[record] record field round-trips through construction and read" {
  val h = makeHolder6332(1)
  assertEqualInt(h.items.count, 1, "Holder6332.items has one element")
  assertEqual(h.items[0].note, "item1", "Holder6332.items[0].note")
}

test "#6332: slice[record] function parameter and return type round-trip" {
  val h = makeHolder6332(2)
  val ys = passThrough6332(h.items)
  assertEqualInt(ys.count, 1, "passThrough6332 returns a 1-element slice")
  assertEqual(ys[0].note, "item2", "passThrough6332[0].note")
}

test "#6332: slice[record] field/param/return survive many calls (call-count tiering)" {
  assertEqualInt(exerciseFieldParamReturn6332(50000), 1, "50000 construct+field-read+param/return round-trips")
}
