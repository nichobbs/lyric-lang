//! The overload rule of a call that resolves through default arguments, as the
//! type checker applies it (#8355, D208): which declaration a call binds, the
//! parameter count the checker records for the backends, and T0200 for a call
//! that two declarations take equally well.  The runtime half, on every
//! target, is `default_overload_self_test.l`.
@test_module
package Lyric.DefaultOverloadDiagSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Testing
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.Pipeline

func countCode(cr: in CheckResult, code: in String): Int {
  var n = 0
  for d in cr.diagnostics {
    if d.code == code {
      n = n + 1
    }
  }
  n
}

func codesOf(cr: in CheckResult): String {
  var acc = ""
  for d in cr.diagnostics {
    acc = acc + d.code + ": " + d.message + "; "
  }
  acc
}

func importedPackage(src: in String, name: in String): ImportedPackage {
  val pr = parse(src)
  ImportedPackage(
    name = name,
    items = pr.file.items,
    imports = collectImportNames(pr.file.imports),
    wholeImports = collectWholeImportNames(pr.file.imports)
  )
}

func checkWith(src: in String, pkgs: in List[ImportedPackage]): CheckResult {
  checkWithImportedPackages(pipePrepareForCheck(parse(src).file, false).file, pkgs)
}

func checkOne(src: in String): CheckResult {
  val none: List[ImportedPackage] = newList()
  checkWith(src, none)
}

// The parameter counts the checker recorded for the file's calls, which the
// backends bind the callee by.
func recordedArities(cr: in CheckResult): List[Int] {
  val acc: List[Int] = newList()
  for k in mapKeys(cr.symbols.methodCallArities) {
    match mapGet(cr.symbols.methodCallArities, k) {
      case Some(n) -> acc.add(n)
      case None -> ()
    }
  }
  acc
}

func hasArity(cr: in CheckResult, n: in Int): Bool {
  for a in recordedArities(cr) {
    if a == n {
      return true
    }
  }
  false
}

val fFirst: String = "package App\nfunc f(x: in Int, y: in Int = 1): Int { x + y }\nfunc f(x: in Int, y: in Int = 10, z: in Int = 100): Int { x + y + z }\n"

val fSecond: String = "package App\nfunc f(x: in Int, y: in Int = 10, z: in Int = 100): Int { x + y + z }\nfunc f(x: in Int, y: in Int = 1): Int { x + y }\n"

test "a call through defaults binds the declaration that fills the fewest" {
  val orders: List[String] = newList()
  orders.add(fFirst)
  orders.add(fSecond)
  for decls in orders {
    val cr = checkOne(decls + "func g(a: in Int): Int { f(a) }\n")
    assertEqualInt(cr.diagnostics.count, 0, "no diagnostic (" + codesOf(cr) + ")")
    assertTrue(hasArity(cr, 2), "the call is recorded as binding the two-parameter declaration")
    assertFalse(hasArity(cr, 3), "and not the three-parameter one")
  }
}

test "the declaration's return type is the call's type" {
  val src = "package App\nfunc f(x: in Int, y: in Int = 1): Int { x + y }\nfunc f(x: in Int, y: in Int = 10, z: in Int = 100): String { \"s\" }\nfunc g(a: in Int): Int { f(a) }\n"
  val cr = checkOne(src)
  assertEqualInt(cr.diagnostics.count, 0, "f(a) is the Int-returning declaration (" + codesOf(cr) + ")")
  val bad = "package App\nfunc f(x: in Int, y: in Int = 1): String { \"s\" }\nfunc f(x: in Int, y: in Int = 10, z: in Int = 100): Int { 1 }\nfunc g(a: in Int): Int { f(a) }\n"
  val badCr = checkOne(bad)
  assertTrue(
    countCode(badCr, "T0070") + countCode(badCr, "T0065") > 0,
    "the String-returning declaration is the one bound"
  )
}

test "a call supplying every parameter wins over one filling defaults" {
  val src = "package App\nfunc k(a: in Int, b: in Int): Int { a + b }\nfunc k(a: in Int, b: in Int = 1, c: in Int = 2): Int { a + b + c }\nfunc g(): Int { k(1, 2) }\n"
  val cr = checkOne(src)
  assertEqualInt(cr.diagnostics.count, 0, codesOf(cr))
  assertFalse(hasArity(cr, 3), "k(1, 2) binds the two-parameter declaration")
}

test "the argument types filter before the number of defaults" {
  val src = "package App\nfunc m(x: in Int, y: in Int = 1): Int { x }\nfunc m[T](x: in T, y: in Int = 1, z: in Int = 2): Int { y }\nfunc g(): Int { m(\"s\") }\n"
  val cr = checkOne(src)
  assertEqualInt(cr.diagnostics.count, 0, "m(String) fits only the generic declaration (" + codesOf(cr) + ")")
  assertTrue(hasArity(cr, 3), "recorded as the three-parameter declaration")
}

