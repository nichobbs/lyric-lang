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

// #2142 prerequisite: a generic union-case constructor is typed as the parent
// union instantiated from the argument types — `Sm(value: String)` on
// `union Opt[T] { Sm(value: T) … }` is `Opt[String]`, not `TyError`.  The
// distinguishing case: an `Opt[Int]` return with an `Sm(value = "s")` body MUST
// mismatch (T0070) — were the constructor still `TyError`, it would unify.
func testGenericUnionCtorTyped(): Unit {
  val bad = "package P\nunion Opt[T] {\n  case Sm(value: T)\n  case Nn\n}\nfunc f(): Opt[Int] { Sm(value = \"s\") }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0070"), "union-ctor: Sm(String) is Opt[String], mismatches Opt[Int]")
  val ok = "package P\nunion Opt2[T] {\n  case Sm2(value: T)\n  case Nn2\n}\nfunc g(): Opt2[String] { Sm2(value = \"s\") }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "union-ctor-ok: Sm2(String) matches Opt2[String]")
}

// A no-field case (`Nn` — like `None`) has uninferable type args, so it is the
// parent union with `TyError` args and leniently matches any instantiation.
func testGenericUnionNullaryLenient(): Unit {
  val src = "package P\nunion Opt3[T] {\n  case Sm3(value: T)\n  case Nn3\n}\nfunc f(): Opt3[Int] { Nn3 }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "union-nullary: Nn3 leniently matches Opt3[Int]")
}

// #2142: a `match` used as a value takes the unified type of its arm bodies,
// with pattern variables bound to their destructured types.  Distinguishing
// case: `case Sm(v) -> v` binds `v : Int` (the case field instantiated against
// `Opt[Int]`), so a `String`-returning function whose other arm is `""` MUST
// mismatch (T0067) — were `v` still `TyError`, the arms would unify silently.
func testMatchBranchDestructuredMismatch(): Unit {
  val src = "package P\nunion Opt[T] {\n  case Sm(value: T)\n  case Nn\n}\nfunc f(o: in Opt[Int]): String {\n  match o {\n    case Sm(v) -> v\n    case Nn -> \"\"\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0067"), "match-destructure: Sm(v) binds v:Int, mismatches the String arm")
}

// Matching arms unify cleanly: `Sm(v) -> v` (Int) and `Nn -> 0` (Int) → Int.
func testMatchBranchClean(): Unit {
  val src = "package P\nunion Opt[T] {\n  case Sm(value: T)\n  case Nn\n}\nfunc f(o: in Opt[Int]): Int {\n  match o {\n    case Sm(v) -> v\n    case Nn -> 0\n  }\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "match-clean: Sm(v:Int) and Nn(0) unify to Int")
}

// A nullary case in pattern position (`case Nn`) must not shadow the `Nn`
// constructor used in the arm body — so the reconstruction round-trips and the
// match types as `Opt[Int]`.
func testMatchNullaryNoShadow(): Unit {
  val src = "package P\nunion Opt[T] {\n  case Sm(value: T)\n  case Nn\n}\nfunc f(o: in Opt[Int]): Opt[Int] {\n  match o {\n    case Sm(v) -> Sm(value = v)\n    case Nn -> Nn\n  }\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "match-no-shadow: case Nn does not shadow the Nn constructor")
}

// #1488 (B): a generic function's return type is instantiated from the
// argument types at the call site — `unwrapOr(o: Opt[T], d: T): T` called on an
// `Opt[Int]` returns `Int`, not the raw `TyVar("T")`.  A `String`-typed binding
// of the result must mismatch (T0060); were the return still `TyVar`, `typeEquiv`
// would treat it as a wildcard and the binding would pass silently.
func testGenericReturnInstantiatedMismatch(): Unit {
  val src = "package P\nunion Opt[T] {\n  case Sm(value: T)\n  case Nn\n}\ngeneric[T] func unwrapOr(o: in Opt[T], d: in T): T { d }\nfunc f(o: in Opt[Int]): Unit {\n  val s: String = unwrapOr(o, 0)\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0060"),
    "generic-return: unwrapOr(Opt[Int], Int) returns Int, mismatches String")
}

