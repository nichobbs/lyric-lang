//! modechecker_self_test.l — exercises the self-hosted Lyric.ModeChecker library.
//! Compiled and executed by SelfHostedModeCheckerTests.fs.
//! Exit 0 + "ok" in stdout means all checks held.
package Lyric.ModeCheckerSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Parser
import Lyric.ModeChecker

// ─────────────────────────────────────────────────────────────────────────────
// Helpers.
// ─────────────────────────────────────────────────────────────────────────────
func parseCheck(src: in String): ModeCheckResult {
  val pr = parse(src)
  checkFile(pr.file)
}

func hasDiagCode(result: in ModeCheckResult, code: in String): Bool {
  var i = 0
  while i < result.diagnostics.count {
    if result.diagnostics[i].code == code {
      return true
    }
    i = i + 1
  }
  false
}

func diagCount(result: in ModeCheckResult): Int {
  result.diagnostics.count
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────
func testRuntimeCheckedDefault(): Unit {
  val result = parseCheck("package P\nfunc f(): Int { 1 }\n")
  match result.level {
    case VLRuntimeChecked -> {
    }
    case _ -> {
      assertTrue(false, "default-level: expected VLRuntimeChecked")
    }
  }
  assertEqualInt(diagCount(result), 0, "default-level: no diagnostics")
}

func testExplicitRuntimeChecked(): Unit {
  val result = parseCheck("@runtime_checked\npackage P\nfunc f(): Int { 1 }\n")
  match result.level {
    case VLRuntimeChecked -> {
    }
    case _ -> {
      assertTrue(false, "explicit-rc: expected VLRuntimeChecked")
    }
  }
  assertEqualInt(diagCount(result), 0, "explicit-rc: no diagnostics")
}

func testProofRequired(): Unit {
  val result = parseCheck("@proof_required\npackage P\nfunc f(): Int { 1 }\n")
  match result.level {
    case VLProofRequired -> {
    }
    case _ -> {
      assertTrue(false, "proof-req: expected VLProofRequired")
    }
  }
  assertEqualInt(diagCount(result), 0, "proof-req: no diagnostics")
}

func testProofRequiredUnsafe(): Unit {
  val result = parseCheck("@proof_required(unsafe_blocks_allowed)\npackage P\nfunc f(): Unit {}\n")
  match result.level {
    case VLProofRequiredUnsafe -> {
    }
    case _ -> {
      assertTrue(false, "pr-unsafe: expected VLProofRequiredUnsafe")
    }
  }
  assertEqualInt(diagCount(result), 0, "pr-unsafe: no diagnostics")
}

func testAxiomLevel(): Unit {
  val result = parseCheck("@axiom\npackage P\nfunc f(): Int\n")
  match result.level {
    case VLAxiom -> {
    }
    case _ -> {
      assertTrue(false, "axiom-level: expected VLAxiom")
    }
  }
  assertEqualInt(diagCount(result), 0, "axiom-level: no diagnostics")
}

func testConflictingAnnotations(): Unit {
  val result = parseCheck("@runtime_checked\n@axiom\npackage P\nfunc f(): Int { 1 }\n")
  assertTrue(hasDiagCode(result, "V0010"), "conflict: V0010 emitted")
}

func testUnknownModifier(): Unit {
  val result = parseCheck("@proof_required(badmod)\npackage P\nfunc f(): Int { 1 }\n")
  assertTrue(hasDiagCode(result, "V0011"), "unknown-mod: V0011 emitted")
}

func testPureCalleePassing(): Unit {
  // @pure callee is admissible from proof-required code.
  val src = "@proof_required\npackage P\n@pure\nfunc helper(): Int { 42 }\nfunc f(): Int { helper() }\n"
  val result = parseCheck(src)
  assertEqualInt(diagCount(result), 0, "pure-callee: no diagnostics")
}

func testImpureCalleeV0002(): Unit {
  // Calling a runtime-checked function from proof-required → V0002.
  // In the self-hosted checker, a function without @pure in a @proof_required
  // file inherits proof-required level, so a callee imported from a
  // runtime-checked package would produce V0002.  We simulate this by using
  // checkFileWithImports with a runtime-checked import.
  val imports: List[ImportedMeta] = newList()
  imports.add(ImportedMeta(name = "Ext.Lib", level = "runtime_checked"))
  val pr = parse("@proof_required\npackage P\nimport Ext.Lib\nfunc f(): Unit {}\n")
  val result = checkFileWithImports(pr.file, imports)
  assertTrue(hasDiagCode(result, "V0001"), "impure-callee: V0001 emitted")
}

func testAwaitV0002(): Unit {
  val src = "@proof_required\npackage P\nfunc f(): Unit { await someAsync() }\nfunc someAsync(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0002"), "await: V0002 emitted")
}

