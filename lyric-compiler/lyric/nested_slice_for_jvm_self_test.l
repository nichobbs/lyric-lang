//! nested_slice_for_jvm_self_test.l — regression test for the JVM `for`-loop
//! crash on a nested `slice[slice[T]]`/`List[slice[T]]` element (#6541).
//!
//! `for x in outer { for y in x { ... } }` where `x`'s own element type is
//! itself array-shaped used to mis-infer the inner loop variable's type as
//! plain erased `Object` on `--target jvm`, so the inner loop picked the
//! `Iterable`/`iterator()` codegen path against a value that is actually a
//! raw Java array at runtime — `Class [Ljava.lang.Object; does not implement
//! the requested interface java.lang.Iterable`.
//!
//! Runtime-verified here for the ARRAY-outer shape (`slice[slice[Int]]`,
//! `slice[slice[String]]`) — the confirmed real-world repro
//! (`Validation.all`'s `slice[slice[ValidationError]]`).  The primitive-inner
//! cases guard against a naive unconditional `checkcast [Ljava/lang/Object;`
//! (wrong for a genuine `int[]` runtime value — primitive arrays are NOT
//! assignable to `Object[]`).
//!
//! The LIST-outer shape (`List[slice[T]]`) is now also runtime-verified
//! below (`sumNestedListOfSlice`/`concatNestedListOfSlice`): constructing
//! an actual `List[slice[T]]` VALUE on `--target jvm` used to hit two
//! separate, pre-existing bugs unrelated to this fix (`List.add()`'s
//! auto-FFI resolution misfired for an array-typed argument, and a bare
//! slice literal stored through `.add()` became a raw `ArrayList` instead
//! of a real array on read-back), filed and fixed as #6546 (see
//! `lyric-compiler/jvm/list_of_slice_construction_jvm_self_test.l` for the
//! dedicated construction/read-back coverage). The `for`-loop CODE fix here
//! unifies both codegen branches (array-outer and `Iterable`-outer) through
//! the same `emitNormalizeErasedSlice` call so they can't diverge — the
//! cases below exercise the `Iterable`-outer branch at runtime now that
//! #6546 unblocks constructing a value to feed it.
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.  Run via
//! native `lyric test` on both targets (mirrors `bitwise_self_test.l`):
//!   lyric test --target dotnet lyric-compiler/lyric/nested_slice_for_jvm_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/nested_slice_for_jvm_self_test.l
@test_module
package Lyric.NestedSliceForJvmSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// Inner rows are built via a helper CALL (not a nested slice literal
// `[[1,2],[3]]` directly) — a nested slice LITERAL's inner elements hit a
// separate, unrelated construction bug (the inner literal isn't converted
// from `ArrayList` to a real array before being stored into the outer one;
// filed as its own issue, out of scope for #6541's for-LOOP fix this file
// regression-tests).  A slice returned from a function call is the same
// runtime shape `Validation.all`'s real repro exercises (its slice[T]
// arguments are `Validation.required(...)`-style call results, never
// literal-in-literal syntax), so this is the representative shape to test.
func intRow(vals: in slice[Int]): slice[Int] {
  vals
}

func strRow(vals: in slice[String]): slice[String] {
  vals
}

func sumNestedSlice(xs: in slice[slice[Int]]): Int {
  var total = 0
  for row in xs {
    for v in row {
      total = total + v
    }
  }
  total
}

func concatNestedSlice(xs: in slice[slice[String]]): String {
  var acc = ""
  for row in xs {
    for s in row {
      acc = acc + s
    }
  }
  acc
}

func sumNestedListOfSlice(xs: in List[slice[Int]]): Int {
  var total = 0
  for row in xs {
    for v in row {
      total = total + v
    }
  }
  total
}

func concatNestedListOfSlice(xs: in List[slice[String]]): String {
  var acc = ""
  for row in xs {
    for s in row {
      acc = acc + s
    }
  }
  acc
}

test "array-outer, primitive inner: slice[slice[Int]] nested for-loop sums correctly" {
  assertEqualInt(sumNestedSlice([intRow([1, 2, 3]), intRow([4, 5]), intRow([6])]), 21, "sum of nested int slices")
}

test "array-outer, reference inner: slice[slice[String]] nested for-loop concatenates correctly" {
  assertEqual(
    concatNestedSlice([strRow(["a", "b"]), strRow(["c"]), strRow(["d", "e", "f"])]),
    "abcdef",
    "concat of nested string slices"
  )
}

test "array-outer, primitive inner: an empty outer slice short-circuits without touching the inner loop" {
  val empty: slice[slice[Int]] = []
  assertEqualInt(sumNestedSlice(empty), 0, "sum of an empty outer slice is 0")
}

test "array-outer: an inner slice containing an empty slice does not crash" {
  assertEqualInt(sumNestedSlice([intRow([]), intRow([1, 2]), intRow([])]), 3, "sum skips empty inner slices correctly")
}

test "List-outer, primitive inner: List[slice[Int]] nested for-loop sums correctly (#6546)" {
  val xs: List[slice[Int]] = newList()
  xs.add(intRow([1, 2, 3]))
  xs.add(intRow([4, 5]))
  xs.add(intRow([6]))
  assertEqualInt(sumNestedListOfSlice(xs), 21, "sum of a List of int slices")
}

test "List-outer, reference inner: List[slice[String]] nested for-loop concatenates correctly (#6546)" {
  val xs: List[slice[String]] = newList()
  xs.add(strRow(["a", "b"]))
  xs.add(strRow(["c"]))
  xs.add(strRow(["d", "e", "f"]))
  assertEqual(concatNestedListOfSlice(xs), "abcdef", "concat of a List of string slices")
}