// The complementary clean case: the instantiated `Int` return is usable in an
// `Int` comparison.  Were the return still `TyVar("T")`, `T < 0` would raise
// T0033 (comparison of `T` and `Int`).
func testGenericReturnInstantiatedClean(): Unit {
  val src = "package P\nunion Opt[T] {\n  case Sm(value: T)\n  case Nn\n}\ngeneric[T] func unwrapOr(o: in Opt[T], d: in T): T { d }\nfunc f(o: in Opt[Int]): Bool {\n  unwrapOr(o, 0) < 0\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0,
    "generic-return: instantiated Int return compares cleanly with Int")
}

// #2228: a generic that occurs in multiple parameter positions resolves
// consistently — `pick(a: T, b: T): T` called with two `Int`s returns `Int`,
// so a `String` binding mismatches (T0060).  (When the occurrences disagree the
// inference falls back to `TyError`; that case is already a T0043 at the
// argument check, so it needs no separate assertion here.)
func testGenericMultiOccurrenceConsistent(): Unit {
  val src = "package P\ngeneric[T] func pick(a: in T, b: in T): T { a }\nfunc f(): Unit {\n  val s: String = pick(1, 2)\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0060"),
    "generic-multi: pick(Int, Int) returns Int, mismatches String")
}

// #1488 (A): `result` is a contextual keyword.  A user-declared local named
// `result` shadows the contract return-value reference, so its reads take the
// *binding's* type — not the enclosing function's return type.  Here `f`
// returns `Unit` but `result` holds a `String`; reading it into a `String`
// binding must be clean.  Before the fix, `result` typed as `Unit` (the return
// type), producing a spurious T0060.  Mirrors codegen, which already loads the
// `result` slot first (codegen.l:2833).
func testResultLocalShadowsKeyword(): Unit {
  val src = "package P\nfunc f(): Unit {\n  val result = \"hi\"\n  val s: String = result\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "result-local: a `val result` shadows the return-value keyword")
}

// The same shadow with a value type distinct from the return type the other
// way: `f` returns `Int`, `result` holds a `String`, and assigning `result`
// into an `Int` binding must now mismatch (T0060) — proving the read takes the
// String binding type, not the Int return type (which would spuriously pass).
func testResultLocalKeepsBindingType(): Unit {
  val src = "package P\nfunc f(): Int {\n  val result = \"hi\"\n  val n: Int = result\n  n\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0060"), "result-local: read takes the String binding type, not Int return type")
}

func testValTypeMismatch(): Unit {
  val src = "package P\nfunc f(): Unit {\n  val x: Int = \"oops\"\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0060"), "val-mismatch: T0060 emitted")
}

// D081 / #1943: a value-position `unsafe { … }` block has the type of its
// trailing expression, not the universal `TyError`.  Distinguishing case: an
// `unsafe { 5 }` body (`Int`) in a `String`-returning function MUST mismatch
// (T0070) — were the block still `TyError`, it would unify silently.
func testUnsafeBlockTyped(): Unit {
  val bad = "package P\nfunc f(): String { unsafe { 5 } }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0070"), "unsafe-block: Int trailing expr mismatches String return")
  val ok = "package P\nfunc g(): Int { unsafe { 5 } }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "unsafe-block-ok: Int trailing expr matches Int return")
}

// A block whose final statement is `return` has type `Never` (bottom), so a
// function whose body block diverges does not false-mismatch its return type.
func testDivergingBlockIsNever(): Unit {
  val src = "package P\nfunc f(): Int { unsafe { return 3 } }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "diverging-block: unsafe { return 3 } is Never, no mismatch")
}

// #1943: an `if`/`else` expression takes the unified type of its branches.
func testIfBranchesUnify(): Unit {
  val ok = "package P\nfunc f(c: in Bool): Int { if c { 1 } else { 2 } }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "if-unify: matching branches type as Int")
  val bad = "package P\nfunc f(c: in Bool): Int { if c { 1 } else { \"x\" } }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0067"), "if-mismatch: Int vs String branches rejected")
}

// An `if` without `else` is `Unit` — binding it to a typed `val` mismatches
// (were it still `TyError`, the binding would unify silently).
func testIfWithoutElseIsUnit(): Unit {
  val src = "package P\nfunc f(c: in Bool): Unit {\n  val x: String = if c { \"x\" }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0060"), "if-no-else: Unit value mismatches a String val binding")
}

