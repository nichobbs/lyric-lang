//! slice_ops_self_test.l — runtime regression test for `slice[T]`'s
//! non-mutating ops: `.append`/`.concat`/`.slice` (#5244).
//!
//! Before this fix, calling any of the three on ANY element type, on EITHER
//! build target, threw "unsupported method '<name>' on the receiver type at
//! this call site" at runtime (MSIL) or silently mis-stacked bytecode that
//! failed class verification (JVM) — despite `lyric build` succeeding, since
//! the type checker had no real signature for these calls and let them
//! through as an unvalidated `TyError`.  This is the exact repro from the
//! issue: `docs/agent/reference.md`'s own canonical `slice[T]` example.
//!
//! Run via native `lyric test` (both targets); imports only `Std.*`, so no
//! `LYRIC_LOAD_COMPILER=1` is needed, mirroring `bitwise_self_test.l`.
@test_module
package Lyric.SliceOpsSelfTest

import Std.Core
import Std.Testing

record Pair {
  a: Int
  b: String
}

// ─────────────────────────────────────────────────────────────────────────────
// .append
// ─────────────────────────────────────────────────────────────────────────────
test "append grows an empty slice[Int]" {
  val xs: slice[Int] = []
  val ys = xs.append(42)
  assertEqualInt(xs.length, 0, "original slice untouched")
  assertEqualInt(ys.length, 1, "appended length")
  assertEqualInt(ys[0], 42, "appended element")
}

test "append grows a non-empty slice[Int]" {
  // The issue's exact repro (docs/agent/reference.md's canonical example).
  val dynamic: slice[Int] = [1, 2, 3]
  val ys = dynamic.append(42)
  assertEqualInt(dynamic.length, 3, "original slice untouched")
  assertEqualInt(ys.length, 4, "appended length")
  assertEqualInt(ys[0], 1, "element 0 preserved")
  assertEqualInt(ys[1], 2, "element 1 preserved")
  assertEqualInt(ys[2], 3, "element 2 preserved")
  assertEqualInt(ys[3], 42, "appended element")
}

test "append on slice[String]" {
  val xs: slice[String] = ["a", "b"]
  val ys = xs.append("c")
  assertEqualInt(ys.length, 3, "appended length")
  assertEqual(ys[0], "a", "element 0")
  assertEqual(ys[1], "b", "element 1")
  assertEqual(ys[2], "c", "appended element")
}

test "append on slice[Pair] (record element type)" {
  // On MSIL this exercises the `List<object>`-backed fallback path (a
  // record element type has no `arrayElemTokenOpt` array token); on JVM
  // every slice is uniformly `Object[]`, so this is the same path as the
  // primitive cases above — asserted here regardless.
  val xs: slice[Pair] = [Pair(a = 1, b = "x"), Pair(a = 2, b = "y")]
  val ys = xs.append(Pair(a = 3, b = "z"))
  assertEqualInt(ys.length, 3, "appended length")
  // Bind each indexed read to an explicitly-typed local before field access:
  // an indexed read off an `Object[]`-erased slice (JVM's uniform slice
  // representation) is untyped `Object` until narrowed, and a `val name: T
  // = ...` binding is what triggers that narrowing cast — chaining
  // `ys[i].field` directly hits an unrelated, pre-existing JVM
  // indexing/field-access gap unrelated to this fix.
  val e0: Pair = ys[0]
  val e1: Pair = ys[1]
  val e2: Pair = ys[2]
  assertEqualInt(e0.a, 1, "element 0 .a")
  assertEqual(e0.b, "x", "element 0 .b")
  assertEqualInt(e1.a, 2, "element 1 .a")
  assertEqual(e1.b, "y", "element 1 .b")
  assertEqualInt(e2.a, 3, "appended element .a")
  assertEqual(e2.b, "z", "appended element .b")
}

// ─────────────────────────────────────────────────────────────────────────────
// .concat
// ─────────────────────────────────────────────────────────────────────────────
test "concat of two non-empty slices" {
  val xs: slice[Int] = [1, 2, 3]
  val ys: slice[Int] = [4, 5]
  val zs = xs.concat(ys)
  assertEqualInt(zs.length, 5, "concatenated length")
  assertEqualInt(zs[0], 1, "element 0")
  assertEqualInt(zs[1], 2, "element 1")
  assertEqualInt(zs[2], 3, "element 2")
  assertEqualInt(zs[3], 4, "element 3")
  assertEqualInt(zs[4], 5, "element 4")
}

test "concat with an empty operand" {
  val xs: slice[Int] = [1, 2, 3]
  val empty: slice[Int] = []
  val leftEmpty = empty.concat(xs)
  val rightEmpty = xs.concat(empty)
  assertEqualInt(leftEmpty.length, 3, "empty.concat(xs) length")
  assertEqualInt(leftEmpty[0], 1, "empty.concat(xs)[0]")
  assertEqualInt(rightEmpty.length, 3, "xs.concat(empty) length")
  assertEqualInt(rightEmpty[2], 3, "xs.concat(empty)[2]")
}

// ─────────────────────────────────────────────────────────────────────────────
// .slice
// ─────────────────────────────────────────────────────────────────────────────
test "slice of a middle sub-range" {
  val xs: slice[Int] = [10, 20, 30, 40, 50]
  val sub = xs.slice(1, 3)
  assertEqualInt(sub.length, 2, "sub-range length")
  assertEqualInt(sub[0], 20, "sub-range element 0")
  assertEqualInt(sub[1], 30, "sub-range element 1")
}

test "slice of the full range" {
  val xs: slice[Int] = [1, 2, 3]
  val full = xs.slice(0, 3)
  assertEqualInt(full.length, 3, "full range length")
  assertEqualInt(full[0], 1, "full range element 0")
  assertEqualInt(full[1], 2, "full range element 1")
  assertEqualInt(full[2], 3, "full range element 2")
}

test "slice of an empty range" {
  val xs: slice[Int] = [1, 2, 3]
  val empty = xs.slice(1, 1)
  assertEqualInt(empty.length, 0, "empty range length")
}

// ─────────────────────────────────────────────────────────────────────────────
// Chained / composed usage
// ─────────────────────────────────────────────────────────────────────────────
test "append, concat, and slice compose" {
  val xs: slice[Int] = [1, 2]
  val appended = xs.append(3)
  val concatenated = appended.concat([4, 5])
  val sub = concatenated.slice(1, 4)
  assertEqualInt(sub.length, 3, "composed length")
  assertEqualInt(sub[0], 2, "composed element 0")
  assertEqualInt(sub[1], 3, "composed element 1")
  assertEqualInt(sub[2], 4, "composed element 2")
}
