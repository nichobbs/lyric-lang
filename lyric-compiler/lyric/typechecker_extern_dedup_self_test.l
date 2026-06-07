//! typechecker_extern_dedup_self_test.l — #2426: the canonical TypeId for an
//! extern type must be consistent regardless of declaration order.
//!
//! Before the fix, two `IExternType` registrations with the same `clrName`
//! in the same `SymbolTable` could receive distinct `TypeId`s depending on
//! which one was registered first (T0060 false-positive when the second decl
//! arrived).  `findExternTypeIdByClr` now scans the table before minting a
//! fresh id, so the second registration re-uses the first's `TypeId`.  The
//! visible invariant: two `extern type` declarations pointing at the same CLR
//! name in the same source file must not produce a T0060 diagnostic.
//!
//! Run in CI via native `lyric test`:
//!
//!   lyric test lyric-compiler/lyric/typechecker_extern_dedup_self_test.l
@test_module
package Lyric.TypeCheckerExternDedupSelfTest

import Std.Core
import Std.Testing
import Lyric.Parser
import Lyric.TypeChecker

func parseCheck(src: in String): CheckResult {
  val pr = parse(src)
  check(pr.file)
}

func hasDiagCode(cr: in CheckResult, code: in String): Bool {
  var i = 0
  while i < cr.diagnostics.count {
    if cr.diagnostics[i].code == code {
      return true
    }
    i = i + 1
  }
  false
}

test "same clrName registered twice produces no T0060 (dedup invariant)" {
  val src = "package P\nextern type A = \"System.String\"\nextern type B = \"System.String\"\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0060"), "same clrName must not produce T0060")
  assertEqualInt(cr.diagnostics.count, 0, "no diagnostics at all")
}

test "distinct clrNames register independently without T0060" {
  val src = "package P\nextern type IntBox = \"System.Int32\"\nextern type StrBox = \"System.String\"\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0060"), "distinct clrNames must not produce T0060")
  assertEqualInt(cr.diagnostics.count, 0, "no diagnostics")
}

test "same clrName three times: still no T0060" {
  val src = "package P\nextern type A = \"System.Object\"\nextern type B = \"System.Object\"\nextern type C = \"System.Object\"\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0060"), "three externs same clrName: no T0060")
  assertEqualInt(cr.diagnostics.count, 0, "no diagnostics")
}