// A diverging branch (`return`) is `Never` and is absorbed — the `if` takes the
// other branch's type, so this is a clean `Int`.
func testIfDivergingBranchAbsorbed(): Unit {
  val src = "package P\nfunc f(c: in Bool): Int { if c { 1 } else { return 0 } }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "if-diverge: else-return is Never, unifies to Int")
}

// When one branch produces no value (`Unit` — here a block ending in a `val`
// statement), the `if` is used statement-like: the branches need not agree and
// the result is `Unit`, so there is no spurious mismatch even though the other
// branch is `Int`.  (A statement-position `if c { x } else { stmt }` where `x`
// is a discarded non-`Unit` value is valid and pervasive — e.g. a branch ending
// in a value-returning call whose result is dropped.)
func testIfUnitBranchNoMismatch(): Unit {
  val src = "package P\nfunc f(c: in Bool): Unit {\n  if c { 1 } else { val x = 2 }\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "if-unit-branch: Int-vs-Unit branches are not a mismatch")
}

// #2127/#2129: a bare UpperCamelCase member-call receiver that does not resolve
// is treated as a module reference (e.g. a `Std.String as Str` alias that
// survived rewriting), so it does NOT emit T0020 …
func testUppercaseModuleReceiverLenient(): Unit {
  val src = "package P\nfunc f(): Int { Foo.bar() }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0020"), "upper-receiver: unresolved `Foo.bar()` does not error T0020")
}

// … but a lowercase receiver is a value, so a typo still surfaces its T0020 —
// the leniency must not swallow real unknown-name errors.
func testLowercaseReceiverStillErrors(): Unit {
  val src = "package P\nfunc f(): Int { stirng.bar() }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0020"), "lower-receiver: typo'd `stirng.bar()` still errors T0020")
}

// #1901: numeric/character conversion methods are typed as their target
// primitive, not the universal `TyError` unifier.  The distinguishing case:
// a `.toLong()` body in an `Int`-returning function MUST mismatch (T0070) —
// were the conversion still `TyError`, it would unify with `Int` and slip
// through silently.
func testConvMethodTypedAsTarget(): Unit {
  val src = "package P\nfunc f(x: in Int): Int { x.toLong() }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0070"), "conv-target: Int body of Long conversion is a mismatch")
}

func testConvMethodWideningAccepted(): Unit {
  val src = "package P\nfunc f(x: in Int): Long { x.toLong() }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "conv-widen: Int.toLong() in a Long context type-checks")
}

func testConvMethodNarrowingAccepted(): Unit {
  val src = "package P\nfunc g(x: in Long): Int { x.toInt() }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "conv-narrow: Long.toInt() in an Int context type-checks")
}

func testConvMethodOnNonNumericRejected(): Unit {
  val src = "package P\nfunc f(s: in String): Int { s.toInt() }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0103"), "conv-nonnumeric: String.toInt() rejected with T0103")
}

// #1901 part B: an index expression `recv[i]` carries the receiver's element
// type, not the universal `TyError`.  Distinguishing case: a `slice[Byte]`
// element returned where `Int` is expected MUST mismatch (T0070) — `Byte != Int`
// (no implicit widening) — whereas `TyError` would have unified silently.
func testIndexByteElementTyped(): Unit {
  val src = "package P\nfunc f(a: in slice[Byte]): Int { a[0] }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0070"), "index-byte: slice[Byte] element is Byte, mismatches Int return")
}

func testIndexByteWithConversionAccepted(): Unit {
  val src = "package P\nfunc f(a: in slice[Byte]): Int { a[0].toInt() }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "index-byte-conv: a[0].toInt() type-checks to Int")
}

// String indexing yields `Char`; a `Char` in a `Char`-returning function is
// clean, but in an `Int`-returning function it mismatches.
func testIndexStringElementIsChar(): Unit {
  val ok = "package P\nfunc f(s: in String): Char { s[0] }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "index-string-char: s[0] is Char")
  val bad = "package P\nfunc g(s: in String): Int { s[0] }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0070"), "index-string-int: Char element mismatches Int return")
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

