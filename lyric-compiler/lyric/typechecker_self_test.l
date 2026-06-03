// typechecker_self_test.l — exercises the self-hosted Lyric.TypeChecker library.
// Compiled and executed by SelfHostedTypeCheckerTests.fs.
// Exit 0 + "ok" in stdout means all checks held.
package Lyric.TypeCheckerSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
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

func testYieldOutsideAsync(): Unit {
  // T0094: yield inside a non-async function body.
  val src = "package P\nfunc f(): Int {\n  yield 1\n  return 0\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0094"), "T0094: yield outside async emits diagnostic")
}

func testAsyncGeneratorFlags(): Unit {
  // An async func with yield: isAsync=true, isGenerator=true, no T0094.
  val src = "package P\nasync func g(): Int {\n  yield 1\n  yield 2\n}\n"
  val cr = parseCheck(src)
  val noT0094 = not hasDiagCode(cr, "T0094")
  assertTrue(noT0094, "async-gen: no T0094 for valid async generator")
  match mapGet(cr.sigs, "g") {
    case None      -> assertTrue(false, "async-gen: sig 'g' not found")
    case Some(sig) -> {
      assertTrue(sig.isAsync,     "async-gen: isAsync=true")
      assertTrue(sig.isGenerator, "async-gen: isGenerator=true")
    }
  }
}

func testHotAnnotationFlag(): Unit {
  // @hot on a regular async func: isHot=true, isGenerator=false.
  val src = "package P\n@hot\nasync func h(): Int { return 42 }\n"
  val cr = parseCheck(src)
  match mapGet(cr.sigs, "h") {
    case None      -> assertTrue(false, "hot: sig 'h' not found")
    case Some(sig) -> {
      assertTrue(sig.isHot,          "hot: isHot=true")
      assertTrue(not sig.isGenerator, "hot: isGenerator=false")
    }
  }
}

func testQualifiedTypeResolvesViaImport(): Unit {
  // `Lib.Point` in a type position should resolve to the same `Point`
  // type registered by checkWithImports — no T0014 "qualified type not
  // resolved".
  val libSrc = "package Lib\npub record Point { x: Int; y: Int }\n"
  val libPr  = parse(libSrc)
  val importedItems: List[Item] = newList()
  var i = 0
  while i < libPr.file.items.count {
    importedItems.add(libPr.file.items[i])
    i = i + 1
  }
  val src = "package App\nfunc f(p: Lib.Point): Int { 0 }\n"
  val pr  = parse(src)
  val cr  = checkWithImports(pr.file, importedItems)
  // Stronger than just `not hasDiagCode T0014` (#924): assert there
  // are no type-resolution diagnostics at all.  The previous form
  // would have passed even if a different type-resolution error
  // (T0010 / T0020 / T0050) had surfaced, masking a regression.
  assertTrue(not hasDiagCode(cr, "T0014"),
    "qualified-type-import: no T0014 for Lib.Point when Point is imported")
  assertTrue(not hasDiagCode(cr, "T0010"),
    "qualified-type-import: no T0010 unknown-type for Lib.Point")
  assertTrue(not hasDiagCode(cr, "T0020"),
    "qualified-type-import: no T0020 unknown-name for Lib.Point")
  assertTrue(not hasDiagCode(cr, "T0050"),
    "qualified-type-import: no T0050 generic-arity for Lib.Point")
}

func testQualifiedTypeUnknownEmitsT0014(): Unit {
  // A qualified name whose last segment is not in scope should still
  // emit T0014, not resolve silently.
  val src = "package App\nfunc f(x: Unknown.Pkg.Blorp): Int { 0 }\n"
  val empty: List[Item] = newList()
  val pr = parse(src)
  val cr = checkWithImports(pr.file, empty)
  assertTrue(hasDiagCode(cr, "T0014"),
    "qualified-unknown: T0014 for Unknown.Pkg.Blorp not in scope")
}