func testUnsafeBlockV0003(): Unit {
  val src = "@proof_required\npackage P\nfunc f(): Unit { unsafe { } }\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0003"), "unsafe: V0003 emitted")
}

func testUnsafeAllowedNoError(): Unit {
  val src = "@proof_required(unsafe_blocks_allowed)\npackage P\nfunc f(): Unit { unsafe { } }\n"
  val result = parseCheck(src)
  assertEqualInt(diagCount(result), 0, "unsafe-allowed: no diagnostics")
}

func testAxiomWithBodyV0004(): Unit {
  val src = "@proof_required\npackage P\n@axiom\nfunc assume(p: in Bool): Unit { p }\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0004"), "axiom-body: V0004 emitted")
}

func testAxiomNoBodyOk(): Unit {
  val src = "@proof_required\npackage P\n@axiom\nfunc assume(p: in Bool): Unit\n"
  val result = parseCheck(src)
  assertEqualInt(diagCount(result), 0, "axiom-no-body: no diagnostics")
}

func testLoopWithoutInvariantV0005(): Unit {
  val src = "@proof_required\npackage P\nfunc f(): Unit {\n  var i = 0\n  while i < 10 { i = i + 1 }\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0005"), "loop-no-inv: V0005 emitted")
}

func testUnboundedQuantifierV0006(): Unit {
  // forall with Int binder in a requires: clause — unbounded domain.
  val src = "@proof_required\npackage P\nfunc f(): Bool\n  requires: forall (n: Int) { n >= 0 }\n{ true }\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0006"), "unbounded-q: V0006 emitted")
}

func testRuntimeCheckedNoChecks(): Unit {
  // @runtime_checked packages skip all proof-mode checks.
  val src = "@runtime_checked\npackage P\nfunc f(): Unit {\n  var i = 0\n  while i < 10 { i = i + 1 }\n}\n"
  val result = parseCheck(src)
  assertEqualInt(diagCount(result), 0, "rc-no-checks: no diagnostics")
}

func testCrossPackageCallV0002(): Unit {
  // A proof-required function calling a function from a runtime_checked
  // package via a multi-segment path (e.g. Ext.Lib.someFunc()) must trigger
  // V0002 at the call site, in addition to V0001 at the import.
  val imports: List[ImportedMeta] = newList()
  imports.add(ImportedMeta(name = "Ext.Lib", level = "runtime_checked"))
  val src = "@proof_required\npackage P\nimport Ext.Lib\nfunc f(): Unit { Ext.Lib.someFunc() }\n"
  val pr = parse(src)
  val result = checkFileWithImports(pr.file, imports)
  assertTrue(hasDiagCode(result, "V0002"), "cross-pkg: V0002 emitted for cross-package call")
}

func testCrossPackageCallProofOk(): Unit {
  // Calling into a proof_required package from proof_required is fine.
  val imports: List[ImportedMeta] = newList()
  imports.add(ImportedMeta(name = "Safe.Lib", level = "proof_required"))
  val src = "@proof_required\npackage P\nimport Safe.Lib\nfunc f(): Unit { Safe.Lib.helper() }\n"
  val pr = parse(src)
  val result = checkFileWithImports(pr.file, imports)
  assertTrue(not (hasDiagCode(result, "V0002")), "cross-pkg-ok: V0002 not emitted for proof_required callee")
}

func testCrossPackageSingleSegmentV0002(): Unit {
  // Covers the EPath-receiver branch (single-segment package name).
  val imports: List[ImportedMeta] = newList()
  imports.add(ImportedMeta(name = "Pkg", level = "runtime_checked"))
  val src = "@proof_required\npackage P\nimport Pkg\nfunc f(): Unit { Pkg.someFunc() }\n"
  val pr = parse(src)
  val result = checkFileWithImports(pr.file, imports)
  assertTrue(
    hasDiagCode(result, "V0002"),
    "single-seg-pkg: V0002 emitted for single-segment runtime_checked package call"
  )
}

func main(): Unit {
  testRuntimeCheckedDefault()
  testExplicitRuntimeChecked()
  testProofRequired()
  testProofRequiredUnsafe()
  testAxiomLevel()
  testConflictingAnnotations()
  testUnknownModifier()
  testPureCalleePassing()
  testImpureCalleeV0002()
  testAwaitV0002()
  testUnsafeBlockV0003()
  testUnsafeAllowedNoError()
  testAxiomWithBodyV0004()
  testAxiomNoBodyOk()
  testLoopWithoutInvariantV0005()
  testUnboundedQuantifierV0006()
  testRuntimeCheckedNoChecks()
  testCrossPackageCallV0002()
  testCrossPackageCallProofOk()
  testCrossPackageSingleSegmentV0002()
  println("modechecker self-test: ok")
}
