// typechecker_self_test.l — exercises the self-hosted Lyric.TypeChecker library.
// Compiled and executed by SelfHostedTypeCheckerTests.fs.
// Exit 0 + "ok" in stdout means all checks held.
package Lyric.TypeCheckerSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Parser
import Lyric.TypeChecker

// ─────────────────────────────────────────────────────────────────────────────
// Helpers.
// ─────────────────────────────────────────────────────────────────────────────

func parseCheck(src: in String): CheckResult {
  val pr = parse(src)
  check(pr.file)
}

func diagCount(cr: in CheckResult): Int {
  cr.diagnostics.count
}

func symCount(cr: in CheckResult): Int {
  cr.symbols.symbols.count
}

func hasDiagCode(cr: in CheckResult, code: in String): Bool {
  var i = 0
  while i < cr.diagnostics.count {
    if cr.diagnostics[i].code == code { return true }
    i = i + 1
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

func testEmptySource(): Unit {
  val cr = parseCheck("")
  assertEqualInt(diagCount(cr), 0, "empty: no diagnostics")
  assertEqualInt(symCount(cr), 0, "empty: no symbols")
}

func testFuncRegistered(): Unit {
  val src = "package P\nfunc add(x: in Int, y: in Int): Int { x + y }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "func-reg: no diagnostics")
  assertTrue(symCount(cr) > 0, "func-reg: symbol registered")
}

func testFuncSigResolved(): Unit {
  val src = "package P\nfunc double(n: in Int): Int { n + n }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "sig: no diagnostics")
  assertTrue(cr.sigs.containsKey("double"), "sig: bare key present")
  assertTrue(cr.sigs.containsKey("double/1"), "sig: arity key present")
}

func testRecordRegistered(): Unit {
  val src = "package P\nrecord Point { x: Int; y: Int }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "rec-reg: no diagnostics")
  assertTrue(symCount(cr) > 0, "rec-reg: symbol registered")
}

func testUnionCasesRegistered(): Unit {
  val src = "package P\nunion Color { case Red; case Green; case Blue }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "union-cases: no diagnostics")
  // union + 3 cases = 4 symbols
  assertEqualInt(symCount(cr), 4, "union-cases: 4 symbols")
}

func testDuplicateNameError(): Unit {
  val src = "package P\nrecord A { x: Int }\nrecord A { y: String }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0001"), "dup: T0001 emitted")
}

func testReturnTypeMismatch(): Unit {
  val src = "package P\nfunc f(): Int { \"hello\" }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0070"), "ret-mismatch: T0070 emitted")
}

func testValTypeMismatch(): Unit {
  val src = "package P\nfunc f(): Unit {\n  val x: Int = \"oops\"\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0060"), "val-mismatch: T0060 emitted")
}

func testReturnWithoutValueError(): Unit {
  val src = "package P\nfunc f(): Int { return }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0064"), "ret-novalue: T0064 emitted")
}

func testRangeSubtypeValid(): Unit {
  val src = "package P\ntype Age = Int range 0 ..= 150\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "range-valid: no diagnostics")
  assertTrue(symCount(cr) > 0, "range-valid: symbol registered")
}

func testRangeSubtypeEmptyBounds(): Unit {
  val src = "package P\ntype Bad = Int range 10 ..= 5\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0090"), "range-empty: T0090 emitted")
}

func testWhereClauseUnknownParam(): Unit {
  val src = "package P\nfunc f[T](x: in T): T where Z: Add { x }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0050"), "where-unknown: T0050 emitted")
}

func testArithmeticTypeMismatch(): Unit {
  // Adding Int and Bool — should produce T0031.
  val src = "package P\nfunc f(x: in Int, b: in Bool): Int { x + b }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0031"), "arith-mismatch: T0031 emitted")
}

func testUnknownName(): Unit {
  val src = "package P\nfunc f(): Int { noSuchName }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0020"), "unknown-name: T0020 emitted")
}

func testMultipleItemsNoError(): Unit {
  val src = "package P\nrecord A { x: Int }\nrecord B { y: String }\nfunc f(a: in A): String { a.x }\n"
  val pr = parse(src)
  val cr = check(pr.file)
  // f returns String but a.x is Int — T0070 expected; records A and B are fine
  assertTrue(symCount(cr) >= 3, "multi: A, B, f all registered")
}

func main(): Unit {
  testEmptySource()
  testFuncRegistered()
  testFuncSigResolved()
  testRecordRegistered()
  testUnionCasesRegistered()
  testDuplicateNameError()
  testReturnTypeMismatch()
  testValTypeMismatch()
  testReturnWithoutValueError()
  testRangeSubtypeValid()
  testRangeSubtypeEmptyBounds()
  testWhereClauseUnknownParam()
  testArithmeticTypeMismatch()
  testUnknownName()
  testMultipleItemsNoError()
  println("typechecker self-test: ok")
}
