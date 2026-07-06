//! slice_append_widening_self_test.l — MSIL-only regression test for
//! `slice[T].append`'s numeric-widening miscompile (#5254).
//!
//! M6 numeric widening (`Int` satisfies `Long`, in `typechecker_exprs.l`'s
//! `argSatisfiesParam`) lets `xs.append(-7)` type-check against a
//! `slice[Long]` receiver. The MSIL lowering's array-backed path pushed the
//! Int32 argument straight into an `Int64[]` `stelem` with no `conv.i8`,
//! silently zero-extending instead of sign-extending — `xs.append(-7)`
//! produced `4294967289`, not `-7`.
//!
//! This is dotnet-only (not wired into the `--target jvm` CI job, unlike
//! `slice_ops_self_test.l`): the JVM backend erases every `slice[T]` to a
//! uniform `Object[]` with no per-array element-type tracking, so a fresh
//! `Int` argument to `.append` on a `slice[Long]` boxes as `Integer` rather
//! than `Long` regardless of the receiver's declared element type — a
//! separate, deeper, pre-existing JVM architecture gap unrelated to this
//! fix, filed as #5257.
@test_module
package Lyric.SliceAppendWideningSelfTest

import Std.Core
import Std.Testing

test "append widens an Int argument to slice[Long]'s element type" {
  val xs: slice[Long] = [1i64, 2i64, 3i64]
  val ys = xs.append(-7)
  assertEqualInt(ys.length, 4, "appended length")
  assertEqualLong(ys[0], 1i64, "element 0 preserved")
  assertEqualLong(ys[3], -7i64, "appended element widened correctly")
}

test "append widens a large-magnitude Int argument to slice[Long]" {
  val xs: slice[Long] = [1i64]
  val ys = xs.append(-2147483000)
  assertEqualLong(ys[1], -2147483000i64, "appended element widened correctly")
}