func testQualifiedTypeMisqualifiedResolvesPermissively(): Unit {
  // Interim Band 6 behaviour (docs/41 §9, #923): the multi-segment
  // resolver looks up only the LAST segment in the symbol table.
  // `Wrong.Prefix.Point` therefore resolves to the imported `Point`
  // even though the package prefix is wrong, because import-statement
  // resolution is deferred to Track A.  This test pins that
  // permissive behaviour so a future change to the resolver
  // surfaces here intentionally rather than silently flipping the
  // verdict for existing code.
  //
  // Once import resolution lands, replace `assertTrue(not ...)` with
  // `assertTrue(hasDiagCode(cr, "T0014"))` and tighten the test name
  // to `testQualifiedTypeMisqualifiedEmitsT0014`.
  val libSrc = "package Lib\npub record Point { x: Int; y: Int }\n"
  val libPr  = parse(libSrc)
  val importedItems: List[Item] = newList()
  var i = 0
  while i < libPr.file.items.count {
    importedItems.add(libPr.file.items[i])
    i = i + 1
  }
  val src = "package App\nfunc f(p: Wrong.Prefix.Point): Int { 0 }\n"
  val pr  = parse(src)
  val cr  = checkWithImports(pr.file, importedItems)
  assertTrue(not hasDiagCode(cr, "T0014"),
    "qualified-misqualified: last-segment lookup currently accepts Wrong.Prefix.Point when Point is imported (Band 6 interim — #923)")
}

// #425 item 6: T0031 ("arithmetic operands must have the same type")
// used to render user-defined types as `<#7>` because the renderer
// could not look up declared names.  After the fix, `TyUser` carries
// its declared name from the resolver and `renderType` surfaces it.
// We exercise this with a record type used in a typed-arithmetic
// mismatch (a Bool + Point pair).  T0031's payload must include the
// declared name "Point" rather than the synthetic `<#N>` placeholder.
func testTyUserRendersDeclaredName(): Unit {
  val src =
    "package P\n" +
    "record Point { x: Int; y: Int }\n" +
    "func f(p: in Point, b: in Bool): Int { p + b }\n"
  val cr = parseCheck(src)
  // Pull every diagnostic message and assert at least one mentions
  // "Point" rather than the synthetic `<#…>`.
  var sawName = false
  var sawPlaceholder = false
  var i = 0
  while i < cr.diagnostics.count {
    val m = cr.diagnostics[i].message
    if Str.contains(m, "Point") { sawName = true }
    if Str.contains(m, "<#") { sawPlaceholder = true }
    i = i + 1
  }
  assertTrue(sawName, "TyUser render: 'Point' surfaces in a diagnostic")
  assertTrue(not sawPlaceholder,
             "TyUser render: no `<#…>` placeholder leaked to diagnostics")
}

// #425 item 5: a range bound of `-9223372036854775808` (Long.MinValue)
// must fold cleanly without T0093 (overflow during fold).  Before the
// fix the lexer rejected the inner literal as out-of-range and the
// fold returned FEOverflow; the lexer now stores 9223372036854775808
// as Long.MinValue's bit pattern and the fold recognises the
// PreNeg + literal pair as a single Long.MinValue unit.
func testRangeBoundLongMinValueFolds(): Unit {
  val src =
    "package P\n" +
    "type Limit = Long range -9223372036854775808 ..= 0\n"
  val cr = parseCheck(src)
  // T0093 = "symbolic bound that cannot be folded" — must not fire.
  assertTrue(not hasDiagCode(cr, "T0093"),
             "Long.MinValue range bound folds without T0093")
  assertEqualInt(diagCount(cr), 0,
                 "Long.MinValue range bound: no diagnostics at all")
}