test "a name only one declaration has selects it" {
  val src = "package App\nfunc n(a: in Int, b: in Int = 1): Int { b }\nfunc n(a: in Int, c: in Int = 5, d: in Int = 6): Int { c }\nfunc g(): Int { n(1, c = 7) + n(1, b = 3) }\n"
  val cr = checkOne(src)
  assertEqualInt(cr.diagnostics.count, 0, codesOf(cr))
  assertTrue(hasArity(cr, 3), "n(1, c = 7) binds the declaration naming c")
}

test "a call no declaration takes is T0042 against a real declaration" {
  val cr = checkOne(fFirst + "func g(): Int { f() }\n")
  assertEqualInt(countCode(cr, "T0042"), 1, codesOf(cr))
  assertEqualInt(countCode(cr, "T0200"), 0, "not an ambiguity")
}

val pkgA: String = "package PkgA\npub func f(x: in Int, y: in Int = 1): Int { x + y }\npub func h(x: in Int, y: in Int = 1): Int { x + y }\n"

val pkgB: String = "package PkgB\npub func f(x: in Int, y: in Int = 2): Int { x * y }\npub func h(x: in Int, z: in Int = 2): Int { x * z }\n"

func twoPackages(): List[ImportedPackage] {
  val pkgs: List[ImportedPackage] = newList()
  pkgs.add(importedPackage(pkgA, "PkgA"))
  pkgs.add(importedPackage(pkgB, "PkgB"))
  pkgs
}

test "a function two imported packages declare is T0123 unless qualified" {
  val cr = checkWith("package App\nimport PkgA\nimport PkgB\nfunc g(a: in Int): Int { f(a) }\n", twoPackages())
  assertEqualInt(
    countCode(cr, "T0123"),
    1,
    "a bare name two imports declare is ambiguous before any overload rule: " + codesOf(cr)
  )
  val qualified = checkWith(
    "package App\nimport PkgA\nimport PkgB\nfunc g(a: in Int): Int { PkgB.f(a) }\n",
    twoPackages()
  )
  assertEqualInt(qualified.diagnostics.count, 0, "qualifying the call resolves it: " + codesOf(qualified))
}

val methodAndDotNamed: String = "package App\nrecord R {\n  n: Int\n  func m(self: in R, x: in Int, y: in Int = 1): Int { x }\n}\n"

test "a body method answers before a dot-named function of the same shape" {
  val src = methodAndDotNamed +
    "func R.m(self: in R, x: in Int, y: in Int = 2): String { \"dot\" }\nfunc g(r: in R): Int { r.m(1) }\n"
  val cr = checkOne(src)
  assertEqualInt(cr.diagnostics.count, 0, "the method, not a tie: " + codesOf(cr))
}

val twoImpls: String = "package App\ninterface A {\n  func m(self: in Self, x: in Int, y: in Int = 1): Int\n}\ninterface B {\n  func m(self: in Self, x: in Int, z: in Int = 2): Int\n}\nrecord R {\n  n: Int\n}\nimpl A for R {\n  func m(self: in R, x: in Int, y: in Int = 1): Int { x + y }\n}\nimpl B for R {\n  func m(self: in R, x: in Int, z: in Int = 2): Int { x * z }\n}\n"

test "a call that two methods of one name take with equally many defaults is T0200" {
  // The two impls clash (T0139) as it is; the call is a tie besides.
  val cr = checkOne(twoImpls + "func g(r: in R): Int { r.m(1) }\n")
  assertEqualInt(countCode(cr, "T0200"), 1, codesOf(cr))
  var msg = ""
  for d in cr.diagnostics {
    if d.code == "T0200" {
      msg = d.message
    }
  }
  assertTrue(Str.contains(msg, "name an argument"), "the message hints to name an argument: " + msg)
}

test "naming an argument only one of them declares resolves the tie" {
  val cr = checkOne(twoImpls + "func g(r: in R): Int { r.m(1, z = 5) + r.m(1, y = 5) }\n")
  assertEqualInt(countCode(cr, "T0200"), 0, codesOf(cr))
  val full = checkOne(twoImpls + "func g(r: in R): Int { r.m(1, 2) }\n")
  assertEqualInt(countCode(full, "T0200"), 0, "supplying every parameter is not a tie: " + codesOf(full))
}

test "a method call fills the fewest defaults" {
  val src = "package App\nrecord R {\n  n: Int\n  func m(self: in R, x: in Int, y: in Int = 10, z: in Int = 100): Int { x }\n  func m(self: in R, x: in Int, y: in Int = 1): Int { y }\n}\nfunc g(r: in R): Int { r.m(1) }\n"
  val cr = checkOne(src)
  assertEqualInt(cr.diagnostics.count, 0, codesOf(cr))
  assertTrue(hasArity(cr, 2), "r.m(1) binds the two-parameter method")
}