// #1488 category C: two imported functions sharing a name and arity but
// differing in parameter type (the `Std.Char.toUpper(Char)` vs
// `Std.String.toUpper(String)` collision) must dispatch by argument type, not
// by first-in-wins.  `mk(String)` returns `Int`; `mk(Int)` returns `String`.
// A `String`-typed argument must select the `Int`-returning overload, so
// binding the call into an `Int` is clean and into a `String` mismatches.
func testOverloadDispatchByArgType(): Unit {
  val libSrc = "package Lib\npub func mk(s: in String): Int { 0 }\npub func mk(n: in Int): String { \"\" }\n"
  val libPr  = parse(libSrc)
  val importedItems: List[Item] = newList()
  var i = 0
  while i < libPr.file.items.count {
    importedItems.add(libPr.file.items[i])
    i = i + 1
  }
  // `mk("x")` selects `mk(String): Int`; the `Int` binding is clean.
  val okSrc = "package App\nfunc f(): Unit {\n  val n: Int = mk(\"x\")\n}\n"
  val okPr  = parse(okSrc)
  assertEqualInt(diagCount(checkWithImports(okPr.file, importedItems)), 0,
    "overload: mk(String) selects the Int-returning overload")
  // `mk(7)` selects `mk(Int): String`; binding into `Int` must mismatch (T0060),
  // proving the *other* overload was chosen — a first-in-wins map would have
  // returned the same overload for both calls.
  val badSrc = "package App\nfunc f(): Unit {\n  val n: Int = mk(7)\n}\n"
  val badPr  = parse(badSrc)
  assertTrue(hasDiagCode(checkWithImports(badPr.file, importedItems), "T0060"),
    "overload: mk(Int) selects the String-returning overload (mismatches Int)")
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

func testOpaqueConstructSamePackageWithDuplicateImportedSymbol(): Unit {
  // Regression test for same-package item shadowing in the typechecker.
  // When a package is compiled with imported stdlib items, the current file's
  // declarations appear after the imported items in the symbol table and
  // must therefore take precedence.
  val src =
    "package P\n" +
    "opaque type Secret { token: String }\n" +
    "func f(): Unit { val s = Secret(token = \"x\") }\n"
  val pr: ParseResult = parse(src)
  val importedItems: List[Item] = newList()
  var i = 0
  while i < pr.file.items.count {
    importedItems.add(pr.file.items[i])
    i = i + 1
  }
  val cr = checkWithImports(pr.file, importedItems)
  assertTrue(not hasDiagCode(cr, "T0100"),
    "same-package opaque construction with duplicate imported symbol: no T0100")
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

func testInlineRefinedUpperOpenBelowLo(): Unit {
  // Upper-open `range 5 ..`: 3 is below the lower bound — T0015.
  val src = "package P\nfunc f(): Unit {\n  val x: Int range 5 .. = 3\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0015"),
    "upper-open below lo: T0015")
}

func testInlineRefinedUpperOpenAtLo(): Unit {
  // Upper-open `range 5 ..`: 5 is at the lower bound, no upper to check.
  val src = "package P\nfunc f(): Unit {\n  val x: Int range 5 .. = 5\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0015"),
    "upper-open at lo: no T0015")
}

func testInlineRefinedLowerOpenAboveHi(): Unit {
  // Lower-open `range ..= 9`: 12 is above the inclusive upper bound — T0015.
  val src = "package P\nfunc f(): Unit {\n  val x: Int range ..= 9 = 12\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0015"),
    "lower-open above hi: T0015")
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

func testMatchGenericUnionExhaustive(): Unit {
  // Generic-union scrutinees (`Option[Int]`) should resolve to the union
  // declaration via `typeIdEq` regardless of type arguments.
  val ok =
    "package P\nunion Option[T] { case Some(value: T); case None }\n" +
    "func f(o: in Option[Int]): Int {\n" +
    "  match o { case Some(x) -> x; case None -> 0 }\n" +
    "}\n"
  val bad =
    "package P\nunion Option[T] { case Some(value: T); case None }\n" +
    "func f(o: in Option[Int]): Int {\n" +
    "  match o { case Some(x) -> x }\n" +
    "}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0016"), "Option[Int] all cases: no T0016")
  assertTrue(hasDiagCode(parseCheck(bad), "T0016"), "Option[Int] missing None: T0016")
}

