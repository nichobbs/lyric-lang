//! indexof_aliased_bcl_self_test.l — pins the #6496 resolution: with
//! `import Std.String as Str` in scope, the method spelling
//! `.indexOf`/`.lastIndexOf` is the UFCS form of the Option[Int]-returning
//! Std.String free functions on BOTH targets — the same routing an
//! unaliased `import Std.String` gets (#6348/#6124), so the import form is
//! never a semantic switch.  Callers that want the raw -1-sentinel int use
//! the explicit `indexOfRaw`/`lastIndexOfRaw` spellings, pinned here too.
//! (This file previously pinned the pre-#6496 MSIL behavior where the
//! ALIASED form kept BCL Int semantics — that cross-target fork is gone.)
@test_module
package Lyric.IndexofAliasedBclSelfTest

import Std.Core
import Std.Testing
import Std.String as Str

test "aliased import: method spelling returns Option on both targets (#6496)" {
  val s = "abcabc"
  match s.indexOf("bc") {
    case Some(i) -> assertEqualInt(i, 1, "method-spelling indexOf Some")
    case None -> assertTrue(false, "expected Some for present substring")
  }
  match s.lastIndexOf("bc") {
    case Some(i) -> assertEqualInt(i, 4, "method-spelling lastIndexOf Some")
    case None -> assertTrue(false, "expected Some for present substring")
  }
  match s.indexOf("zz") {
    case Some(_) -> assertTrue(false, "expected None for absent substring")
    case None -> ()
  }
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

test "indexOfRaw/lastIndexOfRaw keep the raw -1 sentinel semantics (#6496)" {
  assertEqualInt(Str.indexOfRaw("abcabc", "bc"), 1, "indexOfRaw first occurrence")
  assertEqualInt(Str.lastIndexOfRaw("abcabc", "bc"), 4, "lastIndexOfRaw last occurrence")
  assertEqualInt(Str.indexOfRaw("abcabc", "zz"), -1, "indexOfRaw absent is -1")
  assertEqualInt(Str.lastIndexOfRaw("abcabc", "zz"), -1, "lastIndexOfRaw absent is -1")
}