func testFirstWinsOnImportFuncCollision(): Unit {
  // `addSigsFromItems` is called twice by `checkWithImports`: once
  // with `importedItems`, once with `file.items`.  On the bare name
  // key, first-wins means the imported signature pins the slot, and
  // a user-defined function with the same name + same arity does not
  // overwrite it.  The arity-qualified key (`name/<n>`) is still
  // distinct, so user overloads at a different arity register fine.
  //
  // This test pins both halves of that contract: (a) no
  // Dictionary.Add throw when the user redeclares an imported name
  // at the same arity (would have crashed the typechecker before the
  // first-wins guard); (b) a user overload at a different arity gets
  // its own arity-qualified slot and resolves cleanly.
  val libSrc =
    "package Lib\n" +
    "pub func collide(x: in Int): Int { x }\n"
  val libPr  = parse(libSrc)
  val importedItems: List[Item] = newList()
  var i = 0
  while i < libPr.file.items.count {
    importedItems.add(libPr.file.items[i])
    i = i + 1
  }
  // (a) same name + same arity: must not crash; check completes.
  val srcSame =
    "package App\n" +
    "func collide(x: in Int): Int { x + 1 }\n" +
    "func use(): Int { collide(7) }\n"
  val prSame = parse(srcSame)
  val crSame = checkWithImports(prSame.file, importedItems)
  assertTrue(diagCount(crSame) == 0,
             "first-wins: same-name same-arity user redeclaration does not crash and emits no diagnostics")

  // (b) same name + different arity: user overload registers on its
  // own arity-qualified key; both calls resolve.
  val srcDiff =
    "package App2\n" +
    "func collide(x: in Int, y: in Int): Int { x + y }\n" +
    "func use(): Int { collide(7, 8) }\n"
  val prDiff = parse(srcDiff)
  val crDiff = checkWithImports(prDiff.file, importedItems)
  assertTrue(diagCount(crDiff) == 0,
             "first-wins: same-name different-arity user overload registers cleanly")
}

// #1482 (Band-1 foundation): the `Type` union now carries refinement
// (range) bounds via `TyRefined`, populated by the resolver for inline
// refined types (`Int range lo .. hi`).  A binding initialised with an
// integer literal outside those bounds is rejected with T0015.

func testInlineRefinedInBounds(): Unit {
  val src = "package P\nfunc f(): Unit {\n  val x: Int range 0 ..= 9 = 5\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0015"), "inline-range in-bounds: no T0015")
  assertEqualInt(diagCount(cr), 0, "inline-range in-bounds: clean")
}

func testInlineRefinedAboveInclusive(): Unit {
  val src = "package P\nfunc f(): Unit {\n  val x: Int range 0 ..= 9 = 10\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0015"), "inline-range above inclusive hi: T0015")
}

func testInlineRefinedAtInclusiveHi(): Unit {
  // `..=` includes the upper endpoint, so 9 is in range.
  val src = "package P\nfunc f(): Unit {\n  val x: Int range 0 ..= 9 = 9\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0015"), "inline-range at inclusive hi: no T0015")
}

func testInlineRefinedHalfOpenExcludesHi(): Unit {
  // `..` is half-open: 10 is excluded from `0 .. 10`.
  val src = "package P\nfunc f(): Unit {\n  val x: Int range 0 .. 10 = 10\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0015"), "inline-range half-open excludes hi: T0015")
}

func testInlineRefinedHalfOpenInBounds(): Unit {
  val src = "package P\nfunc f(): Unit {\n  val x: Int range 0 .. 10 = 9\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0015"), "inline-range half-open in-bounds: no T0015")
}

func testInlineRefinedBelowLo(): Unit {
  val src = "package P\nfunc f(): Unit {\n  val x: Int range 5 ..= 9 = 1\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0015"), "inline-range below lo: T0015")
}

func testInlineRefinedNegativeBounds(): Unit {
  val ok  = "package P\nfunc f(): Unit {\n  val x: Int range -5 ..= 5 = -3\n}\n"
  val bad = "package P\nfunc f(): Unit {\n  val x: Int range -5 ..= 5 = -9\n}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0015"), "neg-bound in-range: no T0015")
  assertTrue(hasDiagCode(parseCheck(bad), "T0015"), "neg-bound out-of-range: T0015")
}

func testInlineRefinedVarAndLet(): Unit {
  val v = "package P\nfunc f(): Unit {\n  var x: Int range 0 ..= 9 = 10\n}\n"
  val l = "package P\nfunc f(): Unit {\n  let x: Int range 0 ..= 9 = 10\n}\n"
  assertTrue(hasDiagCode(parseCheck(v), "T0015"), "var inline-range out-of-range: T0015")
  assertTrue(hasDiagCode(parseCheck(l), "T0015"), "let inline-range out-of-range: T0015")
}

