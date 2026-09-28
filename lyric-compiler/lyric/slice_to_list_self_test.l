//! slice_to_list_self_test.l — executable regression test for `slice[T].toList()`
//! (#2050 gotcha, cloud-agents docs/lyric/gotchas.md: "slice[Byte].toList()
//! does not resolve at runtime").
//!
//! Before this fix, `.toList()` on any `slice[T]` compiled cleanly (the type
//! checker had no signature for it, so it fell through to lenient/deferred
//! dispatch) but threw "unsupported method 'toList' on the receiver type" the
//! moment it ran — despite `lyric-stdlib/std/file.l`'s own module doc
//! describing `slice[T].toList()` / `List[T].toArray()` as the intended
//! round-trip shuttle; only the `List[T].toArray()` direction worked.
//!
//! **`--target dotnet` ONLY.** This PR implements `.toList()` in
//! `Msil.Codegen` (`lowerSliceToListMsil`) plus a `typechecker_exprs.l`
//! `inferMemberBase` case that resolves the real `List` `TypeId` so the
//! result type-checks wherever a `List[T]` is expected — matching the scope
//! of the originating gotcha. `--target native` already implements
//! `slice.toList()` (`llvm_codegen.l`, list and slice share one runtime
//! representation there). `--target jvm` fails cleanly at BUILD time instead
//! (`error[J008]: method 'toList' cannot be called on a slice receiver`) —
//! `Jvm.Codegen`'s method dispatch (`04_calls.l`) has no `toList` arm, and
//! rejects the call outright rather than deferring to a runtime throw the
//! way the pre-fix MSIL backend did. A still-open, tracked gap, not
//! silently skipped: see docs/01-language-reference.md and
//! `docs/59-compiler-stdlib-deep-review.md`'s parity ethic. Run only via:
//!
//!   lyric test lyric-compiler/lyric/slice_to_list_self_test.l
//!
//! (no `--target jvm` variant).
@test_module
package Lyric.SliceToListSelfTest

import Std.Core
import Std.Collections
import Std.Testing

test "toList on slice[Byte] preserves elements and is independently mutable" {
  val b: slice[Byte] = [1.toByte(), 2.toByte(), 3.toByte()]
  val lst: List[Byte] = b.toList()
  assertEqualInt(lst.count, 3, "toList preserves length")
  assertEqualInt(lst[0].toInt(), 1, "element 0")
  assertEqualInt(lst[1].toInt(), 2, "element 1")
  assertEqualInt(lst[2].toInt(), 3, "element 2")
  lst.add(4.toByte())
  assertEqualInt(lst.count, 4, "the returned List grows independently")
  assertEqualInt(b.length, 3, "the original slice is untouched by growing the List")
}

test "toList on slice[Int]" {
  val ints: slice[Int] = [10, 20, 30]
  val lst: List[Int] = ints.toList()
  assertEqualInt(lst.count, 3, "int list count")
  assertEqualInt(lst[0], 10, "element 0")
  assertEqualInt(lst[1], 20, "element 1")
  assertEqualInt(lst[2], 30, "element 2")
}

test "toList on slice[String]" {
  val strs: slice[String] = ["a", "b"]
  val lst: List[String] = strs.toList()
  assertEqualInt(lst.count, 2, "string list count")
  assertEqual(lst[0], "a", "element 0")
  assertEqual(lst[1], "b", "element 1")
}

test "toList on an empty slice" {
  val xs: slice[Int] = []
  val lst: List[Int] = xs.toList()
  assertEqualInt(lst.count, 0, "empty slice toList has zero elements")
}

test "toArray/toList round-trip" {
  val original: List[Int] = newList()
  original.add(7)
  original.add(8)
  val asSlice = original.toArray()
  val roundTripped: List[Int] = asSlice.toList()
  assertEqualInt(roundTripped.count, 2, "round-tripped count")
  assertEqualInt(roundTripped[0], 7, "round-tripped element 0")
  assertEqualInt(roundTripped[1], 8, "round-tripped element 1")
}