func testMatchOrPatternExhaustive(): Unit {
  // POr arms enumerate multiple union cases at once.
  val ok =
    "package P\n" +
    "union Shape { case Circle; case Square; case Tri }\n" +
    "func area(sh: in Shape): Int {\n" +
    "  match sh { case Circle | Square -> 0; case Tri -> 1 }\n" +
    "}\n"
  val bad =
    "package P\n" +
    "union Shape { case Circle; case Square; case Tri }\n" +
    "func area(sh: in Shape): Int {\n" +
    "  match sh { case Circle | Square -> 0 }\n" +
    "}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0016"), "Or-pattern + Tri: no T0016")
  assertTrue(hasDiagCode(parseCheck(bad), "T0016"), "Or-pattern missing Tri: T0016")
}

func testMatchAtBindExhaustive(): Unit {
  // `case x@Circle(r)` should credit `Circle` to the coverage set via the
  // `Some(inner)` branch of `collectCoveredCases`.
  val src =
    "package P\n" +
    "union Shape { case Circle(r: Int); case Square(s: Int); case Tri }\n" +
    "func area(sh: in Shape): Int {\n" +
    "  match sh { case x@Circle(r) -> r; case Square(s) -> s; case Tri -> 0 }\n" +
    "}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0016"),
    "@-bound Circle covers union case: no T0016")
  val bad =
    "package P\n" +
    "union Shape { case Circle(r: Int); case Square(s: Int); case Tri }\n" +
    "func area(sh: in Shape): Int {\n" +
    "  match sh { case x@Circle(r) -> r }\n" +
    "}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0016"),
    "@-bound Circle alone leaves Square/Tri uncovered: T0016")
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

func testPropagateNonMonadicNoT0060(): Unit {
  val src =
    "package P\n" +
    "func f(n: in Int): Unit { val _x = n? }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0060"),
    "non-monadic ? yields TyError: no T0060 cascade")
}

// #1484: visibility enforcement at use sites.  Per language reference §3.1,
// `pub` and `internal` are visible across packages within a project; an
// unmarked (package-private) symbol is not.  A cross-package reference to a
// package-private imported symbol is rejected with T0097.  (The V0007/V0008
// codes suggested in the issue are already owned by the verifier.)

func importedItemsOf(libSrc: in String): List[Item] {
  val libPr = parse(libSrc)
  val items: List[Item] = newList()
  var i = 0
  while i < libPr.file.items.count {
    items.add(libPr.file.items[i])
    i = i + 1
  }
  items
}

func testVisibilityPubTypeAllowed(): Unit {
  val imp = importedItemsOf("package Lib\npub record Widget { x: Int }\n")
  val pr  = parse("package App\nfunc f(w: in Widget): Int { 0 }\n")
  val cr  = checkWithImports(pr.file, imp)
  assertTrue(not hasDiagCode(cr, "T0097"), "pub imported type: no T0097")
}

func testVisibilityInternalTypeAllowed(): Unit {
  // `internal` is visible across packages within a project.
  val imp = importedItemsOf("package Lib\ninternal record Widget { x: Int }\n")
  val pr  = parse("package App\nfunc f(w: in Widget): Int { 0 }\n")
  val cr  = checkWithImports(pr.file, imp)
  assertTrue(not hasDiagCode(cr, "T0097"), "internal imported type cross-package: no T0097")
}

func testVisibilityPrivateTypeRejected(): Unit {
  val imp = importedItemsOf("package Lib\nrecord Widget { x: Int }\n")
  val pr  = parse("package App\nfunc f(w: in Widget): Int { 0 }\n")
  val cr  = checkWithImports(pr.file, imp)
  assertTrue(hasDiagCode(cr, "T0097"), "package-private imported type referenced cross-package: T0097")
}

func testVisibilityPubFuncAllowed(): Unit {
  val imp = importedItemsOf("package Lib\npub func helper(x: in Int): Int { x }\n")
  val pr  = parse("package App\nfunc f(): Int { helper(3) }\n")
  val cr  = checkWithImports(pr.file, imp)
  assertTrue(not hasDiagCode(cr, "T0097"), "pub imported func: no T0097")
}

func testVisibilityPrivateFuncRejected(): Unit {
  val imp = importedItemsOf("package Lib\nfunc helper(x: in Int): Int { x }\n")
  val pr  = parse("package App\nfunc f(): Int { helper(3) }\n")
  val cr  = checkWithImports(pr.file, imp)
  assertTrue(hasDiagCode(cr, "T0097"), "package-private imported func referenced cross-package: T0097")
}