func testRefinementTransparentToEquiv(): Unit {
  // Gate-safety: a refined type is equivalent to its underlying.  An
  // in-bounds refined binding whose declared type differs only by the
  // refinement layer must produce zero type-equivalence diagnostics
  // (no T0060/T0015) — refinements add no equivalence false positives.
  val src =
    "package P\n" +
    "func f(): Unit {\n" +
    "  val a: Int range 0 ..= 100 = 42\n" +
    "  val b: Int = a\n" +
    "  val c: Int range 0 ..= 100 = b\n" +
    "}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "refinement transparency: zero diagnostics")
}

func testInlineRefinedNonLiteralNotChecked(): Unit {
  // The inline check only fires for statically-known integer literals;
  // a non-literal initialiser (here a parameter) is not range-checked
  // at compile time (that is runtime / Band-4 construction validation).
  val src =
    "package P\n" +
    "func f(n: in Int): Unit {\n" +
    "  val x: Int range 0 ..= 9 = n\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0015"), "non-literal init: no compile-time T0015")
}

// #1483 (Band-1): match exhaustiveness (T0016).  EMatch now infers the
// scrutinee and verifies every possible value is matched, for union / enum /
// Bool / unbounded-scalar scrutinees.  A bare `case Foo` counts as covering
// case `Foo` only when `Foo` names a case of the scrutinee type (matching
// codegen); otherwise it is an irrefutable variable bind (catch-all).

func testMatchUnionExhaustive(): Unit {
  val src =
    "package P\n" +
    "union Shape { case Circle(r: Int); case Square(s: Int); case Tri }\n" +
    "func area(sh: in Shape): Int {\n" +
    "  match sh { case Circle(r) -> r; case Square(s) -> s; case Tri -> 0 }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0016"), "union all-cases: no T0016")
}

func testMatchUnionNonExhaustive(): Unit {
  val src =
    "package P\n" +
    "union Shape { case Circle(r: Int); case Square(s: Int); case Tri }\n" +
    "func area(sh: in Shape): Int {\n" +
    "  match sh { case Circle(r) -> r; case Square(s) -> s }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0016"), "union missing case: T0016")
}

func testMatchUnionWildcard(): Unit {
  val src =
    "package P\n" +
    "union Shape { case Circle(r: Int); case Square(s: Int); case Tri }\n" +
    "func area(sh: in Shape): Int {\n" +
    "  match sh { case Circle(r) -> r; case _ -> 0 }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0016"), "union wildcard: no T0016")
}

func testMatchUnionBareNameBind(): Unit {
  // A bare name that is NOT a case of the scrutinee is a variable bind
  // (catch-all), so the match is exhaustive.
  val src =
    "package P\n" +
    "union Shape { case Circle(r: Int); case Square(s: Int); case Tri }\n" +
    "func area(sh: in Shape): Int {\n" +
    "  match sh { case Circle(r) -> r; case other -> 0 }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0016"), "union bare-name bind catch-all: no T0016")
}

func testMatchUnionNullaryBareCase(): Unit {
  // A bare `case Tri` (nullary) covers case Tri — proving bare-name cases are
  // resolved against the scrutinee's case set, not treated as a catch-all.
  val src =
    "package P\n" +
    "union Shape { case Circle(r: Int); case Tri }\n" +
    "func area(sh: in Shape): Int {\n" +
    "  match sh { case Tri -> 0 }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0016"), "union bare nullary case covers only Tri -> missing Circle: T0016")
}

func testMatchUnionGuardDoesNotCover(): Unit {
  // A guarded arm never counts toward coverage (the guard may fail).
  val src =
    "package P\n" +
    "union Shape { case Circle(r: Int); case Tri }\n" +
    "func area(sh: in Shape): Int {\n" +
    "  match sh { case Circle(r) if r > 0 -> r; case Tri -> 0 }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0016"), "guarded Circle arm does not cover -> T0016")
}

func testMatchEnumExhaustive(): Unit {
  val src =
    "package P\n" +
    "enum Color { case Red; case Green; case Blue }\n" +
    "func rank(c: in Color): Int {\n" +
    "  match c { case Red -> 1; case Green -> 2; case Blue -> 3 }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0016"), "enum all-cases: no T0016")
}

