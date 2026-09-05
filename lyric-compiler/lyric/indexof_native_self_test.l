//! indexof_native_self_test.l — #6588 review follow-up (#6752): pins that
//! native's `.indexOf`/`.lastIndexOf` (#6755) codegen respects the same
//! `import Std.String` gate MSIL/JVM already enforce (#6348/#6124/#6496) —
//! with the import in scope, the method spelling `s.indexOf(x)` /
//! `s.lastIndexOf(x)` is the UFCS form of the real `Option[Int]`-returning
//! `Std.String.indexOf`/`.lastIndexOf` free functions, never the raw
//! `-1`-sentinel `Int` the bare `lyric_string_index_of`/
//! `lyric_string_last_index_of` runtime intrinsics return. Routing the raw
//! intrinsic's result into a caller's `Option[Int]` `match` is exactly the
//! #6348 memory-corruption class (a raw `i32` inspected as if it were a
//! boxed union value).
//!
//! Mirrors `indexof_aliased_bcl_self_test.l`'s dotnet/JVM coverage of the
//! identical rule. Run here via `--target native` (a plain `@test_module`
//! with no compiler-package imports, unlike `llvm_codegen_self_test.l` —
//! compiles through the real `Lyric.LlvmBridge.compileToNativeWithFlags`
//! bundling pipeline, exactly like `lyric build --target native`, not the
//! `LYRIC_LOAD_COMPILER` in-process harness):
//!   lyric test lyric-compiler/lyric/indexof_native_self_test.l --target native
@test_module
package Lyric.IndexofNativeSelfTest

import Std.Core
import Std.Testing
import Std.String

test "import Std.String: .indexOf returns Option[Int] on native, not the raw sentinel (#6588, #6752)" {
  val s = "abcabc"
  match s.indexOf("bc") {
    case Some(i) -> assertEqualInt(i, 1, "method-spelling indexOf Some")
    case None -> assertTrue(false, "expected Some for a present substring")
  }
  match s.indexOf("zz") {
    case Some(_) -> assertTrue(false, "expected None for an absent substring")
    case None -> ()
  }
  match "".indexOf("") {
    case Some(i) -> assertEqualInt(i, 0, "empty-needle/-haystack indexOf is Some(0)")
    case None -> assertTrue(false, "expected Some(0) for an empty needle")
  }
  // The explicit raw-sentinel spellings stay `Int` even with the import in
  // scope (#6496) — the gate only redirects the bare method spelling.
  assertEqualInt(indexOfRaw(s, "bc"), 1, "indexOfRaw keeps the raw sentinel form")
  assertEqualInt(indexOfRaw(s, "zz"), -1, "indexOfRaw absent is -1")
}

test "import Std.String: .lastIndexOf returns Option[Int] on native, not the raw sentinel (#6755)" {
  val s = "abcabc"
  match s.lastIndexOf("bc") {
    case Some(i) -> assertEqualInt(i, 4, "method-spelling lastIndexOf finds the LAST occurrence")
    case None -> assertTrue(false, "expected Some for a present substring")
  }
  match s.lastIndexOf("zz") {
    case Some(_) -> assertTrue(false, "expected None for an absent substring")
    case None -> ()
  }
  match "".lastIndexOf("") {
    case Some(i) -> assertEqualInt(i, 0, "empty-needle/-haystack lastIndexOf is Some(0)")
    case None -> assertTrue(false, "expected Some(0) for an empty needle against an empty haystack")
  }
  match s.lastIndexOf("") {
    case Some(i) -> assertEqualInt(i, s.length, "empty-needle lastIndexOf matches at haystack.length, not 0")
    case None -> assertTrue(false, "expected Some(haystack.length) for an empty needle")
  }
  // The explicit raw-sentinel spellings stay `Int` even with the import in
  // scope (#6496) — the gate only redirects the bare method spelling.
  assertEqualInt(lastIndexOfRaw(s, "bc"), 4, "lastIndexOfRaw keeps the raw sentinel form")
  assertEqualInt(lastIndexOfRaw(s, "zz"), -1, "lastIndexOfRaw absent is -1")
}

test "import Std.String: the other new native scalar methods are unaffected by the indexOf gate (#6588)" {
  val s = "abcabc"
  assertTrue(s.contains("cab"), "contains still lowers to the raw runtime intrinsic")
  assertTrue(s.startsWith("abc"), "startsWith still lowers to the raw runtime intrinsic")
  assertTrue(s.endsWith("abc"), "endsWith still lowers to the raw runtime intrinsic")
  assertEqual(" hi ".trim(), "hi", "trim still lowers to the raw runtime intrinsic")
  assertEqual("HI".toLower(), "hi", "toLower still lowers to the raw runtime intrinsic")
}