func testVisibilityExternTypeAllowed(): Unit {
  // Extern types are FFI-boundary bindings (no `pub`), but are referenced
  // directly across packages (e.g. `List`/`Map`).  They must not be flagged.
  val imp = importedItemsOf("package Lib\nextern type Box = \"System.Object\"\n")
  val pr  = parse("package App\nfunc f(b: in Box): Int { 0 }\n")
  val cr  = checkWithImports(pr.file, imp)
  assertTrue(not hasDiagCode(cr, "T0097"), "extern type cross-package: no T0097 (FFI boundary)")
}

func testVisibilitySamePackageUnaffected(): Unit {
  // A package-private symbol referenced within the same package (not imported)
  // must never be flagged.
  val src =
    "package P\n" +
    "record Widget { x: Int }\n" +
    "func helper(n: in Int): Int { n }\n" +
    "func f(w: in Widget): Int { helper(w.x) }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0097"), "same-package private ref: no T0097")
}

// #1486: impl/interface structural conformance — every abstract interface
// method must be implemented (T0098) with matching parameter arity (T0099).

func testImplConforming(): Unit {
  val src =
    "package P\n" +
    "interface Greeter { func greet(name: in String): String }\n" +
    "record G {}\n" +
    "impl Greeter for G { func greet(name: in String): String { name } }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0098"), "conforming impl: no T0098")
  assertTrue(not hasDiagCode(cr, "T0099"), "conforming impl: no T0099")
}

func testImplMissingMethod(): Unit {
  val src =
    "package P\n" +
    "interface Greeter { func greet(name: in String): String }\n" +
    "record G {}\n" +
    "impl Greeter for G {}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0098"), "impl missing abstract method: T0098")
}

func testImplArityMismatch(): Unit {
  val src =
    "package P\n" +
    "interface Greeter { func greet(name: in String): String }\n" +
    "record G {}\n" +
    "impl Greeter for G { func greet(): String { \"hi\" } }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0099"), "impl method arity mismatch: T0099")
}

func testImplDefaultMethodOptional(): Unit {
  // An interface method WITH a body is a default (IMFunc) — an impl need not
  // override it, so omitting it must not produce T0098.
  val src =
    "package P\n" +
    "interface Greeter { func greet(name: in String): String { \"hi \" + name } }\n" +
    "record G {}\n" +
    "impl Greeter for G {}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0098"), "default interface method not required: no T0098")
}

// #1487 (§5.2): `in` parameters (and `val`/`let`) are immutable and cannot be
// reassigned (T0087); `var` locals and `out`/`inout` params are mutable.

func testInParamNoRebind(): Unit {
  val src = "package P\nfunc f(x: in Int): Unit { x = 5 }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0087"), "reassigning an `in` param: T0087")
}

func testValNoReassign(): Unit {
  val src = "package P\nfunc f(): Unit {\n  val x = 1\n  x = 2\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0087"), "reassigning a `val`: T0087")
}

func testVarReassignOk(): Unit {
  val src = "package P\nfunc f(): Unit {\n  var x = 1\n  x = 2\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0087"), "reassigning a `var`: no T0087")
}

func testOutParamReassignOk(): Unit {
  // `out` params are mutable (they must be assigned), so assigning is fine.
  val src = "package P\nfunc f(x: out Int): Unit { x = 5 }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0087"), "assigning an `out` param: no T0087")
}

func testInoutParamReassignOk(): Unit {
  val src = "package P\nfunc f(x: inout Int): Unit { x = 5 }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0087"), "assigning an `inout` param: no T0087")
}

// #1487 (§5.2): an argument bound to an `out`/`inout` parameter must be a
// mutable l-value (T0085); `in` arguments may be any expression.

func testOutArgMutableOk(): Unit {
  val src = "package P\nfunc g(x: out Int): Unit { x = 5 }\nfunc f(): Unit {\n  var y = 0\n  g(y)\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0085"), "out arg is a var: no T0085")
}

func testOutArgImmutableRejected(): Unit {
  val src = "package P\nfunc g(x: out Int): Unit { x = 5 }\nfunc f(): Unit {\n  val y = 0\n  g(y)\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0085"), "out arg is a val: T0085")
}

func testOutArgLiteralRejected(): Unit {
  val src = "package P\nfunc g(x: out Int): Unit { x = 5 }\nfunc f(): Unit { g(0) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0085"), "out arg is a literal: T0085")
}

