//! return_list_literal_self_test.l — dual-target runtime regression test for
//! D-progress-1026 (#7696): a bracket literal (`[...]`) used directly in
//! return position types (and is built) as `List[T]`, matching every other
//! `List[T]`-expected position D-progress-1025 (#7545) already covered.
//!
//! `typechecker_self_test.l` already pins the CHECKER side of this (zero
//! diagnostics for each return-position form, against a fake
//! `Std.CollectionsHost` package). This file pins the CODEGEN side: it
//! compiles real functions returning list literals through the actual
//! self-hosted MSIL/JVM backends and asserts on the resulting runtime
//! values, so a checker/codegen split (the checker accepting `List[T]` while
//! a backend still built an array/`slice[T]`) would fail here even if it
//! passed every checker-only assertion.
//!
//! Run via native `lyric test` on BOTH targets (mirrors
//! `bitwise_self_test.l`): `--target dotnet` through `Msil.Bridge`,
//! `--target jvm` through `Jvm.Bridge`'s `compileToJarBundled`. Imports only
//! `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ReturnListLiteralSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// Explicit `return [...]`.
// ─────────────────────────────────────────────────────────────────────────────
func viaExplicitReturn(): List[Int] {
  return [1, 2, 3]
}

test "explicit `return [...]` against a List[T] return type builds a genuine List" {
  val xs = viaExplicitReturn()
  assertEqualInt(xs.count, 3, "count")
  assertEqualInt(xs[0], 1, "elem 0")
  assertEqualInt(xs[1], 2, "elem 1")
  assertEqualInt(xs[2], 3, "elem 2")
  // `.add` only exists on the real `List[T]` — if codegen had instead built
  // an array/slice representation here, this call would fail to resolve (or
  // crash at runtime, on a target with no static method-resolution guard).
  xs.add(4)
  assertEqualInt(xs.count, 4, "count after add")
  assertEqualInt(xs[3], 4, "elem 3 after add")
}

// ─────────────────────────────────────────────────────────────────────────────
// A block's trailing/implicit value.
// ─────────────────────────────────────────────────────────────────────────────
func viaTrailingValue(): List[Int] {
  val n = 10;
  [n, 20, 30]
}

test "a block's trailing bracket literal against a List[T] return type builds a genuine List" {
  val xs = viaTrailingValue()
  assertEqualInt(xs.count, 3, "count")
  assertEqualInt(xs[0], 10, "elem 0")
  xs.add(40)
  assertEqualInt(xs.count, 4, "count after add")
}

// ─────────────────────────────────────────────────────────────────────────────
// Expression-bodied function.
// ─────────────────────────────────────────────────────────────────────────────
func viaExprBody(): List[Int] = [7, 8]

test "an expression-bodied function's literal body against a List[T] return type builds a genuine List" {
  val xs = viaExprBody()
  assertEqualInt(xs.count, 2, "count")
  xs.add(9)
  assertEqualInt(xs.count, 3, "count after add")
  assertEqualInt(xs[2], 9, "elem 2 after add")
}

// ─────────────────────────────────────────────────────────────────────────────
// `if`/`match` arms whose value is the function result.
// ─────────────────────────────────────────────────────────────────────────────
func viaIfArm(c: in Bool): List[Int] {
  if c {
    [1, 2, 3]
  } else {
    [4, 5]
  }
}

test "an if-arm's literal against a List[T] return type builds a genuine List (true branch)" {
  val xs = viaIfArm(true)
  assertEqualInt(xs.count, 3, "count")
  xs.add(99)
  assertEqualInt(xs.count, 4, "count after add")
}

test "an if-arm's literal against a List[T] return type builds a genuine List (false branch)" {
  val xs = viaIfArm(false)
  assertEqualInt(xs.count, 2, "count")
  xs.add(99)
  assertEqualInt(xs.count, 3, "count after add")
}

func viaMatchArm(c: in Bool): List[Int] {
  match c {
    case true -> [1, 2, 3]
    case false -> [4, 5]
  }
}

test "a bare-expr match-arm literal against a List[T] return type builds a genuine List" {
  val xs = viaMatchArm(true)
  assertEqualInt(xs.count, 3, "count")
  xs.add(6)
  assertEqualInt(xs.count, 4, "count after add")
  assertEqualInt(xs[3], 6, "elem 3 after add")
}
