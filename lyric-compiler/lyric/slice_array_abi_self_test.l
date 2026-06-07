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