func testInoutArgMutableOk(): Unit {
  val src = "package P\nfunc g(x: inout Int): Unit { x = 5 }\nfunc f(): Unit {\n  var y = 0\n  g(y)\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0085"), "inout arg is a var: no T0085")
}

func testInArgAnyExprOk(): Unit {
  val src = "package P\nfunc g(x: in Int): Unit {}\nfunc f(): Unit { g(0) }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0085"), "in arg literal: no T0085")
}

// #1483 (record-ctor) / #1485 (opaque hiding): a record/opaque construction
// call now yields the constructed type (non-generic records); a named argument
// must reference a real field (T0101); an opaque type cannot be constructed
// outside its declaring package (T0100).

func testCtorReturnsRecordType(): Unit {
  val ok  = "package P\nrecord Point { x: Int; y: Int }\nfunc f(): Unit { val p: Point = Point(x = 1, y = 2) }\n"
  val bad = "package P\nrecord Point { x: Int; y: Int }\nfunc f(): Unit { val q: Int = Point(x = 1, y = 2) }\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0060"), "ctor returns the record type: no T0060")
  assertTrue(hasDiagCode(parseCheck(bad), "T0060"), "record ctor used as Int: T0060")
}

func testCtorUnknownField(): Unit {
  val src = "package P\nrecord Point { x: Int; y: Int }\nfunc f(): Unit { val p = Point(z = 3) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0101"), "unknown ctor field: T0101")
}

func testCtorKnownFieldsOk(): Unit {
  val src = "package P\nrecord Point { x: Int; y: Int }\nfunc f(): Unit { val p = Point(x = 1, y = 2) }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0101"), "known ctor fields: no T0101")
}

func testOpaqueConstructCrossPackage(): Unit {
  val imp = importedItemsOf("package Lib\npub opaque type Secret { token: String }\n")
  val pr  = parse("package App\nfunc f(): Unit { val s = Secret(token = \"x\") }\n")
  val cr  = checkWithImports(pr.file, imp)
  assertTrue(hasDiagCode(cr, "T0100"), "opaque construction cross-package: T0100")
}

func testOpaqueConstructSamePackage(): Unit {
  val src = "package P\nopaque type Secret { token: String }\nfunc f(): Unit { val s = Secret(token = \"x\") }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0100"), "opaque construction same-package: no T0100")
}

// #1485: pattern-matching an opaque type's representation (record/constructor
// pattern) is forbidden outside its declaring package (T0102); binding /
// wildcard arms remain legal.

func testOpaquePatternMatchCrossPackage(): Unit {
  val imp = importedItemsOf("package Lib\npub opaque type Box { item: Int }\n")
  val pr  = parse("package App\nfunc f(b: in Box): Int { match b { case Box(x) -> 1; case _ -> 0 } }\n")
  val cr  = checkWithImports(pr.file, imp)
  assertTrue(hasDiagCode(cr, "T0102"), "cross-package opaque representation match: T0102")
}

func testOpaqueBindingMatchCrossPackageOk(): Unit {
  val imp = importedItemsOf("package Lib\npub opaque type Box { item: Int }\n")
  val pr  = parse("package App\nfunc f(b: in Box): Int { match b { case other -> 0 } }\n")
  val cr  = checkWithImports(pr.file, imp)
  assertTrue(not hasDiagCode(cr, "T0102"), "cross-package opaque binding match: no T0102")
}

func testOpaquePatternMatchSamePackageOk(): Unit {
  val src = "package P\nopaque type Box { item: Int }\nfunc f(b: in Box): Int { match b { case Box(x) -> 1; case _ -> 0 } }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0102"), "same-package opaque destructure: no T0102")
}

// #1487 (§5.2): an `out` parameter must be assigned before the function
// returns; one never assigned anywhere in the body is rejected (T0086).

func testOutAssignedOk(): Unit {
  val src = "package P\nfunc f(x: out Int): Unit { x = 5 }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0086"), "out param assigned: no T0086")
}

func testOutNeverAssigned(): Unit {
  val src = "package P\nfunc f(x: out Int): Unit { val y = 1 }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0086"), "out param never assigned: T0086")
}

