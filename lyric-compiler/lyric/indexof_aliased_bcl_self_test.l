//! indexof_aliased_bcl_self_test.l — pins the ALIASED-import exclusion of
//! #6348's MSIL routing: a file with `import Std.String as Str` keeps the
//! documented BCL semantics for method-spelling `.indexOf`/`.lastIndexOf`
//! (raw Int, -1 when absent) on `--target dotnet`, while the free-function
//! spelling through the alias returns Option[Int] as always.  This is the
//! MSIL half of the aliased-import cross-target divergence tracked in
//! #6496 (the JVM backend routes aliased files to Option too) — CI runs
//! this file dotnet-only for that reason; re-visit when #6496 is decided.
@test_module
package Lyric.IndexofAliasedBclSelfTest

import Std.Core
import Std.Testing
import Std.String as Str

test "aliased import: method spelling keeps BCL Int semantics (#6348/#6496)" {
  val s = "abcabc"
  assertEqualInt(s.indexOf("bc"), 1, "BCL indexOf first occurrence")
  assertEqualInt(s.lastIndexOf("bc"), 4, "BCL lastIndexOf last occurrence")
  assertEqualInt(s.indexOf("zz"), -1, "BCL indexOf absent is -1")
}

test "aliased import: free-function spelling returns Option (#6348)" {
  match Str.indexOf("abcabc", "bc") {
    case Some(i) -> assertEqualInt(i, 1, "free-function indexOf Some")
    case None -> assertTrue(false, "expected Some")
  }
  match Str.indexOf("abcabc", "zz") {
    case Some(_) -> assertTrue(false, "expected None")
    case None -> ()
  }
}