func testMatchEnumNonExhaustive(): Unit {
  val src =
    "package P\n" +
    "enum Color { case Red; case Green; case Blue }\n" +
    "func rank(c: in Color): Int {\n" +
    "  match c { case Red -> 1; case Green -> 2 }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0016"), "enum missing Blue: T0016")
}

func testMatchBoolExhaustive(): Unit {
  val src =
    "package P\n" +
    "func f(b: in Bool): Int { match b { case true -> 1; case false -> 0 } }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0016"), "bool true+false: no T0016")
}

func testMatchBoolNonExhaustive(): Unit {
  val src =
    "package P\n" +
    "func f(b: in Bool): Int { match b { case true -> 1 } }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0016"), "bool missing false: T0016")
}

func testMatchScalarNeedsWildcard(): Unit {
  val bad = "package P\nfunc f(n: in Int): Int { match n { case 0 -> 0; case 1 -> 1 } }\n"
  val ok  = "package P\nfunc f(n: in Int): Int { match n { case 0 -> 0; case _ -> 1 } }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0016"), "int match no wildcard: T0016")
  assertTrue(not hasDiagCode(parseCheck(ok), "T0016"), "int match with wildcard: no T0016")
}

func testMatchStringNeedsWildcard(): Unit {
  val src =
    "package P\n" +
    "func f(s: in String): Int { match s { case \"a\" -> 1; case \"b\" -> 2 } }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0016"), "string match no wildcard: T0016")
}

// #1483 (expression-typing split 2a): EPropagate now carries a real type
// instead of TyError, so downstream uses of `e?` are checked.

func testPropagateResultUnwrap(): Unit {
  val ok =
    "package P\nunion Result[T, E] { case Ok(value: T); case Err(error: E) }\n" +
    "func f(r: in Result[Int, String]): Unit { val n: Int = r? }\n"
  val bad =
    "package P\nunion Result[T, E] { case Ok(value: T); case Err(error: E) }\n" +
    "func f(r: in Result[Int, String]): Unit { val s: String = r? }\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0060"), "Result[Int,_]? -> Int: no T0060")
  assertTrue(hasDiagCode(parseCheck(bad), "T0060"), "Result[Int,_]? used as String: T0060")
}

func testPropagateOptionUnwrap(): Unit {
  val ok =
    "package P\nunion Option[T] { case Some(value: T); case None }\n" +
    "func f(o: in Option[Int]): Unit { val n: Int = o? }\n"
  val bad =
    "package P\nunion Option[T] { case Some(value: T); case None }\n" +
    "func f(o: in Option[Int]): Unit { val s: String = o? }\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0060"), "Option[Int]? -> Int: no T0060")
  assertTrue(hasDiagCode(parseCheck(bad), "T0060"), "Option[Int]? used as String: T0060")
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
  testYieldOutsideAsync()
  testAsyncGeneratorFlags()
  testHotAnnotationFlag()
  testQualifiedTypeResolvesViaImport()
  testQualifiedTypeUnknownEmitsT0014()
  testQualifiedTypeMisqualifiedResolvesPermissively()
  testRangeBoundLongMinValueFolds()
  testTyUserRendersDeclaredName()
  testFirstWinsOnImportFuncCollision()
  testInlineRefinedInBounds()
  testInlineRefinedAboveInclusive()
  testInlineRefinedAtInclusiveHi()
  testInlineRefinedHalfOpenExcludesHi()
  testInlineRefinedHalfOpenInBounds()
  testInlineRefinedBelowLo()
  testInlineRefinedNegativeBounds()
  testInlineRefinedVarAndLet()
  testRefinementTransparentToEquiv()
  testInlineRefinedNonLiteralNotChecked()
  testMatchUnionExhaustive()
  testMatchUnionNonExhaustive()
  testMatchUnionWildcard()
  testMatchUnionBareNameBind()
  testMatchUnionNullaryBareCase()
  testMatchUnionGuardDoesNotCover()
  testMatchEnumExhaustive()
  testMatchEnumNonExhaustive()
  testMatchBoolExhaustive()
  testMatchBoolNonExhaustive()
  testMatchScalarNeedsWildcard()
  testMatchStringNeedsWildcard()
  testPropagateResultUnwrap()
  testPropagateOptionUnwrap()
  println("typechecker self-test: ok")
}