func testOutAssignedInBranchesOk(): Unit {
  val src = "package P\nfunc f(c: in Bool, x: out Int): Unit { if c { x = 1 } else { x = 2 } }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0086"), "out assigned in if-branches: no T0086")
}

func testOutAssignedInLoopOk(): Unit {
  val src = "package P\nfunc f(x: out Int): Unit {\n  var i = 0\n  while i < 3 { x = i; i = i + 1 }\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0086"), "out assigned in loop body: no T0086")
}

func testInParamNoOutCheck(): Unit {
  val src = "package P\nfunc f(x: in Int): Unit { val y = 1 }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0086"), "in param: no T0086")
}

func main(): Unit {
  testEmptySource()
  testFuncRegistered()
  testFuncSigResolved()
  testRecordRegistered()
  testUnionCasesRegistered()
  testDuplicateNameError()
  testReturnTypeMismatch()
  testGenericUnionCtorTyped()
  testGenericUnionNullaryLenient()
  testMatchBranchDestructuredMismatch()
  testMatchBranchClean()
  testMatchNullaryNoShadow()
  testGenericReturnInstantiatedMismatch()
  testGenericReturnInstantiatedClean()
  testGenericMultiOccurrenceConsistent()
  testResultLocalShadowsKeyword()
  testResultLocalKeepsBindingType()
  testValTypeMismatch()
  testUnsafeBlockTyped()
  testDivergingBlockIsNever()
  testIfBranchesUnify()
  testIfWithoutElseIsUnit()
  testIfDivergingBranchAbsorbed()
  testIfUnitBranchNoMismatch()
  testUppercaseModuleReceiverLenient()
  testLowercaseReceiverStillErrors()
  testConvMethodTypedAsTarget()
  testConvMethodWideningAccepted()
  testConvMethodNarrowingAccepted()
  testConvMethodOnNonNumericRejected()
  testIndexByteElementTyped()
  testIndexByteWithConversionAccepted()
  testIndexStringElementIsChar()
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
  testOverloadDispatchByArgType()
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
  testInlineRefinedUpperOpenBelowLo()
  testInlineRefinedUpperOpenAtLo()
  testInlineRefinedLowerOpenAboveHi()
  testRefinementTransparentToEquiv()
  testInlineRefinedNonLiteralNotChecked()
  testMatchUnionExhaustive()
  testMatchUnionNonExhaustive()
  testMatchUnionWildcard()
  testMatchUnionBareNameBind()
  testMatchUnionNullaryBareCase()
  testMatchUnionGuardDoesNotCover()
  testMatchGenericUnionExhaustive()
  testMatchOrPatternExhaustive()
  testMatchAtBindExhaustive()
  testMatchEnumExhaustive()
  testMatchEnumNonExhaustive()
  testMatchBoolExhaustive()
  testMatchBoolNonExhaustive()
  testMatchScalarNeedsWildcard()
  testMatchStringNeedsWildcard()
  testPropagateResultUnwrap()
  testPropagateOptionUnwrap()
  testPropagateNonMonadicNoT0060()
  testVisibilityPubTypeAllowed()
  testVisibilityInternalTypeAllowed()
  testVisibilityPrivateTypeRejected()
  testVisibilityPubFuncAllowed()
  testVisibilityPrivateFuncRejected()
  testVisibilityExternTypeAllowed()
  testVisibilitySamePackageUnaffected()
  testImplConforming()
  testImplMissingMethod()
  testImplArityMismatch()
  testImplDefaultMethodOptional()
  testInParamNoRebind()
  testValNoReassign()
  testVarReassignOk()
  testOutParamReassignOk()
  testInoutParamReassignOk()
  testOutArgMutableOk()
  testOutArgImmutableRejected()
  testOutArgLiteralRejected()
  testInoutArgMutableOk()
  testInArgAnyExprOk()
  testCtorReturnsRecordType()
  testCtorUnknownField()
  testCtorKnownFieldsOk()
  testOpaqueConstructCrossPackage()
  testOpaqueConstructSamePackage()
  testOpaquePatternMatchCrossPackage()
  testOpaqueBindingMatchCrossPackageOk()
  testOpaquePatternMatchSamePackageOk()
  testOutAssignedOk()
  testOutNeverAssigned()
  testOutAssignedInBranchesOk()
  testOutAssignedInLoopOk()
  testInParamNoOutCheck()
  println("typechecker self-test: ok")
}
