//! lazy_lyric_count_jvm_self_test.l — JVM regression test for #4803.
//!
//! The synthesised `__lyricCount(Object)I` static helper (the erased-receiver
//! `.count`/`.length` dispatch — see `02_exprs.l`'s `memberName == "count" or
//! memberName == "length"` branch on a statically-`Object` receiver, e.g. a
//! match binding on a generic union payload such as `case Ok(items)` on
//! `Result[List[Int], String]`, where the union field itself always erases a
//! type parameter to `Object`) used to be emitted unconditionally into every
//! package's functions class (~40 bytes of dead code for the many packages
//! that never take this path).  The fix threads a package-shared
//! `usesLyricCount: List[Bool]` flag through every `FuncCtx` (mirroring
//! `closureAcc`'s existing threading discipline): the erased-receiver
//! `.count`/`.length` call site appends a marker when it actually emits the
//! `invokestatic __lyricCount` call, and `codegenPackageWithSigsSeeded` only
//! adds the helper method when that list is non-empty.
//!
//! This test exercises the CORRECTNESS side of the fix (the helper must
//! still work exactly as before when the package genuinely needs it): it is
//! not possible to assert the helper's ABSENCE from a package that never
//! calls it from within a single-file `@test_module` (that would need a
//! second, separately-compiled package with no `.count`/`.length` erased
//! dispatch at all, to inspect via reflection) — see the code review finding
//! and `codegenPackageWithSigsSeeded`'s `usesLyricCount.count > 0` gate for
//! that half of the fix.
//!
//! Covers every erased-receiver branch the helper's runtime-class dispatch
//! handles: `java.util.Collection` (a `List` union payload), `java.util.Map`
//! (a `Map` union payload), and `java.lang.String` (a `String` union
//! payload) — the boxed-slice (`Object[]`) last-resort branch is exercised
//! transitively by the same dispatch shape but is harder to construct
//! directly from a union payload without an explicit `slice[T]` field, so is
//! not separately pinned here.
//!
//! Run by native `lyric test --target jvm`, which compiles this module
//! in-process through the self-hosted `Jvm.Bridge` (`compileToJarBundled`)
//! and runs it under `java`.  Imports only `Std.*`.
@test_module
package Jvm.LazyLyricCountSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// `items`'s JVM type is `Object` here — `Result`'s `Ok` case field for a
// generic `T` payload always erases to `Object` in the emitted union class,
// regardless of the concrete `T` this function is called with — so
// `items.count` reaches the erased-receiver `__lyricCount` dispatch rather
// than a direct `invokeinterface java/util/Collection.size`.
func firstListLen(r: Result[List[Int], String]): Int {
  match r {
    case Ok(items) -> items.count
    case Err(_) -> -1
  }
}

func firstMapLen(r: Result[Map[String, Int], String]): Int {
  match r {
    case Ok(m) -> m.count
    case Err(_) -> -1
  }
}

func firstStringLen(r: Result[String, String]): Int {
  match r {
    case Ok(s) -> s.length
    case Err(_) -> -1
  }
}

test "erased-receiver .count on a List union payload dispatches through __lyricCount" {
  val xs: List[Int] = newList()
  xs.add(1)
  xs.add(2)
  xs.add(3)
  val r: Result[List[Int], String] = Ok(value = xs)
  assertEqualInt(firstListLen(r), 3, "count of a 3-element List via the erased dispatch")
}

test "erased-receiver .count on a Map union payload dispatches through __lyricCount" {
  val m: Map[String, Int] = newMap()
  m.add("a", 1)
  m.add("b", 2)
  val r: Result[Map[String, Int], String] = Ok(value = m)
  assertEqualInt(firstMapLen(r), 2, "count of a 2-entry Map via the erased dispatch")
}

test "erased-receiver .length on a String union payload dispatches through __lyricCount" {
  val r: Result[String, String] = Ok(value = "hello")
  assertEqualInt(firstStringLen(r), 5, "length of 'hello' via the erased dispatch")
}

test "erased-receiver .count still returns the Err sentinel without touching the helper" {
  val r: Result[List[Int], String] = Err(error = "nope")
  assertEqualInt(firstListLen(r), -1, "Err arm returns -1 without reaching items.count")
}
