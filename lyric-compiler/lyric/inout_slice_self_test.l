//! inout_slice_self_test.l — runtime regression test for #5842: an `inout
//! slice[Int]` parameter miscompiled on MSIL with `System.InvalidCastException:
//! Unable to cast object of type 'System.Int32[]' to type
//! 'System.Collections.Generic.List`1[System.Object]'`.
//!
//! Root cause: `slice[T]` values with a primitive/String element are encoded
//! as a genuine CLR `T[]` array (`Msil.Codegen`'s `EList` slice-context and
//! homogeneous-literal paths, #2592/#5620) — the static MSIL type of every
//! `slice[T]` is `MArray`.  The indexed-assignment codegen (`EIndex` on the
//! LHS of `=`, and its compound-assignment sibling) dispatched on the
//! receiver's tracked type but had cases only for `Map`/`ConcreteMap`/
//! `ConcreteList` — any other receiver, including a genuine `MArray`, fell
//! through to the legacy default: `castclass List<object>` +
//! `List<object>::set_Item`.  That cast faults on a real array.  `inout`
//! surfaced it because a swap body (`xs[i] = xs[j]`) writes through the
//! parameter directly; `Std.Sort`'s own `slice[T]` writes happened to avoid
//! this exact shape.
//!
//! Fix: `emitListSetItem` (and the two indexed-store call sites, the plain
//! `AssEq` arm and the compound-assignment arm) gained an `MArray` case that
//! stores through the non-generic `IList.set_Item(int32, object)` — mirroring
//! the pre-existing `MArray` read-side arms (`emitListGetItem`,
//! `emitListCastRecv`) that already route through `IList` because both
//! `System.Array` and `List<T>` implement it.  This is element-type-agnostic:
//! it fixes writes to a genuine array (Int/Long/Byte/String slice literals)
//! and continues to work for a `List`-backed slice value (any element type
//! whose literal can't build a real array, e.g. a record) exactly as before.
//!
//! A slice is never written in place (docs/01 §2.7, T0157), so the swaps
//! below rebind the `inout` parameter to a new slice; the caller must see the
//! new slice after the call, for a value element of three widths (`Int`,
//! `Long`, `Byte`) and a reference element (`String`).
//!
//! Run by the native `lyric test` on BOTH targets (like `block_shadow_self_test.l`):
//!   lyric test --target dotnet lyric-compiler/lyric/inout_slice_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/inout_slice_self_test.l
//! `lyric test` synthesises a program from the `test` blocks and compiles it
//! in-process through the self-hosted `Msil.Bridge` / `Jvm.Bridge`, then
//! asserts every embedded value.  Imports only `Std.*` (no
//! `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.InoutSliceSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// `inout slice[T]` callees: each reads the caller's slice and rebinds the
// parameter to a new one with two elements exchanged, so the caller must
// observe the rebinding after the call returns.
// ─────────────────────────────────────────────────────────────────────────────
func swapped[T](xs: in slice[T], i: Int, j: Int): slice[T] {
  val acc: List[T] = newList()
  var k = 0
  while k < xs.length {
    if k == i {
      acc.add(xs[j])
    } else if k == j {
      acc.add(xs[i])
    } else {
      acc.add(xs[k])
    }
    k += 1
  }
  acc.toArray()
}

func swapIntSlice(xs: inout slice[Int], i: Int, j: Int) {
  xs = swapped(xs, i, j)
}

func swapLongSlice(xs: inout slice[Long], i: Int, j: Int) {
  xs = swapped(xs, i, j)
}

func swapByteSlice(xs: inout slice[Byte], i: Int, j: Int) {
  xs = swapped(xs, i, j)
}

func swapStringSlice(xs: inout slice[String], i: Int, j: Int) {
  xs = swapped(xs, i, j)
}

// #5842's exact repro shape: a bare, unannotated `var` list literal of `Int`
// (the codegen path that materializes the CLI array `int32[]`, #5620) passed
// to an `inout slice[Int]` parameter.
test "inout slice[Int] swap rebinds the caller's slice (#5842)" {
  var xs = [10, 20, 30]
  swapIntSlice(xs, 0, 2)
  assertEqualInt(xs[0], 30, "xs[0] after swap")
  assertEqualInt(xs[1], 20, "xs[1] unchanged")
  assertEqualInt(xs[2], 10, "xs[2] after swap")
}

// A second value-element width, explicitly annotated so the local's tracked
// MSIL type is unambiguously `MArray(MLong)` — proves the fix is not
// special-cased to `Int`.
test "inout slice[Long] swap rebinds the caller's slice" {
  var xs: slice[Long] = [100i64, 200i64, 300i64]
  swapLongSlice(xs, 0, 2)
  assertEqualLong(xs[0], 300i64, "xs[0] after swap")
  assertEqualLong(xs[1], 200i64, "xs[1] unchanged")
  assertEqualLong(xs[2], 100i64, "xs[2] after swap")
}

// `Byte` elements are the narrowest value-typed representation (unsigned
// 0..255, `docs/59` §4.3) and round through `.toByte()`/`.toInt()` — another
// distinct element width from `Int`/`Long`.
test "inout slice[Byte] swap rebinds the caller's slice" {
  var xs: slice[Byte] = [10.toByte(), 20.toByte(), 30.toByte()]
  swapByteSlice(xs, 0, 2)
  assertEqualInt(xs[0].toInt(), 30, "xs[0] after swap")
  assertEqualInt(xs[1].toInt(), 20, "xs[1] unchanged")
  assertEqualInt(xs[2].toInt(), 10, "xs[2] after swap")
}

// Reference-element case (#5842 requires proof the fix covers String/record
// refs, not just value types): `String` is a genuine CLR reference type, and
// a homogeneous `String` slice literal also materializes as a real
// `System.String[]` array.
test "inout slice[String] (reference element) swap rebinds the caller's slice" {
  var xs = ["alpha", "beta", "gamma"]
  swapStringSlice(xs, 0, 2)
  assertEqual(xs[0], "gamma", "xs[0] after swap")
  assertEqual(xs[1], "beta", "xs[1] unchanged")
  assertEqual(xs[2], "alpha", "xs[2] after swap")
}
