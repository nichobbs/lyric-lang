//! typechecker_self_test.l — exercises the self-hosted Lyric.TypeChecker library.
//! Run in CI via native `lyric test` (no F# runner shim).
@test_module
package Lyric.TypeCheckerSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Testing
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.AliasRewriter
import Lyric.Pipeline
import Lyric.TypeAliasResolve as TAR
import Lyric.BareFuncRef as BFR

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
    if cr.diagnostics[i].code == code {
      return true
    }
    i = i + 1
  }
  false
}

// #6540: how many diagnostics carry `code` — used where a fix's whole point
// is that a diagnostic fires EXACTLY ONCE per site (a redundant emission
// path duplicating it would still pass a bare `hasDiagCode` check).
func countDiagCode(cr: in CheckResult, code: in String): Int {
  var i = 0
  var n = 0
  while i < cr.diagnostics.count {
    if cr.diagnostics[i].code == code {
      n = n + 1
    }
    i = i + 1
  }
  n
}

// The message of the first diagnostic with `code`, or "" when absent.
func diagMessageFor(cr: in CheckResult, code: in String): String {
  var i = 0
  while i < cr.diagnostics.count {
    if cr.diagnostics[i].code == code {
      return cr.diagnostics[i].message
    }
    i = i + 1
  }
  ""
}

// #6418: mirrors the real per-target pipeline's alias-resolution step
// (`Msil.Bridge.resolveTypeAliasesMsil` / `Jvm.Bridge.resolveTypeAliases`,
// both `Lyric.TypeAliasResolve.resolveAliasesInFile` over
// `Lyric.BareFuncRef.collectFuncAliasTargets`), so a checker-level test can
// observe its effect. Plain `parseCheck` alone runs only the checker's OWN
// independent `DKTypeAlias` symbol-table resolution — correct for pass/fail
// (the language reference's "alias is fully transparent" guarantee), but it
// never stamps `TypeExpr.aliasName`, so a display-name assertion needs this
// wrapper instead.
func parseCheckAliasResolved(src: in String): CheckResult {
  val pr = parse(src)
  val resolved = TAR.resolveAliasesInFile(BFR.collectFuncAliasTargets(pr.file), pr.file)
  check(resolved)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────
test "empty source" {
  val cr = parseCheck("")
  assertEqualInt(diagCount(cr), 0, "empty: no diagnostics")
  assertEqualInt(symCount(cr), 0, "empty: no symbols")
}

test "func registered" {
  val src = "package P\nfunc add(x: in Int, y: in Int): Int { x + y }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "func-reg: no diagnostics")
  assertTrue(symCount(cr) > 0, "func-reg: symbol registered")
}

test "func sig resolved" {
  val src = "package P\nfunc double(n: in Int): Int { n + n }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "sig: no diagnostics")
  assertTrue(cr.sigs.containsKey("double"), "sig: bare key present")
  assertTrue(cr.sigs.containsKey("double/1"), "sig: arity key present")
}

test "record registered" {
  val src = "package P\nrecord Point { x: Int; y: Int }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "rec-reg: no diagnostics")
  assertTrue(symCount(cr) > 0, "rec-reg: symbol registered")
}

test "union cases registered" {
  val src = "package P\nunion Color { case Red; case Green; case Blue }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "union-cases: no diagnostics")
  // union + 3 cases = 4 symbols
  assertEqualInt(symCount(cr), 4, "union-cases: 4 symbols")
}

test "duplicate name error" {
  val src = "package P\nrecord A { x: Int }\nrecord A { y: String }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0001"), "dup: T0001 emitted")
}

test "return type mismatch" {
  val src = "package P\nfunc f(): Int { \"hello\" }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0070"), "ret-mismatch: T0070 emitted")
}

// #2142 prerequisite: a generic union-case constructor is typed as the parent
// union instantiated from the argument types — `Sm(value: String)` on
// `union Opt[T] { Sm(value: T) … }` is `Opt[String]`, not `TyError`.  The
// distinguishing case: an `Opt[Int]` return with an `Sm(value = "s")` body MUST
// mismatch (T0070) — were the constructor still `TyError`, it would unify.
test "generic union ctor typed" {
  val bad = "package P\nunion Opt[T] {\n  case Sm(value: T)\n  case Nn\n}\nfunc f(): Opt[Int] { Sm(value = \"s\") }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0070"), "union-ctor: Sm(String) is Opt[String], mismatches Opt[Int]")
  val ok = "package P\nunion Opt2[T] {\n  case Sm2(value: T)\n  case Nn2\n}\nfunc g(): Opt2[String] { Sm2(value = \"s\") }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "union-ctor-ok: Sm2(String) matches Opt2[String]")
}

// A no-field case (`Nn` — like `None`) has uninferable type args, so it is the
// parent union with `TyError` args and leniently matches any instantiation.
test "generic union nullary lenient" {
  val src = "package P\nunion Opt3[T] {\n  case Sm3(value: T)\n  case Nn3\n}\nfunc f(): Opt3[Int] { Nn3 }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "union-nullary: Nn3 leniently matches Opt3[Int]")
}

// #2142: a `match` used as a value takes the unified type of its arm bodies,
// with pattern variables bound to their destructured types.  Distinguishing
// case: `case Sm(v) -> v` binds `v : Int` (the case field instantiated against
// `Opt[Int]`), so a `String`-returning function whose other arm is `""` MUST
// mismatch (T0067) — were `v` still `TyError`, the arms would unify silently.
test "match branch destructured mismatch" {
  val src = "package P\nunion Opt[T] {\n  case Sm(value: T)\n  case Nn\n}\nfunc f(o: in Opt[Int]): String {\n  match o {\n    case Sm(v) -> v\n    case Nn -> \"\"\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0067"), "match-destructure: Sm(v) binds v:Int, mismatches the String arm")
}

// Matching arms unify cleanly: `Sm(v) -> v` (Int) and `Nn -> 0` (Int) → Int.
test "match branch clean" {
  val src = "package P\nunion Opt[T] {\n  case Sm(value: T)\n  case Nn\n}\nfunc f(o: in Opt[Int]): Int {\n  match o {\n    case Sm(v) -> v\n    case Nn -> 0\n  }\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "match-clean: Sm(v:Int) and Nn(0) unify to Int")
}

// A nullary case in pattern position (`case Nn`) must not shadow the `Nn`
// constructor used in the arm body — so the reconstruction round-trips and the
// match types as `Opt[Int]`.
test "match nullary no shadow" {
  val src = "package P\nunion Opt[T] {\n  case Sm(value: T)\n  case Nn\n}\nfunc f(o: in Opt[Int]): Opt[Int] {\n  match o {\n    case Sm(v) -> Sm(value = v)\n    case Nn -> Nn\n  }\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "match-no-shadow: case Nn does not shadow the Nn constructor")
}

// #2514: a concrete record returned where its implemented interface is
// expected upcasts cleanly, including through a generic head — a `match`
// that re-wraps a `Result[Int, String]` into `Result[Conn, DErr]` whose
// `Ok` arm yields `Ok(NC(...))` (NC implements Conn) must NOT mismatch.
// This is the lyric-db `connect(): Result[DbConnection, DbError]` shape.
test "interface upcast in result" {
  // Inline `Res[T, E]` stands in for `Result[T, E]` so the check is
  // self-contained (no Std.Core import).  The `Ok2` arm yields a concrete
  // `NC` where the declared `Res[Conn, DErr]` expects `Conn`; the `Err2`
  // arm fixes `E = DErr`.  Branch unification leaves the body as
  // `Res[NC, <error>]`, so the return-type check must accept it via
  // covariant interface subsumption (NC implements Conn) without a T0070.
  val prelude = "package P\npub interface Conn {\n  func q(): Int\n}\nrecord NC {\n  id: Int\n}\nimpl Conn for NC {\n  func q(): Int { return self.id }\n}\nrecord DErr {\n  msg: String\n}\nunion Res[T, E] {\n  case Ok2(value: T)\n  case Err2(err: E)\n}\n"
  val ok = prelude +
    "func connect(c: in Res[Int, String]): Res[Conn, DErr] {\n  match c {\n    case Ok2(cid) -> Ok2(value = NC(id = cid))\n    case Err2(m) -> Err2(err = DErr(msg = m))\n  }\n}\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "iface-upcast: NC upcasts to Conn inside Res")
}

// #2514: Rust-style integer-literal inference — an unsuffixed integer
// literal adopts the concrete integer type required by context, so
// `someLong <= 0`, `someLong + 1`, and a `colLong`-style match whose
// `case _ -> 0` default sits beside `Long` arms all type-check without a
// `0i64` suffix.
test "int literal adopts context" {
  val cmp = "package P\npub func f(x: in Long): Bool {\n  x <= 0\n}\n"
  assertEqualInt(diagCount(parseCheck(cmp)), 0, "int-lit: Long <= 0 type-checks")
  val arith = "package P\npub func g(x: in Long): Long {\n  return x + 1\n}\n"
  assertEqualInt(diagCount(parseCheck(arith)), 0, "int-lit: Long + 1 type-checks")
  val branch = "package P\npub func h(b: in Bool, v: in Long): Long {\n  if b {\n    v\n  } else {\n    0\n  }\n}\n"
  assertEqualInt(diagCount(parseCheck(branch)), 0, "int-lit: if-branch Long/0 widens to Long")
}

// Guard branch widening against over-reach: a genuinely incompatible pair
// (String vs Int) must still raise T0067, not silently unify.
test "branch widen still rejects mismatch" {
  val bad = "package P\npub func f(b: in Bool): Int {\n  if b {\n    1\n  } else {\n    \"x\"\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0067"), "branch-widen: Int vs String still T0067")
}

// Guard the assignability relation against over-leniency: a record that
// does NOT implement the expected interface must still mismatch (T0070).
test "unrelated return still mismatches" {
  val bad = "package P\npub interface Conn {\n  func q(): Int\n}\nrecord Other {\n  x: Int\n}\nfunc f(): Conn { Other(x = 1) }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0070"), "no-impl: Other does not implement Conn → T0070")
}

// #1488: a range subtype (`Int range 0 ..= 150`) is numeric and ordered when
// its underlying representation is, so arithmetic and comparison on a
// range-typed value type-check cleanly.  Before `isNumericType`/`isOrderedType`
// unwrapped `TyRefined`, `a + 1` / `a < 100` raised a spurious T0030/T0033.
test "range subtype arithmetic" {
  val src = "package P\nfunc f(a: in Int range 0 ..= 150): Bool {\n  val n = a + 1\n  a < 100\n}\n"
  assertEqualInt(
    diagCount(parseCheck(src)),
    0,
    "range-subtype: arithmetic and comparison on `Int range 0 ..= 150` are clean"
  )
}

// #1488 (B): a generic function's return type is instantiated from the
// argument types at the call site — `unwrapOr(o: Opt[T], d: T): T` called on an
// `Opt[Int]` returns `Int`, not the raw `TyVar("T")`.  A `String`-typed binding
// of the result must mismatch (T0060); were the return still `TyVar`, `typeEquiv`
// would treat it as a wildcard and the binding would pass silently.
test "generic return instantiated mismatch" {
  val src = "package P\nunion Opt[T] {\n  case Sm(value: T)\n  case Nn\n}\ngeneric[T] func unwrapOr(o: in Opt[T], d: in T): T { d }\nfunc f(o: in Opt[Int]): Unit {\n  val s: String = unwrapOr(o, 0)\n}\n"
  assertTrue(
    hasDiagCode(parseCheck(src), "T0060"),
    "generic-return: unwrapOr(Opt[Int], Int) returns Int, mismatches String"
  )
}

// The complementary clean case: the instantiated `Int` return is usable in an
// `Int` comparison.  Were the return still `TyVar("T")`, `T < 0` would raise
// T0033 (comparison of `T` and `Int`).
test "generic return instantiated clean" {
  val src = "package P\nunion Opt[T] {\n  case Sm(value: T)\n  case Nn\n}\ngeneric[T] func unwrapOr(o: in Opt[T], d: in T): T { d }\nfunc f(o: in Opt[Int]): Bool {\n  unwrapOr(o, 0) < 0\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "generic-return: instantiated Int return compares cleanly with Int")
}

// #2228: a generic that occurs in multiple parameter positions resolves
// consistently — `pick(a: T, b: T): T` called with two `Int`s returns `Int`,
// so a `String` binding mismatches (T0060).  (When the occurrences disagree the
// inference falls back to `TyError`; that case is already a T0043 at the
// argument check, so it needs no separate assertion here.)
test "generic multi occurrence consistent" {
  val src = "package P\ngeneric[T] func pick(a: in T, b: in T): T { a }\nfunc f(): Unit {\n  val s: String = pick(1, 2)\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0060"), "generic-multi: pick(Int, Int) returns Int, mismatches String")
}

// #1488 (A): `result` is a contextual keyword.  A user-declared local named
// `result` shadows the contract return-value reference, so its reads take the
// *binding's* type — not the enclosing function's return type.  Here `f`
// returns `Unit` but `result` holds a `String`; reading it into a `String`
// binding must be clean.  Before the fix, `result` typed as `Unit` (the return
// type), producing a spurious T0060.  Mirrors codegen, which already loads the
// `result` slot first (codegen.l:2833).
test "result local shadows keyword" {
  val src = "package P\nfunc f(): Unit {\n  val result = \"hi\"\n  val s: String = result\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "result-local: a `val result` shadows the return-value keyword")
}

// The same shadow with a value type distinct from the return type the other
// way: `f` returns `Int`, `result` holds a `String`, and assigning `result`
// into an `Int` binding must now mismatch (T0060) — proving the read takes the
// String binding type, not the Int return type (which would spuriously pass).
test "result local keeps binding type" {
  val src = "package P\nfunc f(): Int {\n  val result = \"hi\"\n  val n: Int = result\n  n\n}\n"
  assertTrue(
    hasDiagCode(parseCheck(src), "T0060"),
    "result-local: read takes the String binding type, not Int return type"
  )
}

test "val type mismatch" {
  val src = "package P\nfunc f(): Unit {\n  val x: Int = \"oops\"\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0060"), "val-mismatch: T0060 emitted")
}

// D081 / #1943: a value-position `unsafe { … }` block has the type of its
// trailing expression, not the universal `TyError`.  Distinguishing case: an
// `unsafe { 5 }` body (`Int`) in a `String`-returning function MUST mismatch
// (T0070) — were the block still `TyError`, it would unify silently.
test "unsafe block typed" {
  val bad = "package P\nfunc f(): String { unsafe { 5 } }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0070"), "unsafe-block: Int trailing expr mismatches String return")
  val ok = "package P\nfunc g(): Int { unsafe { 5 } }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "unsafe-block-ok: Int trailing expr matches Int return")
}

// A block whose final statement is `return` has type `Never` (bottom), so a
// function whose body block diverges does not false-mismatch its return type.
test "diverging block is never" {
  val src = "package P\nfunc f(): Int { unsafe { return 3 } }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "diverging-block: unsafe { return 3 } is Never, no mismatch")
}

// #1943: an `if`/`else` expression takes the unified type of its branches.
test "if branches unify" {
  val ok = "package P\nfunc f(c: in Bool): Int { if c { 1 } else { 2 } }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "if-unify: matching branches type as Int")
  val bad = "package P\nfunc f(c: in Bool): Int { if c { 1 } else { \"x\" } }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0067"), "if-mismatch: Int vs String branches rejected")
}

// An `if` without `else` is `Unit` — binding it to a typed `val` mismatches
// (were it still `TyError`, the binding would unify silently).
test "if without else is unit" {
  val src = "package P\nfunc f(c: in Bool): Unit {\n  val x: String = if c { \"x\" }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0060"), "if-no-else: Unit value mismatches a String val binding")
}

// A diverging branch (`return`) is `Never` and is absorbed — the `if` takes the
// other branch's type, so this is a clean `Int`.
test "if diverging branch absorbed" {
  val src = "package P\nfunc f(c: in Bool): Int { if c { 1 } else { return 0 } }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "if-diverge: else-return is Never, unifies to Int")
}

// When one branch produces no value (`Unit` — here a block ending in a `val`
// statement), the `if` is used statement-like: the branches need not agree and
// the result is `Unit`, so there is no spurious mismatch even though the other
// branch is `Int`.  (A statement-position `if c { x } else { stmt }` where `x`
// is a discarded non-`Unit` value is valid and pervasive — e.g. a branch ending
// in a value-returning call whose result is dropped.)
test "if unit branch no mismatch" {
  val src = "package P\nfunc f(c: in Bool): Unit {\n  if c { 1 } else { val x = 2 }\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "if-unit-branch: Int-vs-Unit branches are not a mismatch")
}

// #2127/#2129: a bare UpperCamelCase member-call receiver that does not resolve
// is treated as a module reference (e.g. a `Std.String as Str` alias that
// survived rewriting), so it does NOT emit T0020 …
test "uppercase module receiver lenient" {
  val src = "package P\nfunc f(): Int { Foo.bar() }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0020"), "upper-receiver: unresolved `Foo.bar()` does not error T0020")
}

// … but a lowercase receiver is a value, so a typo still surfaces its T0020 —
// the leniency must not swallow real unknown-name errors.
test "lowercase receiver still errors" {
  val src = "package P\nfunc f(): Int { stirng.bar() }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0020"), "lower-receiver: typo'd `stirng.bar()` still errors T0020")
}

// #1901: numeric/character conversion methods are typed as their target
// primitive, not the universal `TyError` unifier.  The distinguishing case:
// a `.toLong()` body in an `Int`-returning function MUST mismatch (T0070) —
// were the conversion still `TyError`, it would unify with `Int` and slip
// through silently.
test "conv method typed as target" {
  val src = "package P\nfunc f(x: in Int): Int { x.toLong() }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0070"), "conv-target: Int body of Long conversion is a mismatch")
}

test "conv method widening accepted" {
  val src = "package P\nfunc f(x: in Int): Long { x.toLong() }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "conv-widen: Int.toLong() in a Long context type-checks")
}

test "conv method narrowing accepted" {
  val src = "package P\nfunc g(x: in Long): Int { x.toInt() }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "conv-narrow: Long.toInt() in an Int context type-checks")
}

test "conv method on non numeric rejected" {
  val src = "package P\nfunc f(s: in String): Int { s.toInt() }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0103"), "conv-nonnumeric: String.toInt() rejected with T0103")
}

// #1901 part B: an index expression `recv[i]` carries the receiver's element
// type, not the universal `TyError`.  Distinguishing case: a `slice[Byte]`
// element returned where `Int` is expected MUST mismatch (T0070) — `Byte != Int`
// (no implicit widening) — whereas `TyError` would have unified silently.
test "index byte element typed" {
  val src = "package P\nfunc f(a: in slice[Byte]): Int { a[0] }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0070"), "index-byte: slice[Byte] element is Byte, mismatches Int return")
}

test "index byte with conversion accepted" {
  val src = "package P\nfunc f(a: in slice[Byte]): Int { a[0].toInt() }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "index-byte-conv: a[0].toInt() type-checks to Int")
}

// String indexing yields `Char`; a `Char` in a `Char`-returning function is
// clean, but in an `Int`-returning function it mismatches.
test "index string element is char" {
  val ok = "package P\nfunc f(s: in String): Char { s[0] }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "index-string-char: s[0] is Char")
  val bad = "package P\nfunc g(s: in String): Int { s[0] }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0070"), "index-string-int: Char element mismatches Int return")
}

test "return without value error" {
  val src = "package P\nfunc f(): Int { return }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0064"), "ret-novalue: T0064 emitted")
}

test "range subtype valid" {
  val src = "package P\ntype Age = Int range 0 ..= 150\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "range-valid: no diagnostics")
  assertTrue(symCount(cr) > 0, "range-valid: symbol registered")
}

test "range subtype empty bounds" {
  val src = "package P\ntype Bad = Int range 10 ..= 5\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0090"), "range-empty: T0090 emitted")
}

test "where clause unknown param" {
  val src = "package P\nfunc f[T](x: in T): T where Z: Add { x }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0050"), "where-unknown: T0050 emitted")
}

test "arithmetic type mismatch" {
  // Adding Int and Bool — should produce T0031.
  val src = "package P\nfunc f(x: in Int, b: in Bool): Int { x + b }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0031"), "arith-mismatch: T0031 emitted")
}

test "unknown name" {
  val src = "package P\nfunc f(): Int { noSuchName }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0020"), "unknown-name: T0020 emitted")
}

// A `pub alias X = Y` type-alias re-export used in type position must
// resolve to its target (the stdlib's `pub alias Random =
// Std.RandomHost.Random` re-export pattern).  Before the resolver
// followed aliases, the alias symbol carried no TypeId and produced a
// spurious T0013 "'X' is not a type".
test "type alias resolves" {
  val src = "package P\nrecord Foo { x: Int }\nalias Bar = Foo\nfunc f(b: in Bar): Int { b.x }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0013"), "alias-resolve: no T0013 for aliased type")
  assertTrue(not hasDiagCode(cr, "T0010"), "alias-resolve: no T0010 for aliased type")
  assertEqualInt(diagCount(cr), 0, "alias-resolve: clean type-check")
}

// A multi-hop alias chain (`alias B = Foo`, `alias C = B`) must resolve
// through every hop to the concrete target.
test "type alias chain resolves" {
  val src = "package P\nrecord Foo { x: Int }\nalias B = Foo\nalias C = B\nfunc f(c: in C): Int { c.x }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "alias-chain: clean type-check")
}

// An alias to a generic type instantiation (the `TGenericApp` branch of
// resolveAliasRhs) must resolve to the underlying generic type.
test "type alias to generic resolves" {
  val src = "package P\nrecord Box[T] { value: T }\nalias IntBox = Box[Int]\nfunc f(b: in IntBox): Int { 0 }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0013"), "alias-generic: no T0013")
  assertTrue(not hasDiagCode(cr, "T0017"), "alias-generic: no spurious cycle")
}

// A mutual alias cycle (`alias A = B`, `alias B = A`) must be rejected with
// a clean T0017 diagnostic, not recurse to a stack overflow (#2607).
test "cyclic type alias rejected" {
  val src = "package P\nalias A = B\nalias B = A\nfunc f(a: in A): Int { 0 }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0017"), "alias-cycle: T0017 emitted")
}

// #6418: a diagnostic on an aliased annotation must name the alias the user
// wrote, not just its resolved underlying type. Covers the two "free"
// (no signature-registry plumbing needed) wiring points: a function's
// declared return type (T0070, `checkFunctionBody`'s `fn.ret` + `sig.returnTy`
// co-located) and a local `val` binding's declared type (T0060, `LBVal`'s
// `te` + `declT` co-located). See `docs/03-decision-log.md` D-progress-765
// for the diagnostics covered vs. deferred (call-argument mismatches against
// a registered function signature stay unthreaded — `ResolvedParam` persists
// only `Type`, not the originating `TypeExpr`).
test "T0070 return-type mismatch names the alias the user wrote (#6418)" {
  val src = "package P\nalias Meters = Long\nfunc f(): Meters {\n  \"oops\"\n}\n"
  val cr = parseCheckAliasResolved(src)
  val m = diagMessageFor(cr, "T0070")
  assertTrue(Str.contains(m, "Meters (aka Long)"), "T0070 message names the alias: " + m)
}

test "T0060 val-binding mismatch names the alias the user wrote (#6418)" {
  val src = "package P\nalias UserId = Int\nfunc f(): Unit {\n  val u: UserId = \"nope\"\n}\n"
  val cr = parseCheckAliasResolved(src)
  val m = diagMessageFor(cr, "T0060")
  assertTrue(Str.contains(m, "UserId (aka Int)"), "T0060 message names the alias: " + m)
}

// Without the alias-resolve pre-pass, the checker's own independent
// `DKTypeAlias` lookup still resolves `Meters` correctly for pass/fail, but
// `TypeExpr.aliasName` is never stamped — pin that `renderTypeExpr` degrades
// safely to the bare underlying name (no "aka") instead of rendering
// inconsistently across code paths that do vs. don't run the pre-pass.
test "T0070 without the alias-resolve pre-pass falls back to the underlying type name (#6418)" {
  val src = "package P\nalias Meters = Long\nfunc f(): Meters {\n  \"oops\"\n}\n"
  val cr = parseCheck(src)
  val m = diagMessageFor(cr, "T0070")
  assertTrue(
    Str.contains(m, "Long") and not Str.contains(m, "aka"),
    "no pre-pass: bare underlying name, no \"aka\": " + m
  )
}

test "multiple items no error" {
  val src = "package P\nrecord A { x: Int }\nrecord B { y: String }\nfunc f(a: in A): String { a.x }\n"
  val pr = parse(src)
  val cr = check(pr.file)
  // f returns String but a.x is Int — T0070 expected; records A and B are fine
  assertTrue(symCount(cr) >= 3, "multi: A, B, f all registered")
}

test "yield outside async" {
  // T0094: yield inside a non-async function body.
  val src = "package P\nfunc f(): Int {\n  yield 1\n  return 0\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0094"), "T0094: yield outside async emits diagnostic")
}

test "async generator flags" {
  // An async func with yield: isAsync=true, isGenerator=true, no T0094.
  val src = "package P\nasync func g(): Int {\n  yield 1\n  yield 2\n}\n"
  val cr = parseCheck(src)
  val noT0094 = not hasDiagCode(cr, "T0094")
  assertTrue(noT0094, "async-gen: no T0094 for valid async generator")
  match mapGet(cr.sigs, "g") {
    case None -> assertTrue(false, "async-gen: sig 'g' not found")
    case Some(sig) -> {
      assertTrue(sig.isAsync, "async-gen: isAsync=true")
      assertTrue(sig.isGenerator, "async-gen: isGenerator=true")
    }
  }
}

test "hot annotation flag" {
  // @hot on a regular async func: isHot=true, isGenerator=false.
  val src = "package P\n@hot\nasync func h(): Int { return 42 }\n"
  val cr = parseCheck(src)
  match mapGet(cr.sigs, "h") {
    case None -> assertTrue(false, "hot: sig 'h' not found")
    case Some(sig) -> {
      assertTrue(sig.isHot, "hot: isHot=true")
      assertTrue(not sig.isGenerator, "hot: isGenerator=false")
    }
  }
}

test "qualified type resolves via import" {
  // `Lib.Point` in a type position should resolve to the same `Point`
  // type registered by checkWithImports — no T0014 "qualified type not
  // resolved".
  val libSrc = "package Lib\npub record Point { x: Int; y: Int }\n"
  val libPr = parse(libSrc)
  val importedItems: List[Item] = newList()
  var i = 0
  while i < libPr.file.items.count {
    importedItems.add(libPr.file.items[i])
    i = i + 1
  }
  val src = "package App\nfunc f(p: Lib.Point): Int { 0 }\n"
  val pr = parse(src)
  val cr = checkWithImports(pr.file, importedItems)
  // Stronger than just `not hasDiagCode T0014` (#924): assert there
  // are no type-resolution diagnostics at all.  The previous form
  // would have passed even if a different type-resolution error
  // (T0010 / T0020 / T0050) had surfaced, masking a regression.
  assertTrue(not hasDiagCode(cr, "T0014"), "qualified-type-import: no T0014 for Lib.Point when Point is imported")
  assertTrue(not hasDiagCode(cr, "T0010"), "qualified-type-import: no T0010 unknown-type for Lib.Point")
  assertTrue(not hasDiagCode(cr, "T0020"), "qualified-type-import: no T0020 unknown-name for Lib.Point")
  assertTrue(not hasDiagCode(cr, "T0050"), "qualified-type-import: no T0050 generic-arity for Lib.Point")
}

// #1488: interface subtyping at argument positions — a value whose type `T`
// has `impl I for T` is accepted where parameter type is the interface `I`.
// `Hello` impls `Greeter`, so `useGreeter(Hello(...))` is clean.
test "interface subtyping accepted" {
  val src = "package P\npub interface Greeter {\n  func greet(): String\n}\nrecord Hello { name: String }\nimpl Greeter for Hello {\n  func greet(): String { \"hi\" }\n}\nfunc useGreeter(g: in Greeter): String { g.greet() }\nfunc f(): Unit {\n  val s = useGreeter(Hello(name = \"x\"))\n}\n"
  assertEqualInt(
    diagCount(parseCheck(src)),
    0,
    "interface-subtyping: Hello (impl Greeter) is accepted where Greeter is expected"
  )
}

// The subtyping is precise: a record that does NOT implement the interface is
// still rejected (T0043), so the relation isn't a blanket "any user type".
test "interface subtyping rejects non impl" {
  val src = "package P\npub interface Greeter {\n  func greet(): String\n}\nrecord Other { x: Int }\nfunc useGreeter(g: in Greeter): String { \"\" }\nfunc f(): Unit {\n  val s = useGreeter(Other(x = 1))\n}\n"
  assertTrue(
    hasDiagCode(parseCheck(src), "T0043"),
    "interface-subtyping: Other (no impl) is rejected where Greeter is expected"
  )
}

// #2303 soundness: conformance is keyed by `TypeId`, not simple name.  `PkgA`
// and `PkgB` both declare a `Greeter` interface (distinct ids).  `Hello` impls
// `PkgA.Greeter` (the user imports `PkgA`), so passing it to `PkgB.wantB`, whose
// parameter is `PkgB.Greeter`, MUST still be rejected — a simple-name key would
// have wrongly accepted it.
test "interface subtyping cross package sound" {
  val pkgA = parse("package PkgA\npub interface Greeter {\n  func greet(): String\n}\n")
  val pkgB = parse(
    "package PkgB\npub interface Greeter {\n  func greet(): String\n}\npub func wantB(g: in Greeter): String { \"\" }\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(ImportedPackage(name = "PkgA", items = pkgA.file.items, imports = collectImportNames(pkgA.file.imports)))
  packages.add(ImportedPackage(name = "PkgB", items = pkgB.file.items, imports = collectImportNames(pkgB.file.imports)))
  val src = "package App\nimport PkgA\nrecord Hello { x: Int }\nimpl Greeter for Hello {\n  func greet(): String { \"hi\" }\n}\nfunc f(): Unit {\n  val s = wantB(Hello(x = 1))\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, packages)
  assertTrue(
    hasDiagCode(cr, "T0043"),
    "interface-subtyping cross-package: impl of PkgA.Greeter does not satisfy a PkgB.Greeter parameter"
  )
}

// #6287: a PACKAGE-QUALIFIED union-case constructor honours its qualifier.
// PkgA and PkgB both export `union Signal` with a colliding case name `Ping`
// (different field shapes).  Before the fix, `PkgA.Ping(...)` resolved the
// bare last segment last-registered-wins — PkgB's case won despite the
// explicit qualifier, surfacing as a baffling `T0043 Signal vs Signal`.
test "qualified union case constructor honours package qualifier" {
  val pkgA = parse(
    "package PkgA\npub union Signal {\n  case Ping(code: Int)\n  case Halt\n}\npub func wantA(s: in Signal): Int { 0 }\n"
  )
  val pkgB = parse("package PkgB\npub union Signal {\n  case Ping(label: String)\n  case Halt\n}\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(ImportedPackage(name = "PkgA", items = pkgA.file.items, imports = collectImportNames(pkgA.file.imports)))
  packages.add(ImportedPackage(name = "PkgB", items = pkgB.file.items, imports = collectImportNames(pkgB.file.imports)))
  // Qualified to PkgA — must construct PkgA's Signal and satisfy wantA.
  val okSrc = "package App\nimport PkgA\nimport PkgB\nfunc f(): Int {\n  wantA(PkgA.Ping(code = 7))\n}\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(okSrc).file, packages)),
    0,
    "qualified ctor: PkgA.Ping resolves to PkgA's case despite PkgB's collision (registered later)"
  )
  // Qualified to PkgB — the constructed value's cases carry PkgB's field
  // types: binding Ping's String `label` into an Int-typed val must be
  // rejected.  (Not routed through `wantA`'s signature — the flat test
  // shim resolves sig param types leniently, so a cross-union arg check is
  // not enforceable here; the field type IS.)
  val errSrc = "package App\nimport PkgA\nimport PkgB\nfunc f(): Int {\n  match PkgB.Ping(label = \"x\") {\n    case Ping(c) -> {\n      val x: Int = c\n      x\n    }\n    case Halt -> 0\n  }\n}\n"
  assertTrue(
    hasDiagCode(checkWithImportedPackages(parse(errSrc).file, packages), "T0060"),
    "qualified ctor: PkgB.Ping constructs PkgB's Signal — its Ping binds a String, rejected by an Int val"
  )
  // And the same shape through PkgA stays clean (`code` is Int).
  val okSrc3 = "package App\nimport PkgA\nimport PkgB\nfunc f(): Int {\n  match PkgA.Ping(code = 1) {\n    case Ping(c) -> {\n      val x: Int = c\n      x\n    }\n    case Halt -> 0\n  }\n}\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(okSrc3).file, packages)),
    0,
    "qualified ctor: PkgA.Ping's Int field binds cleanly into an Int val"
  )
  // Union-name-qualified with a leading package — `PkgA.Signal.Ping(...)`.
  val okSrc2 = "package App\nimport PkgA\nimport PkgB\nfunc f(): Int {\n  wantA(PkgA.Signal.Ping(code = 7))\n}\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(okSrc2).file, packages)),
    0,
    "qualified ctor: PkgA.Signal.Ping resolves through the package-qualified parent union"
  )
}

// #6287 Phase B: a PACKAGE-QUALIFIED union-case PATTERN HEAD must have its
// qualifier validated against the SCRUTINEE's own union, not silently
// ignored.  PkgA and PkgB both export `union Signal` with a colliding case
// name `Ping` (different field shapes).  Before the fix,
// `unionCaseSymbolForScrutinee` extracted only the bare last segment
// ("Ping") and searched for whichever candidate's parent matched the
// scrutinee's own union — silently discarding an explicit (and here,
// WRONG) qualifier and binding the scrutinee's own field type, which then
// surfaced only as a baffling downstream type error at the bind site, not
// at the actual mis-qualified pattern.
test "qualified union case pattern head validates against the scrutinee's own union" {
  val pkgA = parse(
    "package PkgA\npub union Signal {\n  case Ping(code: Int)\n  case Halt\n}\npub func wantA(s: in Signal): Int { 0 }\n"
  )
  val pkgB = parse("package PkgB\npub union Signal {\n  case Ping(label: String)\n  case Halt\n}\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(ImportedPackage(name = "PkgA", items = pkgA.file.items, imports = collectImportNames(pkgA.file.imports)))
  packages.add(ImportedPackage(name = "PkgB", items = pkgB.file.items, imports = collectImportNames(pkgB.file.imports)))
  // A PkgA-typed scrutinee matched with an explicitly PkgB-qualified
  // pattern head must be rejected — PkgB never declares the union being
  // matched.
  val mismatchSrc = "package App\nimport PkgA\nimport PkgB\nfunc f(s: in PkgA.Signal): Int {\n  match s {\n    case PkgB.Ping(c) -> c\n    case Halt -> 0\n  }\n}\n"
  // #6540: EMatch runs both bindPatternTyped and checkConstRefPattern over
  // the same arm pattern; only bindPatternTyped's call should own the
  // T0122 emission, so it must fire EXACTLY ONCE per mismatched pattern
  // (a bare hasDiagCode existence check would miss a duplicate-emission
  // regression like #6540).
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(mismatchSrc).file, packages), "T0122"),
    1,
    "pattern qualifier mismatch: PkgB.Ping against a PkgA-typed scrutinee is rejected exactly once, not silently bound (#6540)"
  )
  // Correctly PkgA-qualified pattern head still resolves and binds the
  // real (Int) field type.
  val correctSrc = "package App\nimport PkgA\nimport PkgB\nfunc f(s: in PkgA.Signal): Int {\n  match s {\n    case PkgA.Ping(c) -> c\n    case Halt -> 0\n  }\n}\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(correctSrc).file, packages)),
    0,
    "pattern qualifier match: PkgA.Ping against a PkgA-typed scrutinee resolves cleanly"
  )
  // A bare (unqualified) pattern head still resolves against the
  // scrutinee's own union, unaffected by the qualifier-validation guard
  // (the #6510/D-progress-785 behaviour this test does not change).
  val bareSrc = "package App\nimport PkgA\nimport PkgB\nfunc f(s: in PkgA.Signal): Int {\n  match s {\n    case Ping(c) -> c\n    case Halt -> 0\n  }\n}\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(bareSrc).file, packages)),
    0,
    "pattern qualifier match: a bare Ping(c) still resolves against the scrutinee's own (PkgA) union"
  )
}

// #6519: a PACKAGE-QUALIFIED record constructor call validates its field
// argument types.  Before the fix, `constructorSymbolOf` only matched a
// single-segment `EPath` callee (`Type(...)`) — a qualified callee
// (`Pkg.Type(...)`, or the nested-`EMember` `Pkg.Sub.Type(...)` form)
// returned `None` unconditionally, so `inferConstruction` never found the
// record symbol and skipped its per-field T0104 check entirely, silently
// accepting a wrong-typed field argument for ANY qualified construction.
test "qualified record constructor validates field argument types" {
  val pkgR = parse("package PkgR\npub record Widget {\n  pub name: String\n  pub count: Int\n}\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(ImportedPackage(name = "PkgR", items = pkgR.file.items, imports = collectImportNames(pkgR.file.imports)))
  // Wrong-typed `name` field (Int where String is declared) through a
  // qualified constructor call must be rejected with T0104 — pre-fix this
  // fell through to the lenient generic call-type path and type-checked clean.
  val badSrc = "package App\nimport PkgR\nfunc f(): Unit {\n  val w = PkgR.Widget(name = 7, count = 1)\n}\n"
  assertTrue(
    hasDiagCode(checkWithImportedPackages(parse(badSrc).file, packages), "T0104"),
    "qualified ctor: PkgR.Widget(name = 7, ...) rejects an Int argument for the String field 'name'"
  )
  // Correctly-typed qualified construction stays clean.
  val okSrc = "package App\nimport PkgR\nfunc f(): Unit {\n  val w = PkgR.Widget(name = \"ok\", count = 1)\n}\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(okSrc).file, packages)),
    0,
    "qualified ctor: PkgR.Widget(name = \"ok\", ...) with correctly-typed fields is clean"
  )
}

// #1488 category D: two imported packages can export the same simple type name
// (`Std.Regex.RegexError` {TimedOut, InvalidPattern} vs `Std.RegexSafe.RegexError`
// {TimedOut, RegexBug}).  Through the flat `checkWithImports` shim, every
// imported symbol carries an empty origin package, so package-scoped resolution
// never engages and lookup is last-registered-wins (`symTableTryFindOne` scans
// the table backwards): the package whose items are spread last wins every
// reference to the shared name.  This test pins that flat-shim invariant — the
// scope-aware fix for the collision (D-progress-428) lives behind
// `checkWithImportedPackages` and is covered by
// `testScopedResolutionNoCrossPackageTypeCollision`.  Here, when `LibB`'s `E` is
// registered after `LibA`'s, a `match` over `E` is exhaustive against `LibB`'s
// cases (and `LibA`'s cases are unknown).
test "colliding type name last registered wins" {
  val libA = parse("package LibA\npub union E { case A1(x: Int) }\n")
  val libB = parse("package LibB\npub union E { case B1(x: Int)\n  case B2(y: Int) }\n")
  val importedItems: List[Item] = newList()
  var a = 0
  while a < libA.file.items.count {
    importedItems.add(libA.file.items[a])
    a = a + 1
  }
  var b = 0
  while b < libB.file.items.count {
    importedItems.add(libB.file.items[b])
    b = b + 1
  }
  // `E` resolves to LibB's (registered last); a match over its cases is clean.
  val okSrc = "package App\nfunc f(e: in E): Unit {\n  match e {\n    case B1(_) -> ()\n    case B2(_) -> ()\n  }\n}\n"
  assertEqualInt(
    diagCount(checkWithImports(parse(okSrc).file, importedItems)),
    0,
    "collision: E resolves to the last-registered (LibB) union; B1/B2 match is exhaustive"
  )
  // Matching LibA's `A1` is non-exhaustive against LibB's `E` (missing B1/B2).
  val badSrc = "package App\nfunc g(e: in E): Unit {\n  match e {\n    case A1(_) -> ()\n  }\n}\n"
  assertTrue(
    hasDiagCode(checkWithImports(parse(badSrc).file, importedItems), "T0016"),
    "collision: matching LibA's A1 is non-exhaustive against the last-registered E"
  )
}

// #1488 category C: two imported functions sharing a name and arity but
// differing in parameter type (the `Std.Char.toUpper(Char)` vs
// `Std.String.toUpper(String)` collision) must dispatch by argument type, not
// by first-in-wins.  `mk(String)` returns `Int`; `mk(Int)` returns `String`.
// A `String`-typed argument must select the `Int`-returning overload, so
// binding the call into an `Int` is clean and into a `String` mismatches.
test "overload dispatch by arg type" {
  val libSrc = "package Lib\npub func mk(s: in String): Int { 0 }\npub func mk(n: in Int): String { \"\" }\n"
  val libPr = parse(libSrc)
  val importedItems: List[Item] = newList()
  var i = 0
  while i < libPr.file.items.count {
    importedItems.add(libPr.file.items[i])
    i = i + 1
  }
  // `mk("x")` selects `mk(String): Int`; the `Int` binding is clean.
  val okSrc = "package App\nfunc f(): Unit {\n  val n: Int = mk(\"x\")\n}\n"
  val okPr = parse(okSrc)
  assertEqualInt(
    diagCount(checkWithImports(okPr.file, importedItems)),
    0,
    "overload: mk(String) selects the Int-returning overload"
  )
  // `mk(7)` selects `mk(Int): String`; binding into `Int` must mismatch (T0060),
  // proving the *other* overload was chosen — a first-in-wins map would have
  // returned the same overload for both calls.
  val badSrc = "package App\nfunc f(): Unit {\n  val n: Int = mk(7)\n}\n"
  val badPr = parse(badSrc)
  assertTrue(
    hasDiagCode(checkWithImports(badPr.file, importedItems), "T0060"),
    "overload: mk(Int) selects the String-returning overload (mismatches Int)"
  )
}

test "qualified type unknown emits t0014" {
  // A qualified name whose last segment is not in scope should still
  // emit T0014, not resolve silently.
  val src = "package App\nfunc f(x: Unknown.Pkg.Blorp): Int { 0 }\n"
  val empty: List[Item] = newList()
  val pr = parse(src)
  val cr = checkWithImports(pr.file, empty)
  assertTrue(hasDiagCode(cr, "T0014"), "qualified-unknown: T0014 for Unknown.Pkg.Blorp not in scope")
}

test "qualified type misqualified resolves permissively" {
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
  val libPr = parse(libSrc)
  val importedItems: List[Item] = newList()
  var i = 0
  while i < libPr.file.items.count {
    importedItems.add(libPr.file.items[i])
    i = i + 1
  }
  val src = "package App\nfunc f(p: Wrong.Prefix.Point): Int { 0 }\n"
  val pr = parse(src)
  val cr = checkWithImports(pr.file, importedItems)
  assertTrue(
    not hasDiagCode(cr, "T0014"),
    "qualified-misqualified: last-segment lookup currently accepts Wrong.Prefix.Point when Point is imported (Band 6 interim — #923)"
  )
}

func testOpaqueConstructSamePackageWithDuplicateImportedSymbol(): Unit {
  // Regression test for same-package item shadowing in the typechecker.
  // When a package is compiled with imported stdlib items, the current file's
  // declarations appear after the imported items in the symbol table and
  // must therefore take precedence.
  val src = "package P\n" + "opaque type Secret { token: String }\n" +
    "func f(): Unit { val s = Secret(token = \"x\") }\n"
  val pr: ParseResult = parse(src)
  val importedItems: List[Item] = newList()
  var i = 0
  while i < pr.file.items.count {
    importedItems.add(pr.file.items[i])
    i = i + 1
  }
  val cr = checkWithImports(pr.file, importedItems)
  assertTrue(not hasDiagCode(cr, "T0100"), "same-package opaque construction with duplicate imported symbol: no T0100")
}

// #425 item 6: T0031 ("arithmetic operands must have the same type")
// used to render user-defined types as `<#7>` because the renderer
// could not look up declared names.  After the fix, `TyUser` carries
// its declared name from the resolver and `renderType` surfaces it.
// We exercise this with a record type used in a typed-arithmetic
// mismatch (a Bool + Point pair).  T0031's payload must include the
// declared name "Point" rather than the synthetic `<#N>` placeholder.
test "ty user renders declared name" {
  val src = "package P\n" + "record Point { x: Int; y: Int }\n" + "func f(p: in Point, b: in Bool): Int { p + b }\n"
  val cr = parseCheck(src)
  // Pull every diagnostic message and assert at least one mentions
  // "Point" rather than the synthetic `<#…>`.
  var sawName = false
  var sawPlaceholder = false
  var i = 0
  while i < cr.diagnostics.count {
    val m = cr.diagnostics[i].message
    if Str.contains(m, "Point") {
      sawName = true
    }
    if Str.contains(m, "<#") {
      sawPlaceholder = true
    }
    i = i + 1
  }
  assertTrue(sawName, "TyUser render: 'Point' surfaces in a diagnostic")
  assertTrue(not sawPlaceholder, "TyUser render: no `<#…>` placeholder leaked to diagnostics")
}

// #425 item 5: a range bound of `-9223372036854775808` (Long.MinValue)
// must fold cleanly without T0093 (overflow during fold).  Before the
// fix the lexer rejected the inner literal as out-of-range and the
// fold returned FEOverflow; the lexer now stores 9223372036854775808
// as Long.MinValue's bit pattern and the fold recognises the
// PreNeg + literal pair as a single Long.MinValue unit.
test "range bound long min value folds" {
  val src = "package P\n" + "type Limit = Long range -9223372036854775808 ..= 0\n"
  val cr = parseCheck(src)
  // T0093 = "symbolic bound that cannot be folded" — must not fire.
  assertTrue(not hasDiagCode(cr, "T0093"), "Long.MinValue range bound folds without T0093")
  assertEqualInt(diagCount(cr), 0, "Long.MinValue range bound: no diagnostics at all")
}

test "first wins on import func collision" {
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
  val libSrc = "package Lib\n" + "pub func collide(x: in Int): Int { x }\n"
  val libPr = parse(libSrc)
  val importedItems: List[Item] = newList()
  var i = 0
  while i < libPr.file.items.count {
    importedItems.add(libPr.file.items[i])
    i = i + 1
  }
  // (a) same name + same arity: must not crash; check completes.
  val srcSame = "package App\n" + "func collide(x: in Int): Int { x + 1 }\n" + "func consume(): Int { collide(7) }\n"
  val prSame = parse(srcSame)
  val crSame = checkWithImports(prSame.file, importedItems)
  assertTrue(
    diagCount(crSame) == 0,
    "first-wins: same-name same-arity user redeclaration does not crash and emits no diagnostics"
  )

  // (b) same name + different arity: user overload registers on its
  // own arity-qualified key; both calls resolve.
  val srcDiff = "package App2\n" + "func collide(x: in Int, y: in Int): Int { x + y }\n" +
    "func consume(): Int { collide(7, 8) }\n"
  val prDiff = parse(srcDiff)
  val crDiff = checkWithImports(prDiff.file, importedItems)
  assertTrue(diagCount(crDiff) == 0, "first-wins: same-name different-arity user overload registers cleanly")
}

// #1482 (Band-1 foundation): the `Type` union now carries refinement
// (range) bounds via `TyRefined`, populated by the resolver for inline
// refined types (`Int range lo .. hi`).  A binding initialised with an
// integer literal outside those bounds is rejected with T0015.
test "inline refined in bounds" {
  val src = "package P\nfunc f(): Unit {\n  val x: Int range 0 ..= 9 = 5\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0015"), "inline-range in-bounds: no T0015")
  assertEqualInt(diagCount(cr), 0, "inline-range in-bounds: clean")
}

test "inline refined above inclusive" {
  val src = "package P\nfunc f(): Unit {\n  val x: Int range 0 ..= 9 = 10\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0015"), "inline-range above inclusive hi: T0015")
}

test "inline refined at inclusive hi" {
  // `..=` includes the upper endpoint, so 9 is in range.
  val src = "package P\nfunc f(): Unit {\n  val x: Int range 0 ..= 9 = 9\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0015"), "inline-range at inclusive hi: no T0015")
}

test "inline refined half open excludes hi" {
  // `..` is half-open: 10 is excluded from `0 .. 10`.
  val src = "package P\nfunc f(): Unit {\n  val x: Int range 0 .. 10 = 10\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0015"), "inline-range half-open excludes hi: T0015")
}

test "inline refined half open in bounds" {
  val src = "package P\nfunc f(): Unit {\n  val x: Int range 0 .. 10 = 9\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0015"), "inline-range half-open in-bounds: no T0015")
}

test "inline refined below lo" {
  val src = "package P\nfunc f(): Unit {\n  val x: Int range 5 ..= 9 = 1\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0015"), "inline-range below lo: T0015")
}

test "inline refined negative bounds" {
  val ok = "package P\nfunc f(): Unit {\n  val x: Int range -5 ..= 5 = -3\n}\n"
  val bad = "package P\nfunc f(): Unit {\n  val x: Int range -5 ..= 5 = -9\n}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0015"), "neg-bound in-range: no T0015")
  assertTrue(hasDiagCode(parseCheck(bad), "T0015"), "neg-bound out-of-range: T0015")
}

test "inline refined var and let" {
  val v = "package P\nfunc f(): Unit {\n  var x: Int range 0 ..= 9 = 10\n}\n"
  val l = "package P\nfunc f(): Unit {\n  let x: Int range 0 ..= 9 = 10\n}\n"
  assertTrue(hasDiagCode(parseCheck(v), "T0015"), "var inline-range out-of-range: T0015")
  assertTrue(hasDiagCode(parseCheck(l), "T0015"), "let inline-range out-of-range: T0015")
}

test "inline refined upper open below lo" {
  // Upper-open `range 5 ..`: 3 is below the lower bound — T0015.
  val src = "package P\nfunc f(): Unit {\n  val x: Int range 5 .. = 3\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0015"), "upper-open below lo: T0015")
}

test "inline refined upper open at lo" {
  // Upper-open `range 5 ..`: 5 is at the lower bound, no upper to check.
  val src = "package P\nfunc f(): Unit {\n  val x: Int range 5 .. = 5\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0015"), "upper-open at lo: no T0015")
}

test "inline refined lower open above hi" {
  // Lower-open `range ..= 9`: 12 is above the inclusive upper bound — T0015.
  val src = "package P\nfunc f(): Unit {\n  val x: Int range ..= 9 = 12\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0015"), "lower-open above hi: T0015")
}

test "refinement transparent to equiv" {
  // Gate-safety: a refined type is equivalent to its underlying.  An
  // in-bounds refined binding whose declared type differs only by the
  // refinement layer must produce zero type-equivalence diagnostics
  // (no T0060/T0015) — refinements add no equivalence false positives.
  val src = "package P\n" + "func f(): Unit {\n" + "  val a: Int range 0 ..= 100 = 42\n" + "  val b: Int = a\n" +
    "  val c: Int range 0 ..= 100 = b\n" +
    "}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "refinement transparency: zero diagnostics")
}

test "inline refined non literal not checked" {
  // The inline check only fires for statically-known integer literals;
  // a non-literal initialiser (here a parameter) is not range-checked
  // at compile time (that is runtime / Band-4 construction validation).
  val src = "package P\n" + "func f(n: in Int): Unit {\n" + "  val x: Int range 0 ..= 9 = n\n" + "}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0015"), "non-literal init: no compile-time T0015")
}

// #1483 (Band-1): match exhaustiveness (T0016).  EMatch now infers the
// scrutinee and verifies every possible value is matched, for union / enum /
// Bool / unbounded-scalar scrutinees.  A bare `case Foo` counts as covering
// case `Foo` only when `Foo` names a case of the scrutinee type (matching
// codegen); otherwise it is an irrefutable variable bind (catch-all).
test "match union exhaustive" {
  val src = "package P\n" + "union Shape { case Circle(r: Int); case Square(s: Int); case Tri }\n" +
    "func area(sh: in Shape): Int {\n" +
    "  match sh { case Circle(r) -> r; case Square(s) -> s; case Tri -> 0 }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0016"), "union all-cases: no T0016")
}

test "match union non exhaustive" {
  val src = "package P\n" + "union Shape { case Circle(r: Int); case Square(s: Int); case Tri }\n" +
    "func area(sh: in Shape): Int {\n" +
    "  match sh { case Circle(r) -> r; case Square(s) -> s }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0016"), "union missing case: T0016")
}

test "match union wildcard" {
  val src = "package P\n" + "union Shape { case Circle(r: Int); case Square(s: Int); case Tri }\n" +
    "func area(sh: in Shape): Int {\n" +
    "  match sh { case Circle(r) -> r; case _ -> 0 }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0016"), "union wildcard: no T0016")
}

test "match union bare name bind" {
  // A bare name that is NOT a case of the scrutinee is a variable bind
  // (catch-all), so the match is exhaustive.
  val src = "package P\n" + "union Shape { case Circle(r: Int); case Square(s: Int); case Tri }\n" +
    "func area(sh: in Shape): Int {\n" +
    "  match sh { case Circle(r) -> r; case other -> 0 }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0016"), "union bare-name bind catch-all: no T0016")
}

test "match union nullary bare case" {
  // A bare `case Tri` (nullary) covers case Tri — proving bare-name cases are
  // resolved against the scrutinee's case set, not treated as a catch-all.
  val src = "package P\n" + "union Shape { case Circle(r: Int); case Tri }\n" + "func area(sh: in Shape): Int {\n" +
    "  match sh { case Tri -> 0 }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0016"), "union bare nullary case covers only Tri -> missing Circle: T0016")
}

test "match union guard does not cover" {
  // A guarded arm never counts toward coverage (the guard may fail).
  val src = "package P\n" + "union Shape { case Circle(r: Int); case Tri }\n" + "func area(sh: in Shape): Int {\n" +
    "  match sh { case Circle(r) if r > 0 -> r; case Tri -> 0 }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0016"), "guarded Circle arm does not cover -> T0016")
}

test "match generic union exhaustive" {
  // Generic-union scrutinees (`Option[Int]`) should resolve to the union
  // declaration via `typeIdEq` regardless of type arguments.
  val ok = "package P\nunion Option[T] { case Some(value: T); case None }\n" + "func f(o: in Option[Int]): Int {\n" +
    "  match o { case Some(x) -> x; case None -> 0 }\n" +
    "}\n"
  val bad = "package P\nunion Option[T] { case Some(value: T); case None }\n" + "func f(o: in Option[Int]): Int {\n" +
    "  match o { case Some(x) -> x }\n" +
    "}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0016"), "Option[Int] all cases: no T0016")
  assertTrue(hasDiagCode(parseCheck(bad), "T0016"), "Option[Int] missing None: T0016")
}

test "match or pattern exhaustive" {
  // POr arms enumerate multiple union cases at once.
  val ok = "package P\n" + "union Shape { case Circle; case Square; case Tri }\n" + "func area(sh: in Shape): Int {\n" +
    "  match sh { case Circle | Square -> 0; case Tri -> 1 }\n" +
    "}\n"
  val bad = "package P\n" + "union Shape { case Circle; case Square; case Tri }\n" + "func area(sh: in Shape): Int {\n" +
    "  match sh { case Circle | Square -> 0 }\n" +
    "}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0016"), "Or-pattern + Tri: no T0016")
  assertTrue(hasDiagCode(parseCheck(bad), "T0016"), "Or-pattern missing Tri: T0016")
}

test "match at bind exhaustive" {
  // `case x@Circle(r)` should credit `Circle` to the coverage set via the
  // `Some(inner)` branch of `collectCoveredCases`.
  val src = "package P\n" + "union Shape { case Circle(r: Int); case Square(s: Int); case Tri }\n" +
    "func area(sh: in Shape): Int {\n" +
    "  match sh { case x@Circle(r) -> r; case Square(s) -> s; case Tri -> 0 }\n" +
    "}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0016"), "@-bound Circle covers union case: no T0016")
  val bad = "package P\n" + "union Shape { case Circle(r: Int); case Square(s: Int); case Tri }\n" +
    "func area(sh: in Shape): Int {\n" +
    "  match sh { case x@Circle(r) -> r }\n" +
    "}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0016"), "@-bound Circle alone leaves Square/Tri uncovered: T0016")
}

test "match enum exhaustive" {
  val src = "package P\n" + "enum Color { case Red; case Green; case Blue }\n" + "func rank(c: in Color): Int {\n" +
    "  match c { case Red -> 1; case Green -> 2; case Blue -> 3 }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0016"), "enum all-cases: no T0016")
}

test "match enum non exhaustive" {
  val src = "package P\n" + "enum Color { case Red; case Green; case Blue }\n" + "func rank(c: in Color): Int {\n" +
    "  match c { case Red -> 1; case Green -> 2 }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0016"), "enum missing Blue: T0016")
}

test "match bool exhaustive" {
  val src = "package P\n" + "func f(b: in Bool): Int { match b { case true -> 1; case false -> 0 } }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0016"), "bool true+false: no T0016")
}

test "match bool non exhaustive" {
  val src = "package P\n" + "func f(b: in Bool): Int { match b { case true -> 1 } }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0016"), "bool missing false: T0016")
}

test "match scalar needs wildcard" {
  val bad = "package P\nfunc f(n: in Int): Int { match n { case 0 -> 0; case 1 -> 1 } }\n"
  val ok = "package P\nfunc f(n: in Int): Int { match n { case 0 -> 0; case _ -> 1 } }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0016"), "int match no wildcard: T0016")
  assertTrue(not hasDiagCode(parseCheck(ok), "T0016"), "int match with wildcard: no T0016")
}

test "match string needs wildcard" {
  val src = "package P\n" + "func f(s: in String): Int { match s { case \"a\" -> 1; case \"b\" -> 2 } }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0016"), "string match no wildcard: T0016")
}

test "propagate result unwrap" {
  val ok = "package P\nunion Result[T, E] { case Ok(value: T); case Err(error: E) }\n" +
    "func f(r: in Result[Int, String]): Unit { val n: Int = r? }\n"
  val bad = "package P\nunion Result[T, E] { case Ok(value: T); case Err(error: E) }\n" +
    "func f(r: in Result[Int, String]): Unit { val s: String = r? }\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0060"), "Result[Int,_]? -> Int: no T0060")
  assertTrue(hasDiagCode(parseCheck(bad), "T0060"), "Result[Int,_]? used as String: T0060")
}

test "propagate option unwrap" {
  val ok = "package P\nunion Option[T] { case Some(value: T); case None }\n" +
    "func f(o: in Option[Int]): Unit { val n: Int = o? }\n"
  val bad = "package P\nunion Option[T] { case Some(value: T); case None }\n" +
    "func f(o: in Option[Int]): Unit { val s: String = o? }\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0060"), "Option[Int]? -> Int: no T0060")
  assertTrue(hasDiagCode(parseCheck(bad), "T0060"), "Option[Int]? used as String: T0060")
}

test "propagate non monadic no t0060" {
  val src = "package P\n" + "func f(n: in Int): Unit { val _x = n? }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0060"), "non-monadic ? yields TyError: no T0060 cascade")
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

test "visibility pub type allowed" {
  val imp = importedItemsOf("package Lib\npub record Widget { x: Int }\n")
  val pr = parse("package App\nfunc f(w: in Widget): Int { 0 }\n")
  val cr = checkWithImports(pr.file, imp)
  assertTrue(not hasDiagCode(cr, "T0097"), "pub imported type: no T0097")
}

test "visibility internal type allowed" {
  // `internal` is visible across packages within a project.
  val imp = importedItemsOf("package Lib\ninternal record Widget { x: Int }\n")
  val pr = parse("package App\nfunc f(w: in Widget): Int { 0 }\n")
  val cr = checkWithImports(pr.file, imp)
  assertTrue(not hasDiagCode(cr, "T0097"), "internal imported type cross-package: no T0097")
}

test "visibility private type rejected" {
  val imp = importedItemsOf("package Lib\nrecord Widget { x: Int }\n")
  val pr = parse("package App\nfunc f(w: in Widget): Int { 0 }\n")
  val cr = checkWithImports(pr.file, imp)
  assertTrue(hasDiagCode(cr, "T0097"), "package-private imported type referenced cross-package: T0097")
}

test "visibility pub func allowed" {
  val imp = importedItemsOf("package Lib\npub func helper(x: in Int): Int { x }\n")
  val pr = parse("package App\nfunc f(): Int { helper(3) }\n")
  val cr = checkWithImports(pr.file, imp)
  assertTrue(not hasDiagCode(cr, "T0097"), "pub imported func: no T0097")
}

test "visibility private func rejected" {
  val imp = importedItemsOf("package Lib\nfunc helper(x: in Int): Int { x }\n")
  val pr = parse("package App\nfunc f(): Int { helper(3) }\n")
  val cr = checkWithImports(pr.file, imp)
  assertTrue(hasDiagCode(cr, "T0097"), "package-private imported func referenced cross-package: T0097")
}

// #5374: `symbolToType`'s `DKTypeAlias` arm followed an alias to its RHS
// without ever calling `checkImportedVisibility` on the alias symbol itself
// (only the eventually-resolved concrete type got the check, via
// `concreteAliasTarget`/`resolveAliasPath`) — so a package-private `alias`
// was silently resolvable cross-package with no T0097, unlike every other
// item kind.
test "visibility pub type alias allowed" {
  val imp = importedItemsOf("package Lib\npub alias Handler = (Int) -> Int\n")
  val pr = parse("package App\nfunc f(h: in Handler): Int { 0 }\n")
  val cr = checkWithImports(pr.file, imp)
  assertTrue(not hasDiagCode(cr, "T0097"), "pub imported type alias: no T0097")
}

test "visibility private type alias rejected" {
  val imp = importedItemsOf("package Lib\nalias Handler = (Int) -> Int\n")
  val pr = parse("package App\nfunc f(h: in Handler): Int { 0 }\n")
  val cr = checkWithImports(pr.file, imp)
  assertTrue(hasDiagCode(cr, "T0097"), "package-private imported type alias referenced cross-package: T0097")
}

test "visibility extern type allowed" {
  // Extern types are FFI-boundary bindings (no `pub`), but are referenced
  // directly across packages (e.g. `List`/`Map`).  They must not be flagged.
  val imp = importedItemsOf("package Lib\nextern type Box = \"System.Object\"\n")
  val pr = parse("package App\nfunc f(b: in Box): Int { 0 }\n")
  val cr = checkWithImports(pr.file, imp)
  assertTrue(not hasDiagCode(cr, "T0097"), "extern type cross-package: no T0097 (FFI boundary)")
}

test "visibility same package unaffected" {
  // A package-private symbol referenced within the same package (not imported)
  // must never be flagged.
  val src = "package P\n" + "record Widget { x: Int }\n" + "func helper(n: in Int): Int { n }\n" +
    "func f(w: in Widget): Int { helper(w.x) }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0097"), "same-package private ref: no T0097")
}

// #1486: impl/interface structural conformance — every abstract interface
// method must be implemented (T0098) with matching parameter arity (T0099).
test "impl conforming" {
  val src = "package P\n" + "interface Greeter { func greet(name: in String): String }\n" + "record G {}\n" +
    "impl Greeter for G { func greet(name: in String): String { name } }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0098"), "conforming impl: no T0098")
  assertTrue(not hasDiagCode(cr, "T0099"), "conforming impl: no T0099")
}

test "impl missing method" {
  val src = "package P\n" + "interface Greeter { func greet(name: in String): String }\n" + "record G {}\n" +
    "impl Greeter for G {}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0098"), "impl missing abstract method: T0098")
}

test "impl arity mismatch" {
  val src = "package P\n" + "interface Greeter { func greet(name: in String): String }\n" + "record G {}\n" +
    "impl Greeter for G { func greet(): String { \"hi\" } }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0099"), "impl method arity mismatch: T0099")
}

test "impl default method optional" {
  // An interface method WITH a body is a default (IMFunc) — an impl need not
  // override it, so omitting it must not produce T0098.
  val src = "package P\n" + "interface Greeter { func greet(name: in String): String { \"hi \" + name } }\n" +
    "record G {}\n" +
    "impl Greeter for G {}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0098"), "default interface method not required: no T0098")
}

// #6445: a default method's `Self` is the interface itself, which owns no
// fields — but both backends ALSO lower a body-bearing interface member onto
// the interface's own class for interface-typed dispatch (JVM D-progress-676,
// MSIL D-progress-753's DIM caveat), where `self.<field>` cannot resolve.
// Before this test, that body went entirely unchecked and panicked (JVM
// J009) or silently mis-lowered (MSIL). `self.<name>` for a name that is not
// an interface member is now rejected at check time under T0118.
test "default method body field access on self is rejected (#6445)" {
  val src = "package P\n" + "interface Peeker {\n" + "  func peekBase(self: in Self): Int {\n" + "    self.base\n" +
    "  }\n" +
    "}\n" +
    "record Thing { base: Int }\n" +
    "impl Peeker for Thing {}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0118"), "self.base in a default body: T0118")
}

// The same shape via a non-receiver `Self`-typed parameter (`other: in
// Self`) hits the identical DIM-lowering gap — `Self` narrows to the
// interface there too, so it owns no fields either.
test "default method body field access on a Self-typed param is rejected (#6445)" {
  val src = "package P\n" + "interface Merger {\n" + "  func score(self: in Self): Int\n" +
    "  func combined(self: in Self, other: in Self): Int {\n" +
    "    other.base\n" +
    "  }\n" +
    "}\n" +
    "record Weighted { base: Int }\n" +
    "impl Merger for Weighted { func score(self: in Self): Int { self.base } }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0118"), "other.base in a default body: T0118")
}

// A default body calling ANOTHER interface member — via `self.<name>()` or a
// bare `<name>()` — is the whole point of a default method and must stay
// legal; T0118 must not fire for it.
test "default method body calling another interface member via self is accepted (#6445)" {
  val src = "package P\n" + "interface Ranker {\n" + "  func score(self: in Self): Int\n" +
    "  func doubled(self: in Self): Int {\n" +
    "    self.score() * 2\n" +
    "  }\n" +
    "}\n" +
    "record Item { v: Int }\n" +
    "impl Ranker for Item { func score(self: in Self): Int { self.v } }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0118"), "self.score() calling another interface member: no T0118")
}

test "default method body calling another interface member bare is accepted (#6445)" {
  val src = "package P\n" + "interface Ranker2 {\n" + "  func score(self: in Self): Int\n" +
    "  func doubled(self: in Self): Int {\n" +
    "    score() * 2\n" +
    "  }\n" +
    "}\n" +
    "record Item2 { v: Int }\n" +
    "impl Ranker2 for Item2 { func score(self: in Self): Int { self.v } }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0118"), "bare score() calling another interface member: no T0118")
}

// ─────────────────────────────────────────────────────────────────────────────
// #6452 — three boundaries of the T0118 name-based check (all fixed together;
// see typechecker_checker.l's T0118 header comment for the design).
// ─────────────────────────────────────────────────────────────────────────────
// Boundary 2 (false positive): a nested block that shadows a `Self`-typed
// parameter name with an unrelated local must NOT trip T0118 — `other`
// inside the `if` is a plain Int, not the outer Self-typed parameter.
test "shadowed Self-typed param name inside a nested block is accepted (#6452)" {
  val src = "package P\n" + "interface Merger {\n" + "  func combined(self: in Self, other: in Self): Int {\n" +
    "    if true {\n" +
    "      val other = 5\n" +
    "      other.toString().length\n" +
    "    } else {\n" +
    "      0\n" +
    "    }\n" +
    "  }\n" +
    "}\n" +
    "record Weighted { base: Int }\n" +
    "impl Merger for Weighted {}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0118"), "shadowed other.toString(): no T0118")
}

// The shadow must be BLOCK-scoped: after the shadowing block exits, the name
// resolves back to the outer Self-typed parameter, so field access is
// rejected again.
test "access after the shadowing block exits is still rejected (#6452)" {
  val src = "package P\n" + "interface Merger2 {\n" + "  func combined(self: in Self, other: in Self): Int {\n" +
    "    if true {\n" +
    "      val other = 5\n" +
    "    }\n" +
    "    other.base\n" +
    "  }\n" +
    "}\n" +
    "record Weighted2 { base: Int }\n" +
    "impl Merger2 for Weighted2 {}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0118"), "other.base after the shadowing block exits: T0118")
}

// A match-arm pattern binding shadows for the arm body only; `.toString()`
// on the arm-bound `other` (a plain Int payload) must not trip T0118.
test "match-arm pattern binding shadowing a Self-typed param name is accepted (#6452)" {
  val src = "package P\n" + "interface Merger3 {\n" + "  func combined(self: in Self, other: in Self): Int {\n" +
    "    val o: Option[Int] = Some(value = 5)\n" +
    "    match o {\n" +
    "      case Some(other) -> other.toString().length\n" +
    "      case None -> 0\n" +
    "    }\n" +
    "  }\n" +
    "}\n" +
    "record Weighted3 { base: Int }\n" +
    "impl Merger3 for Weighted3 {}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0118"), "match-arm-bound other.toString(): no T0118")
}

// A lambda parameter shadows for the lambda body only.
test "lambda parameter shadowing a Self-typed param name is accepted (#6452)" {
  val src = "package P\n" + "interface Merger4 {\n" + "  func combined(self: in Self, other: in Self): Int {\n" +
    "    val f: (Int) -> Int = { other: Int -> other.toString().length }\n" +
    "    f(3)\n" +
    "  }\n" +
    "}\n" +
    "record Weighted4 { base: Int }\n" +
    "impl Merger4 for Weighted4 {}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0118"), "lambda-param other.toString(): no T0118")
}

// A `for`-loop binding shadows for the loop body only.
test "for-loop binding shadowing a Self-typed param name is accepted (#6452)" {
  val src = "package P\n" + "interface Merger5 {\n" + "  func combined(self: in Self, other: in Self): Int {\n" +
    "    var total = 0\n" +
    "    for other in 0 ..< 3 {\n" +
    "      total = total + other.toString().length\n" +
    "    }\n" +
    "    total\n" +
    "  }\n" +
    "}\n" +
    "record Weighted5 { base: Int }\n" +
    "impl Merger5 for Weighted5 {}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0118"), "for-bound other.toString(): no T0118")
}

// Boundary 1 (false negative), depth 1: a chained access through a
// `Self`-returning interface member (`self.withX().base`) is rejected —
// `withX` is itself declared `(self: in Self): Self`.
test "chained access through a Self-returning member is rejected, depth 1 (#6452)" {
  val src = "package P\n" + "interface Builder {\n" + "  func withX(self: in Self): Self\n" +
    "  func peekBase(self: in Self): Int {\n" +
    "    self.withX().base\n" +
    "  }\n" +
    "}\n" +
    "record Thing { base: Int }\n" +
    "impl Builder for Thing { func withX(self: in Self): Self { self } }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0118"), "self.withX().base: T0118")
}

// Depth 2: the chain rule recurses through arbitrarily many Self-returning
// calls before the final non-member access.
test "chained access through a Self-returning member is rejected, depth 2 (#6452)" {
  val src = "package P\n" + "interface Builder2 {\n" + "  func withX(self: in Self): Self\n" +
    "  func peekBase(self: in Self): Int {\n" +
    "    self.withX().withX().base\n" +
    "  }\n" +
    "}\n" +
    "record Thing2 { base: Int }\n" +
    "impl Builder2 for Thing2 { func withX(self: in Self): Self { self } }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0118"), "self.withX().withX().base: T0118")
}

// Explicitness pin queued from #6466's review: the chain rule
// (`isSelfLikeExpr`) is receiver-generic — it walks any Self-typed binding in
// scope, not just `self` — so it already covers a non-`self` Self-typed
// param (`other`) chained through a Self-returning member. Pin both the
// rejection and the accepted counterpart explicitly (T0118).
test "chained access through a Self-returning member via a non-self param is rejected (T0118)" {
  val src = "package P\n" + "interface Merger8 {\n" + "  func withX(self: in Self): Self\n" +
    "  func score(self: in Self): Int\n" +
    "  func combined(self: in Self, other: in Self): Int {\n" +
    "    other.withX().base\n" +
    "  }\n" +
    "}\n" +
    "record Weighted8 { base: Int }\n" +
    "impl Merger8 for Weighted8 {\n" +
    "  func withX(self: in Self): Self { self }\n" +
    "  func score(self: in Self): Int { self.base }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0118"), "other.withX().base: T0118")
}

test "chained call through a non-self param ending in a member call is accepted (T0118)" {
  val src = "package P\n" + "interface Merger9 {\n" + "  func withX(self: in Self): Self\n" +
    "  func score(self: in Self): Int\n" +
    "  func combined(self: in Self, other: in Self): Int {\n" +
    "    other.withX().score()\n" +
    "  }\n" +
    "}\n" +
    "record Weighted9 { base: Int }\n" +
    "impl Merger9 for Weighted9 {\n" +
    "  func withX(self: in Self): Self { self }\n" +
    "  func score(self: in Self): Int { self.base }\n" +
    "}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0118"), "other.withX().score(): no T0118")
}

// A chained call through a member that does NOT return `Self` (e.g. `Int`)
// must not be treated as self-like — no false positive from the chain rule.
test "chained call to a non-Self-returning member is accepted (#6452)" {
  val src = "package P\n" + "interface Counter {\n" + "  func count(self: in Self): Int\n" +
    "  func doubled(self: in Self): Int {\n" +
    "    self.count().toString().length\n" +
    "  }\n" +
    "}\n" +
    "record Thing3 { base: Int }\n" +
    "impl Counter for Thing3 { func count(self: in Self): Int { self.base } }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0118"), "self.count().toString().length: no T0118 from the chain rule")
}

// Boundary 3 (false negative): a parenthesized Self-typed receiver
// (`(other).base`) must be rejected exactly like the bare form.
test "parenthesized Self-typed receiver is rejected (#6452)" {
  val src = "package P\n" + "interface Merger6 {\n" + "  func combined(self: in Self, other: in Self): Int {\n" +
    "    (other).base\n" +
    "  }\n" +
    "}\n" +
    "record Weighted6 { base: Int }\n" +
    "impl Merger6 for Weighted6 {}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0118"), "(other).base: T0118")
}

// Sequencing check (#6452's comment): the paren unwrap must not widen the
// shadowing false positive back open — a parenthesized SHADOWED name stays
// accepted.
test "parenthesized shadowed Self-typed param name is accepted (#6452)" {
  val src = "package P\n" + "interface Merger7 {\n" + "  func combined(self: in Self, other: in Self): Int {\n" +
    "    if true {\n" +
    "      val other = 5\n" +
    "      (other).toString().length\n" +
    "    } else {\n" +
    "      0\n" +
    "    }\n" +
    "  }\n" +
    "}\n" +
    "record Weighted7 { base: Int }\n" +
    "impl Merger7 for Weighted7 {}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0118"), "(other).toString() shadowed: no T0118")
}

// #1487 (§5.2): `in` parameters (and `val`/`let`) are immutable and cannot be
// reassigned (T0087); `var` locals and `out`/`inout` params are mutable.
test "in param no rebind" {
  val src = "package P\nfunc f(x: in Int): Unit { x = 5 }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0087"), "reassigning an `in` param: T0087")
}

test "val no reassign" {
  val src = "package P\nfunc f(): Unit {\n  val x = 1\n  x = 2\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0087"), "reassigning a `val`: T0087")
}

test "var reassign ok" {
  val src = "package P\nfunc f(): Unit {\n  var x = 1\n  x = 2\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0087"), "reassigning a `var`: no T0087")
}

test "out param reassign ok" {
  // `out` params are mutable (they must be assigned), so assigning is fine.
  val src = "package P\nfunc f(x: out Int): Unit { x = 5 }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0087"), "assigning an `out` param: no T0087")
}

test "inout param reassign ok" {
  val src = "package P\nfunc f(x: inout Int): Unit { x = 5 }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0087"), "assigning an `inout` param: no T0087")
}

// #1487 (§5.2): an argument bound to an `out`/`inout` parameter must be a
// mutable l-value (T0085); `in` arguments may be any expression.
test "out arg mutable ok" {
  val src = "package P\nfunc g(x: out Int): Unit { x = 5 }\nfunc f(): Unit {\n  var y = 0\n  g(y)\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0085"), "out arg is a var: no T0085")
}

test "out arg immutable rejected" {
  val src = "package P\nfunc g(x: out Int): Unit { x = 5 }\nfunc f(): Unit {\n  val y = 0\n  g(y)\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0085"), "out arg is a val: T0085")
}

test "out arg literal rejected" {
  val src = "package P\nfunc g(x: out Int): Unit { x = 5 }\nfunc f(): Unit { g(0) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0085"), "out arg is a literal: T0085")
}

test "inout arg mutable ok" {
  val src = "package P\nfunc g(x: inout Int): Unit { x = 5 }\nfunc f(): Unit {\n  var y = 0\n  g(y)\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0085"), "inout arg is a var: no T0085")
}

test "in arg any expr ok" {
  val src = "package P\nfunc g(x: in Int): Unit {}\nfunc f(): Unit { g(0) }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0085"), "in arg literal: no T0085")
}

// #1483 (record-ctor) / #1485 (opaque hiding): a record/opaque construction
// call now yields the constructed type (non-generic records); a named argument
// must reference a real field (T0101); an opaque type cannot be constructed
// outside its declaring package (T0100).
test "ctor returns record type" {
  val ok = "package P\nrecord Point { x: Int; y: Int }\nfunc f(): Unit { val p: Point = Point(x = 1, y = 2) }\n"
  val bad = "package P\nrecord Point { x: Int; y: Int }\nfunc f(): Unit { val q: Int = Point(x = 1, y = 2) }\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0060"), "ctor returns the record type: no T0060")
  assertTrue(hasDiagCode(parseCheck(bad), "T0060"), "record ctor used as Int: T0060")
}

test "ctor unknown field" {
  val src = "package P\nrecord Point { x: Int; y: Int }\nfunc f(): Unit { val p = Point(z = 3) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0101"), "unknown ctor field: T0101")
}

test "ctor known fields ok" {
  val src = "package P\nrecord Point { x: Int; y: Int }\nfunc f(): Unit { val p = Point(x = 1, y = 2) }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0101"), "known ctor fields: no T0101")
}

test "opaque construct cross package" {
  val imp = importedItemsOf("package Lib\npub opaque type Secret { token: String }\n")
  val pr = parse("package App\nfunc f(): Unit { val s = Secret(token = \"x\") }\n")
  val cr = checkWithImports(pr.file, imp)
  assertTrue(hasDiagCode(cr, "T0100"), "opaque construction cross-package: T0100")
}

test "opaque construct same package" {
  val src = "package P\nopaque type Secret { token: String }\nfunc f(): Unit { val s = Secret(token = \"x\") }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0100"), "opaque construction same-package: no T0100")
}

// #1485: pattern-matching an opaque type's representation (record/constructor
// pattern) is forbidden outside its declaring package (T0102); binding /
// wildcard arms remain legal.
test "opaque pattern match cross package" {
  val imp = importedItemsOf("package Lib\npub opaque type Box { item: Int }\n")
  val pr = parse("package App\nfunc f(b: in Box): Int { match b { case Box(x) -> 1; case _ -> 0 } }\n")
  val cr = checkWithImports(pr.file, imp)
  assertTrue(hasDiagCode(cr, "T0102"), "cross-package opaque representation match: T0102")
}

test "opaque binding match cross package ok" {
  val imp = importedItemsOf("package Lib\npub opaque type Box { item: Int }\n")
  val pr = parse("package App\nfunc f(b: in Box): Int { match b { case other -> 0 } }\n")
  val cr = checkWithImports(pr.file, imp)
  assertTrue(not hasDiagCode(cr, "T0102"), "cross-package opaque binding match: no T0102")
}

test "opaque pattern match same package ok" {
  val src = "package P\nopaque type Box { item: Int }\nfunc f(b: in Box): Int { match b { case Box(x) -> 1; case _ -> 0 } }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0102"), "same-package opaque destructure: no T0102")
}

// #1487 (§5.2): an `out` parameter must be assigned before the function
// returns; one never assigned anywhere in the body is rejected (T0086).
test "out assigned ok" {
  val src = "package P\nfunc f(x: out Int): Unit { x = 5 }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0086"), "out param assigned: no T0086")
}

test "out never assigned" {
  val src = "package P\nfunc f(x: out Int): Unit { val y = 1 }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0086"), "out param never assigned: T0086")
}

test "out assigned in branches ok" {
  val src = "package P\nfunc f(c: in Bool, x: out Int): Unit { if c { x = 1 } else { x = 2 } }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0086"), "out assigned in if-branches: no T0086")
}

// An out param NAMED `result` parses as an ordinary EPath identifier
// outside contract clauses (#5735), so the T0086 collector's EPath arm
// credits it directly (Auth.Kernel.Jvm regression; the old EResult
// carve-out this comment once described was removed in #5753).
test "out param named result assigned ok" {
  val src = "package P\nfunc f(x: in Int, result: out Int): Unit { result = x }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0086"), "out param named result assigned: no T0086")
}

test "out param named result never assigned" {
  val src = "package P\nfunc f(x: in Int, result: out Int): Unit { val y = x }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0086"), "out param named result never assigned: T0086")
}

test "out assigned in loop ok" {
  val src = "package P\nfunc f(x: out Int): Unit {\n  var i = 0\n  while i < 3 { x = i; i = i + 1 }\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0086"), "out assigned in loop body: no T0086")
}

test "in param no out check" {
  val src = "package P\nfunc f(x: in Int): Unit { val y = 1 }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0086"), "in param: no T0086")
}

// Scope-aware symbol resolution (cross-package same-named type collision).
//
// `RegexError` is declared by two sibling packages.  Under the old single
// flat last-registered-wins symbol table, whichever `RegexError` was
// registered last won EVERY reference — including the return type inside the
// other package's own function signature.  `checkWithImportedPackages`
// resolves each package's signatures with that package preferred, so the two
// `tryX` functions bind their return type to their OWN package's union.
func sigReturnUserId(cr: in CheckResult, name: in String): Int {
  match mapGet(cr.sigs, name) {
    case None -> 0 - 1
    case Some(sig) -> match sig.returnTy { case TyUser(id, _, _) -> id.id; case _ -> 0 - 1 }
  }
}

func typeSymIdByOrigin(cr: in CheckResult, name: in String, origin: in String): Int {
  var i = 0
  while i < cr.symbols.symbols.count {
    val s = cr.symbols.symbols[i]
    if s.name == name and s.originPackage == origin {
      match symbolTypeIdOpt(s) {
        case Some(tid) -> return tid.id
        case None -> {
        }
      }
    }
    i = i + 1
  }
  0 - 1
}

func regexErrorPkgA(): ParseResult {
  parse("package Pa\n" + "pub union RegexError { case Bad }\n" + "pub func tryA(): RegexError { Bad }\n")
}

func regexErrorPkgB(): ParseResult {
  parse("package Pb\n" + "pub union RegexError { case Worse }\n" + "pub func tryB(): RegexError { Worse }\n")
}

test "scoped resolution no cross package type collision" {
  val pkgA = regexErrorPkgA()
  val pkgB = regexErrorPkgB()
  val imports: List[ImportedPackage] = newList()
  imports.add(ImportedPackage(name = "Pa", items = pkgA.file.items, imports = collectImportNames(pkgA.file.imports)))
  imports.add(ImportedPackage(name = "Pb", items = pkgB.file.items, imports = collectImportNames(pkgB.file.imports)))
  val app = parse("package App\nfunc main(): Int { 0 }\n")
  val cr = checkWithImportedPackages(app.file, imports)

  val idA = sigReturnUserId(cr, "tryA")
  val idB = sigReturnUserId(cr, "tryB")
  assertTrue(idA > 0, "scoped: tryA resolves to a user type")
  assertTrue(idB > 0, "scoped: tryB resolves to a user type")
  assertTrue(idA != idB, "scoped: each package's RegexError resolves to its own union (distinct type ids)")
  // Each return type binds to ITS package's union, not a sibling's.
  assertEqualInt(idA, typeSymIdByOrigin(cr, "RegexError", "Pa"), "scoped: tryA return type is Pa's RegexError")
  assertEqualInt(idB, typeSymIdByOrigin(cr, "RegexError", "Pb"), "scoped: tryB return type is Pb's RegexError")
}

test "flat imports preserve last wins" {
  // The flat `checkWithImports` shim leaves imported symbols with an empty
  // origin package, so scoped resolution's package preference never engages
  // and the historical last-registered-wins behaviour is preserved: both
  // signatures resolve their return type to the SAME (last) RegexError.
  // This pins the back-compat contract — scoped resolution activates only
  // through `checkWithImportedPackages`.
  val pkgA = regexErrorPkgA()
  val pkgB = regexErrorPkgB()
  val flat: List[Item] = newList()
  var ia = 0
  while ia < pkgA.file.items.count {
    flat.add(pkgA.file.items[ia])
    ia = ia + 1
  }
  var ib = 0
  while ib < pkgB.file.items.count {
    flat.add(pkgB.file.items[ib])
    ib = ib + 1
  }
  val app = parse("package App\nfunc main(): Int { 0 }\n")
  val cr = checkWithImports(app.file, flat)
  val idA = sigReturnUserId(cr, "tryA")
  val idB = sigReturnUserId(cr, "tryB")
  assertTrue(idA > 0 and idB > 0, "flat: both signatures resolve to a user type")
  assertEqualInt(idA, idB, "flat imports: last-registered RegexError wins both signatures (back-compat)")
}

// #2282: an imported package's own signatures resolve through ITS declared
// imports (tier 2), not last-registered-wins (tier 3).  `Pa` imports `Pb`
// without declaring its own `Payload`; `Pb` and `Pc` both export one, and `Pc`
// registers last.  Under the old empty-imports scope, tier 1 never fired (no
// local decl) and tier 2 never engaged (empty imports list), so `mk`'s return
// type silently bound to Pc's union.  With `ImportedPackage.imports` threaded,
// tier 2 binds it to Pb's.
test "imported package signature prefers its declared import" {
  val pkgB = parse("package Pb\npub union Payload { case FromB }\n")
  val pkgC = parse("package Pc\npub union Payload { case FromC }\n")
  val pkgA = parse("package Pa\nimport Pb\npub func mk(): Payload { FromB }\n")
  val imports: List[ImportedPackage] = newList()
  imports.add(ImportedPackage(name = "Pa", items = pkgA.file.items, imports = collectImportNames(pkgA.file.imports)))
  imports.add(ImportedPackage(name = "Pb", items = pkgB.file.items, imports = collectImportNames(pkgB.file.imports)))
  imports.add(ImportedPackage(name = "Pc", items = pkgC.file.items, imports = collectImportNames(pkgC.file.imports)))
  val app = parse("package App\nfunc main(): Int { 0 }\n")
  val cr = checkWithImportedPackages(app.file, imports)
  val idMk = sigReturnUserId(cr, "mk")
  val idPb = typeSymIdByOrigin(cr, "Payload", "Pb")
  val idPc = typeSymIdByOrigin(cr, "Payload", "Pc")
  assertTrue(idMk > 0, "import-scope: mk resolves to a user type")
  assertTrue(idPb != idPc, "import-scope: Pb's and Pc's Payload are distinct types")
  assertEqualInt(idMk, idPb, "import-scope: mk's return binds to Pb's Payload (Pa's declared import)")
  assertTrue(idMk != idPc, "import-scope: mk's return is not the last-registered Pc Payload")
}

// A concrete record with `impl Iface for Record` in package A must satisfy an
// `Iface` *parameter* of a free function imported from A when called from a
// consumer package B (the lyric-cache `Cache.get(Cache.inProcess(), …)` shape).
// Same-package this works (registerImplsFromItems keys the relation by TypeId);
// cross-package it regressed because the impl relation was keyed off TypeIds
// that the consumer's scope re-resolved differently.
test "cross package impl satisfies interface at argument position" {
  val pkgAcme = parse(
    "package Acme\npub interface Store { func get(key: in String): Int }\npub record MemStore { var data: Int = 0 }\nimpl Store for MemStore { func get(key: in String): Int { 0 } }\npub func mkStore(): MemStore { MemStore(data = 0) }\npub func lookup(store: in Store, key: in String): Int { store.get(key) }\n"
  )
  val imports: List[ImportedPackage] = newList()
  imports.add(
    ImportedPackage(name = "Acme", items = pkgAcme.file.items, imports = collectImportNames(pkgAcme.file.imports))
  )
  val app = parse("package App\nimport Acme\nfunc run(): Int { lookup(mkStore(), \"k\") }\n")
  val cr = checkWithImportedPackages(app.file, imports)
  assertFalse(hasDiagCode(cr, "T0043"), "cross-package: MemStore satisfies Store parameter (no T0043)")
}

// #1980: `let` bindings are immutable like `val`; reassigning one must emit T0087.
test "let no reassign" {
  val src = "package P\nfunc f(): Unit {\n  let x = 1\n  x = 2\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0087"), "reassigning a `let`: T0087")
  // #3009: the message must name all three immutable binding forms, so a user
  // reassigning a `let` sees their binding kind mentioned.
  assertTrue(Str.contains(diagMessageFor(cr, "T0087"), "`val`/`let`/`in`"), "T0087 message names val/let/in")
}

// #1993: an `inout val` argument must emit T0085.
test "inout arg immutable rejected" {
  val src = "package P\nfunc g(x: inout Int): Unit { x = 5 }\nfunc f(): Unit {\n  val y = 0\n  g(y)\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0085"), "inout arg is a val: T0085")
}

// #1993: an `inout` literal argument must emit T0085.
test "inout arg literal rejected" {
  val src = "package P\nfunc g(x: inout Int): Unit { x = 5 }\nfunc f(): Unit { g(0) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0085"), "inout arg is a literal: T0085")
}

// #1994: forwarding an `out` binding to another `out` param must not emit T0085.
test "out arg forwarded out binding ok" {
  val src = "package P\nfunc g(x: out Int): Unit { x = 5 }\nfunc h(y: out Int): Unit { g(y) }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0085"), "forwarding out binding to out param: no T0085")
}

// #2010: exposed-record constructor returns the record type.
test "exposed rec ctor returns type" {
  val ok = "package P\nexposed record Point { x: Int; y: Int }\nfunc f(): Unit { val p: Point = Point(x = 1, y = 2) }\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0060"), "exposed-rec ctor returns the record type: no T0060")
}

// #2030: multiple out params — only the unassigned one emits T0086.
test "out multiple one unassigned" {
  val src = "package P\nfunc f(x: out Int, y: out Int): Unit { x = 1 }\n"
  val diags = parseCheck(src)
  assertTrue(hasDiagCode(diags, "T0086"), "T0086 fires for the unassigned out param")
  var count = 0
  var i = 0
  while i < diags.diagnostics.count {
    if diags.diagnostics[i].code == "T0086" {
      count = count + 1
    }
    i = i + 1
  }
  assertEqualInt(count, 1, "exactly one T0086 for the unassigned param")
}

// #2038: a body-less function (interface/extern signature) with an `out` param
// must not falsely trigger T0086.
test "out body less no false t0086" {
  val src = "package P\ninterface I { func f(x: out Int): Unit }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0086"), "body-less interface method: no false T0086")
}

// #2074: array[N, T] element inference returns T, not TyError.
test "index array element typed" {
  val src = "package P\nfunc f(a: in array[10, Long]): Int { a[0] }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0070"), "array[N,Long] element is Long, mismatches Int return")
}

// #2074: List[T] element inference returns T.
test "index list element typed" {
  val src = "package P\nextern type List[T] = \"System.Collections.Generic.List`1\"\nfunc f(xs: in List[Long]): Int { xs[0] }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0070"), "List[Long] element is Long, mismatches Int return")
}

// #2079: EResult inside an `ensures:` clause types as the function's return type.
test "result expr typed in ensures" {
  val ok = "package P\nfunc h(x: in Int): Bool ensures: result == true { x > 0 }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "result in ensures: no type error when types agree")
}

// #2025: PParen pattern should trigger T0102 when it wraps a constructor sub-pattern.
test "opaque paren pattern crack rejected" {
  val imp = importedItemsOf("package Lib\npub opaque type Box { item: Int }\n")
  val pr = parse("package App\nfunc f(b: in Box): Int { match b { case (Box(x)) -> 1; case _ -> 0 } }\n")
  val cr = checkWithImports(pr.file, imp)
  assertTrue(hasDiagCode(cr, "T0102"), "PParen wrapping PConstructor: T0102 for opaque crack")
}

// #2025: POr with a cracking sub-pattern should trigger T0102.
test "opaque or pattern crack rejected" {
  val imp = importedItemsOf("package Lib\npub opaque type Box { item: Int }\n")
  val pr = parse("package App\nfunc f(b: in Box): Int { match b { case Box(x) | _ -> 1 } }\n")
  val cr = checkWithImports(pr.file, imp)
  assertTrue(hasDiagCode(cr, "T0102"), "POr with PConstructor sub-pattern: T0102 for opaque crack")
}

// #2025: POr with only binding/wildcard sub-patterns should NOT trigger T0102.
test "opaque or binding pattern ok" {
  val imp = importedItemsOf("package Lib\npub opaque type Box { item: Int }\n")
  val pr = parse("package App\nfunc f(b: in Box): Int { match b { case other | _ -> 0 } }\n")
  val cr = checkWithImports(pr.file, imp)
  assertTrue(not hasDiagCode(cr, "T0102"), "POr with bindings only: no T0102")
}

// #2140: then-branch diverging is Never and is absorbed — the if takes the else type.
test "if then diverging branch absorbed" {
  val src = "package P\nfunc f(c: in Bool): Int { if c { return 0 } else { 1 } }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "if then-diverge: then-return is Never, unifies to Int")
}

// #2141: else-if chain unifies arms.
test "else if chain unify" {
  val ok = "package P\nfunc f(a: in Bool, b: in Bool): Int { if a { 1 } else if b { 2 } else { 3 } }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "else-if chain: all Int arms unify")
  val bad = "package P\nfunc f(a: in Bool, b: in Bool): Int { if a { 1 } else if b { \"s\" } else { 3 } }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0067"), "else-if chain: String arm mismatches T0067")
}

// #2202: or-pattern binding does not double-bind (POr processes first alternative only).
test "match or pattern no double bind" {
  val src = "package P\nunion C { case A(n: Int); case B(n: Int) }\nfunc f(c: in C): Int { match c { case A(v) | B(v) -> v } }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "or-pattern: no double-bind, arm body uses v cleanly")
}

// #2208: a parameter named `result` exercises the same code path as a local named `result`.
test "param named result shadows keyword" {
  val src = "package P\nfunc f(result: in String): Unit {\n  val s: String = result\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "param named result: reads as String, not return type")
}

// #2209: EResult in ensures clause still types as return type (no user binding in scope).
test "result in ensures types as return" {
  val ok = "package P\nfunc h(x: in Int): Bool ensures: result == true { x > 0 }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "result in ensures: types as return type Bool")
}

// #1957: internal function cross-package visibility (no T0097).
test "visibility internal func allowed" {
  val imp = importedItemsOf("package Lib\ninternal func helper(x: in Int): Int { x }\n")
  val pr = parse("package App\nfunc f(): Int { helper(3) }\n")
  val cr = checkWithImports(pr.file, imp)
  assertTrue(not hasDiagCode(cr, "T0097"), "internal imported func cross-package: no T0097")
}

// #1957: multi-segment type path to a package-private type emits T0097.
test "visibility multi segment private type rejected" {
  val imp = importedItemsOf("package Lib\nrecord Widget { x: Int }\n")
  val pr = parse("package App\nfunc f(w: in Lib.Widget): Int { 0 }\n")
  val cr = checkWithImports(pr.file, imp)
  assertTrue(hasDiagCode(cr, "T0097"), "package-private type via multi-segment path: T0097")
}

// #2239: slice[T] parameter — findGenericInPair handles TySlice.
test "generic return slice param instantiated" {
  val src = "package P\ngeneric[T] func head(xs: in slice[T]): T { xs[0] }\nfunc f(bs: in slice[Byte]): Int { head(bs) }\n"
  assertTrue(
    hasDiagCode(parseCheck(src), "T0070"),
    "generic slice param: head(slice[Byte]) returns Byte, mismatches Int"
  )
}

// #2220: user function shadows imported function with same name/arity/param type.
test "user func shadows import by return type" {
  val libSrc = "package Lib\npub func mk(s: in String): Int { 0 }\n"
  val libPr = parse(libSrc)
  val importedItems: List[Item] = newList()
  var i = 0
  while i < libPr.file.items.count {
    importedItems.add(libPr.file.items[i])
    i = i + 1
  }
  val src = "package App\nfunc mk(s: in String): Bool { true }\nfunc f(): Unit { val b: Bool = mk(\"x\") }\n"
  val cr = checkWithImports(parse(src).file, importedItems)
  assertTrue(not hasDiagCode(cr, "T0060"), "user mk(String):Bool shadows import mk(String):Int — Bool binding clean")
}

// #2221: empty-literal slice arg selects the correct overload via TyError-wildcard.
test "empty literal selects slice overload" {
  val libSrc = "package Lib\npub func mk(n: in Int, xs: in slice[String]): Int { 0 }\npub func mk(n: in Int, s: in String): Bool { true }\n"
  val libPr = parse(libSrc)
  val importedItems: List[Item] = newList()
  var i = 0
  while i < libPr.file.items.count {
    importedItems.add(libPr.file.items[i])
    i = i + 1
  }
  val src = "package App\nfunc f(): Unit { val n: Int = mk(1, []) }\n"
  val cr = checkWithImports(parse(src).file, importedItems)
  assertTrue(not hasDiagCode(cr, "T0060"), "empty-literal [] arg selects slice[String] overload: Int binding clean")
}

// #2307: cross-package acceptance — impl PkgA.Greeter for Hello, pass Hello to PkgA.Greeter param.
test "interface subtyping cross package acceptance" {
  val pkgA = parse(
    "package PkgA\npub interface Greeter {\n  func greet(): String\n}\npub func useG(g: in Greeter): String { \"\" }\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(ImportedPackage(name = "PkgA", items = pkgA.file.items, imports = collectImportNames(pkgA.file.imports)))
  val src = "package App\nimport PkgA\nrecord Hello { x: Int }\nimpl Greeter for Hello {\n  func greet(): String { \"hi\" }\n}\nfunc f(): Unit {\n  val s = useG(Hello(x = 1))\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, packages)
  assertTrue(
    not hasDiagCode(cr, "T0043"),
    "cross-package impl acceptance: Hello (impl PkgA.Greeter) accepted at PkgA.Greeter param"
  )
}

// #2275: range-typed params comment collapsed to one line — the behaviour unchanged.
test "range subtype arithmetic clean" {
  // range-typed params must be numeric/ordered; TyRefined wraps the base prim.
  val src = "package P\nfunc f(a: in Int range 0 ..= 150): Bool {\n  val n = a + 1\n  a < 100\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "range-subtype: arithmetic and comparison clean")
}

// ─────────────────────────────────────────────────────────────────────────────
// Front-end soundness: ELambda typing.
// ─────────────────────────────────────────────────────────────────────────────
test "lambda annotated params inferred" {
  val src = "package P\nfunc f(): Unit {\n  val fn = { x: Int -> x + 1 }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "lambda with annotated Int param: no errors")
}

test "lambda unannotated params lenient" {
  val src = "package P\nfunc f(): Unit {\n  val fn = { x -> x }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "lambda with unannotated param: no errors (lenient)")
}

test "lambda body type error reported" {
  val src = "package P\nfunc f(): Unit {\n  val fn = { x: Int -> x + true }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0030") or hasDiagCode(cr, "T0031"), "lambda body type mismatch: error reported")
}

// ─────────────────────────────────────────────────────────────────────────────
// A2 (docs/59 §5.1): bidirectional lambda parameter typing — unannotated
// lambda params adopt the expected function type at call-argument and
// annotated-binding positions, so lambda bodies are actually checked.
// ─────────────────────────────────────────────────────────────────────────────
test "unannotated lambda param typed from callee signature" {
  val src = "package P\nfunc apply(f: in (Int) -> Int, x: in Int): Int {\n  f(x)\n}\nfunc g(): Int {\n  apply({ n -> n + 1 }, 3)\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "lambda param typed Int from apply's signature: no errors")
}

test "lambda-arg body type error diagnosed via expected param type" {
  // Before A2 the param was TyError so `n + true` passed silently.
  val src = "package P\nfunc apply(f: in (Int) -> Int, x: in Int): Int {\n  f(x)\n}\nfunc g(): Int {\n  apply({ n -> n + true }, 3)\n}\n"
  val cr = parseCheck(src)
  assertTrue(
    hasDiagCode(cr, "T0030") or hasDiagCode(cr, "T0031"),
    "Int param makes `n + true` a diagnosed arithmetic mismatch"
  )
}

test "lambda-arg return mismatch diagnosed against expected ret" {
  // With the param typed, the body's Int result no longer unifies with the
  // expected `(Int) -> Bool` — the standard argument check reports it.
  val src = "package P\nfunc applyB(f: in (Int) -> Bool, x: in Int): Bool {\n  f(x)\n}\nfunc g(): Bool {\n  applyB({ n -> n + 1 }, 3)\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0043"), "(Int) -> Int lambda at (Int) -> Bool param: T0043")
}

test "annotated binding types unannotated lambda param" {
  val src = "package P\nfunc f(): Unit {\n  val fn: (Int) -> Bool = { x -> x > 0 }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "declared (Int) -> Bool binding types the lambda param: no errors")
}

test "annotated binding lambda return mismatch diagnosed" {
  val src = "package P\nfunc f(): Unit {\n  val fn: (Int) -> Bool = { x -> x + 1 }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0060"), "declared (Int) -> Bool but body yields Int: T0060")
}

test "generic callee lambda param typed by substitution from sibling arg" {
  // T is inferred Int from the second argument; the lambda's expected type
  // becomes (Int) -> Bool after TyVar substitution.
  val src = "package P\nfunc pick[T](f: in (T) -> Bool, x: in T): T {\n  x\n}\nfunc g(): Int {\n  pick({ n -> n > 0 }, 5)\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "generic expectation substituted to (Int) -> Bool: no errors")
}

test "generic callee lambda body error diagnosed after substitution" {
  val src = "package P\nfunc pick[T](f: in (T) -> Bool, x: in T): T {\n  x\n}\nfunc g(): Int {\n  pick({ n -> n + true }, 5)\n}\n"
  val cr = parseCheck(src)
  assertTrue(
    hasDiagCode(cr, "T0030") or hasDiagCode(cr, "T0031"),
    "substituted Int param makes `n + true` a diagnosed mismatch"
  )
}

test "unresolved generic expectation degrades to lenient" {
  // The generic T occurs only in the lambda's own parameter position, so no
  // sibling argument determines it — the leftover TyVar is erased to TyError
  // and the lambda stays lenient (no false rejection).
  val src = "package P\nfunc only[T](f: in (T) -> Bool): Bool {\n  true\n}\nfunc g(): Bool {\n  only({ n -> n > 0 })\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "undeterminable T erased: lambda stays lenient, no errors")
}

test "arity-mismatched lambda expectation degrades to lenient params" {
  // A two-param lambda at a one-param slot: the expectation is unusable, so
  // params degrade to TyError (no body false positives) and the standard
  // argument check reports the function-shape mismatch.
  val src = "package P\nfunc apply(f: in (Int) -> Int, x: in Int): Int {\n  f(x)\n}\nfunc g(): Int {\n  apply({ a, b -> a }, 3)\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0043"), "two-param lambda at (Int) -> Int param: T0043, not a crash")
}

test "named lambda arg typed via param-name pairing" {
  val src = "package P\nfunc apply(f: in (Int) -> Int, x: in Int): Int {\n  f(x)\n}\nfunc g(): Int {\n  apply(x = 3, f = { n -> n + true })\n}\n"
  val cr = parseCheck(src)
  assertTrue(
    hasDiagCode(cr, "T0030") or hasDiagCode(cr, "T0031"),
    "named-arg lambda still gets the (Int) -> Int expectation"
  )
}

test "function-typed local callee threads expectation to lambda arg" {
  val src = "package P\nfunc g(h: in ((Int) -> Int, Int) -> Int): Int {\n  h({ n -> n + true }, 3)\n}\n"
  val cr = parseCheck(src)
  assertTrue(
    hasDiagCode(cr, "T0030") or hasDiagCode(cr, "T0031"),
    "function-typed value callee: lambda param typed positionally"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Front-end soundness: EAssign in expression position.
// ─────────────────────────────────────────────────────────────────────────────
test "assign stmt type mismatch rejected" {
  val src = "package P\nfunc f(): Unit {\n  var x = 0\n  x = true\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0063"), "assignment with type mismatch: T0063")
}

test "assign stmt same type ok" {
  val src = "package P\nfunc f(): Unit {\n  var x = 0\n  x = 5\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0063"), "assignment with same type: no T0063")
}

test "assign stmt immutable binding rejected" {
  val src = "package P\nfunc f(): Unit {\n  val x = 0\n  x = 5\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0087"), "assignment to val: T0087")
}

// ─────────────────────────────────────────────────────────────────────────────
// Front-end soundness: EForall/EExists quantifiers.
// ─────────────────────────────────────────────────────────────────────────────
test "forall quantifier returns bool" {
  val src = "package P\nfunc f(): Bool {\n  forall(x: Int) x >= 0\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "forall quantifier: returns Bool, no errors")
}

test "exists quantifier returns bool" {
  val src = "package P\nfunc f(): Bool {\n  exists(x: Int) x > 0\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "exists quantifier: returns Bool, no errors")
}

// ─────────────────────────────────────────────────────────────────────────────
// Front-end soundness: tuple-destructure sub-bindings.
// ─────────────────────────────────────────────────────────────────────────────
test "tuple destructure sub-bindings typed" {
  // `val (a, b) = (1, true)` — `a` should be typed Int, `b` Bool, so using
  // them in a numeric context must not produce a false T0030.
  val src = "package P\nfunc f(): Int {\n  val (a, b) = (1, true)\n  a + 1\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0030"), "tuple sub-binding a typed as Int: no T0030 on a+1")
}

test "tuple destructure sub-binding type mismatch" {
  // `b` is Bool; using it as Int should fire T0030.
  val src = "package P\nfunc f(): Int {\n  val (a, b) = (1, true)\n  b + 1\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0030"), "tuple sub-binding b typed as Bool: T0030 on b+1")
}

// ─────────────────────────────────────────────────────────────────────────────
// Front-end soundness: record constructor argument type checking (C2).
// ─────────────────────────────────────────────────────────────────────────────
test "ctor named arg type mismatch rejected" {
  val src = "package P\nrecord Point { x: Int; y: Int }\nfunc f(): Unit { val _ = Point(x = true, y = 2) }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0104"), "ctor named arg type mismatch: T0104")
}

test "ctor named arg type match ok" {
  val src = "package P\nrecord Point { x: Int; y: Int }\nfunc f(): Unit { val _ = Point(x = 1, y = 2) }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0104"), "ctor named arg type match: no T0104")
}

test "ctor positional arg type mismatch rejected" {
  val src = "package P\nrecord Point { x: Int; y: Int }\nfunc f(): Unit { val _ = Point(true, 2) }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0104"), "ctor positional arg type mismatch: T0104")
}

test "ctor positional arg too many rejected" {
  val src = "package P\nrecord Point { x: Int; y: Int }\nfunc f(): Unit { val _ = Point(1, 2, 3) }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0104"), "ctor positional too many: T0104")
}

// ─────────────────────────────────────────────────────────────────────────────
// Front-end soundness: impl conformance — parameter and return type checking (C11).
// ─────────────────────────────────────────────────────────────────────────────
test "impl param type mismatch rejected" {
  val src = "package P\n" + "interface Adder { func add(x: in Int): Int }\n" + "record R {}\n" +
    "impl Adder for R { func add(x: in String): Int { 0 } }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0106"), "impl param type mismatch: T0106")
}

test "impl return type mismatch rejected" {
  val src = "package P\n" + "interface Namer { func name(): String }\n" + "record R {}\n" +
    "impl Namer for R { func name(): Int { 0 } }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0107"), "impl return type mismatch: T0107")
}

test "impl param and return match ok" {
  val src = "package P\n" + "interface Adder { func add(x: in Int): Int }\n" + "record R {}\n" +
    "impl Adder for R { func add(x: in Int): Int { 0 } }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0106"), "impl param type match: no T0106")
  assertTrue(not hasDiagCode(cr, "T0107"), "impl return type match: no T0107")
}

// #6417: an impl method that mirrors the interface's `self: in Self` spelling
// verbatim must conform — `substitutesSelf` previously ran on the
// INTERFACE side of the C11 comparison only, so an impl-side literal `Self`
// (unsubstituted `TySelf`) could never equal the substituted concrete
// target type, and the impl was rejected even though it matches the
// interface exactly.
test "impl method with Self receiver (matching interface) conforms, no T0106" {
  val src = "package P\n" + "interface Tagger { func tag(self: in Self): Int }\n" + "record R { seed: Int }\n" +
    "impl Tagger for R { func tag(self: in Self): Int { self.seed } }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0106"), "impl Self receiver matching interface Self receiver: no T0106")
}

test "impl method with Self in a non-receiver param conforms, no T0106" {
  val src = "package P\n" + "interface Combiner { func combine(self: in Self, other: in Self): Int }\n" +
    "record R { v: Int }\n" +
    "impl Combiner for R { func combine(self: in Self, other: in Self): Int { self.v + other.v } }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0106"), "impl Self non-receiver param matching interface Self param: no T0106")
}

test "impl method with Self return type conforms, no T0107" {
  val src = "package P\n" + "interface Cloner { func dup(self: in Self): Self }\n" + "record R { v: Int }\n" +
    "impl Cloner for R { func dup(self: in Self): Self { R(v = self.v) } }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0107"), "impl Self return matching interface Self return: no T0107")
}

test "impl Self receiver still rejects a genuinely wrong param type, T0106" {
  // Self in the receiver conforms, but a mismatched second parameter must
  // still be rejected — the fix substitutes Self on both sides, it does not
  // weaken the underlying comparison.
  val src = "package P\n" + "interface Adder2 { func add(self: in Self, x: in Int): Int }\n" + "record R { v: Int }\n" +
    "impl Adder2 for R { func add(self: in Self, x: in String): Int { self.v } }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0106"), "impl Self receiver ok, but String-vs-Int second param still: T0106")
}

// ─────────────────────────────────────────────────────────────────────────────
// Front-end soundness: where T: Marker bound satisfaction (H15).
// ─────────────────────────────────────────────────────────────────────────────
test "where bound satisfied ok" {
  val src = "package P\n@derive(Add)\nrecord Meters { value: Int }\nfunc add2[T](a: in T, b: in T): T where T: Add { default() }\nfunc f(): Meters { add2(Meters(value = 1), Meters(value = 2)) }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0108"), "where-bound Add satisfied by @derive(Add): no T0108")
}

test "where bound not satisfied rejected" {
  val src = "package P\nrecord Plain { value: Int }\nfunc add2[T](a: in T, b: in T): T where T: Add { default() }\nfunc f(): Plain { add2(Plain(value = 1), Plain(value = 2)) }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0108"), "where-bound Add not satisfied by Plain: T0108")
}

// ─────────────────────────────────────────────────────────────────────────────
// Front-end soundness: numeric widening (M6).
// ─────────────────────────────────────────────────────────────────────────────
test "int plus long widens to long" {
  val src = "package P\nfunc f(a: in Int, b: in Long): Long { a + b }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "Int + Long widens to Long: no errors")
}

test "int less than long widens" {
  val src = "package P\nfunc f(a: in Int, b: in Long): Bool { a < b }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "Int < Long widens: no errors")
}

test "float plus double widens to double" {
  val src = "package P\nfunc f(a: in Float, b: in Double): Double { a + b }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "Float + Double widens to Double: no errors")
}

test "int plus string still rejected" {
  val src = "package P\nfunc f(a: in Int, b: in String): Unit { val _ = a + b }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0031"), "Int + String still rejected: T0031")
}

test "int plus bool still rejected" {
  val src = "package P\nfunc f(a: in Int, b: in Bool): Unit { val _ = a + b }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0031") or hasDiagCode(cr, "T0030"), "Int + Bool still rejected")
}

test "int literal in long ctor field ok" {
  val src = "package P\nrecord R { id: Long }\nfunc f(): R { R(id = 0) }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "Int literal widened to Long in ctor field")
}

test "long in int ctor field rejected" {
  val src = "package P\nrecord R { id: Int }\nfunc f(v: in Long): R { R(id = v) }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0104"), "Long does not narrow to Int in ctor field")
}

test "slice literal in list ctor field ok" {
  // Declare a local generic `List` so the field type resolves in the bare
  // `check()` harness (which registers no stdlib items) — the slice-
  // satisfies-List rule keys on the type NAME, so a resolved local `List`
  // exercises it the same way the stdlib's does.  This keeps the strict
  // zero-diagnostics assertion meaningful: with the field type resolved,
  // the ctor-argument check runs for real instead of vacuously matching a
  // TyError field (#3190).
  val src = "package P\nrecord List[T] { }\nrecord R { items: List[Int] }\nfunc f(): R { R(items = [1, 2, 3]) }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "slice[Int] satisfies List[Int] in ctor field")
}

// ─────────────────────────────────────────────────────────────────────────────
// #1228: declaration-position type references are validated (no silent
// degradation to Object for unknown type names in declarations).
// ─────────────────────────────────────────────────────────────────────────────
test "record field unknown type emits T0010" {
  val src = "package P\nrecord H { a: Nonexistent }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0010"), "record field unknown type: T0010")
}

test "union case field unknown type emits T0010" {
  val src = "package P\nunion U { case A(payload: Nonexistent) case B }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0010"), "union case field unknown type: T0010")
}

test "interface method unknown return type emits T0010" {
  val src = "package P\ninterface I { func get(): Nonexistent }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0010"), "interface return unknown type: T0010")
}

test "type alias unknown target emits T0010" {
  val src = "package P\nalias A2 = Nonexistent\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0010"), "alias target unknown type: T0010")
}

test "module val unknown annotation emits T0010" {
  val src = "package P\nval g: Nonexistent = 1\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0010"), "module val unknown annotation: T0010")
}

test "generic record field referencing its type param ok" {
  val src = "package P\nrecord Box[T] { value: T }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "Box[T] field T resolves to the type param")
}

test "recursive record field referencing own type ok" {
  val src = "package P\nrecord Node { name: String }\nrecord Tree { root: Node }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "sibling record reference resolves")
}

test "interface method Self return ok" {
  val src = "package P\ninterface Cloneable { func clone(): Self }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "Self in interface return resolves")
}

// ─────────────────────────────────────────────────────────────────────────────
// `Never` (bottom) function subtyping: a lambda whose body diverges types as
// `() -> Never` and must satisfy a `() -> Unit` (or any-return) function
// parameter — the assertPanics shape from #1854's acceptance test.
// ─────────────────────────────────────────────────────────────────────────────
test "never-returning lambda satisfies unit-function param" {
  val src = "package P\nfunc run(fn: in () -> Unit): Unit { fn() }\nfunc f(): Unit { run({ -> panic(\"x\") }) }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0043"), "() -> Never satisfies () -> Unit")
}

test "never-returning lambda satisfies int-function param" {
  val src = "package P\nfunc pick(fn: in () -> Int): Int { fn() }\nfunc f(): Int { pick({ -> panic(\"x\") }) }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0043"), "() -> Never satisfies () -> Int")
}

test "param-count mismatch still rejected for never lambda" {
  val src = "package P\nfunc run(fn: in (Int) -> Unit): Unit { fn(1) }\nfunc f(): Unit { run({ -> panic(\"x\") }) }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0043"), "arity mismatch keeps T0043")
}

// ─────────────────────────────────────────────────────────────────────────────
// #2707: T0109 for value-expression-as-type-argument (distinct from T0012).
// ─────────────────────────────────────────────────────────────────────────────
test "value expr as type arg emits T0109 not T0012" {
  val src = "package P\nimport Std.Collections\nfunc f(): Unit { val _ : List[1] = newList() }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0109"), "value as type arg: T0109")
  assertTrue(not hasDiagCode(cr, "T0012"), "value as type arg: not T0012")
}

// ─────────────────────────────────────────────────────────────────────────────
// #2708: match-arm guard must be Bool (T0066 symmetry with if-condition).
// ─────────────────────────────────────────────────────────────────────────────
test "match arm guard string rejected with T0066" {
  val src = "package P\nfunc f(x: in Int): Int { match x { case _ if \"bad\" -> 1; case _ -> 0 } }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0066"), "match guard non-Bool: T0066")
}

test "match arm guard bool ok" {
  val src = "package P\nfunc f(x: in Int): Int { match x { case _ if x > 0 -> 1; case _ -> 0 } }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "match guard Bool: no errors")
}

// ─────────────────────────────────────────────────────────────────────────────
// #2955: SAssign uses argSatisfiesParam so M6 widening applies.
// ─────────────────────────────────────────────────────────────────────────────
test "assign int to long target ok" {
  val src = "package P\nfunc f(): Unit { var x: Long = 0i64; x = 42 }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "assign Int to Long: no errors")
}

test "assign string to int target rejected" {
  val src = "package P\nfunc f(): Unit { var x: Int = 0; x = \"bad\" }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0063"), "assign wrong type: T0063")
}

// ─────────────────────────────────────────────────────────────────────────────
// #2009: generic record constructor emits T0110 when a type parameter cannot be
// inferred from the supplied arguments.  A phantom type parameter (one that
// appears in no field) is genuinely uninferable — T0110 must fire.
// A constructor where all type params appear in fields (e.g. Pair[A,B]) is
// inferable and must NOT fire T0110.
// ─────────────────────────────────────────────────────────────────────────────
test "generic record constructor emits T0110 for uninferable type param" {
  val src = "package P\nrecord Tagged[T, Phantom] { value: T }\nfunc f(): Unit { val _ = Tagged(value = 1) }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0110"), "phantom type param: T0110")
}

test "generic record constructor with inferable type params does not emit T0110" {
  val src = "package P\nrecord Pair[A, B] { first: A; second: B }\nfunc f(): Unit { val _ = Pair(first = 1, second = \"x\") }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0110"), "inferable generic ctor: no T0110")
}

// ─────────────────────────────────────────────────────────────────────────────
// #2954: unknown constraint name in where-clause emits T0111 warning.
// T0111 fires at the call site (checkBoundsSatisfied); T0051 fires at the
// definition site.  A call to f(42) is needed to trigger the call-site path.
// ─────────────────────────────────────────────────────────────────────────────
test "unknown constraint emits T0111 warning" {
  val src = "package P\nfunc f[T](x: in T): T where T: Addd { x }\nfunc g(): Int { f(42) }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0111"), "unknown constraint: T0111")
}

// #5549 / D-progress-807: T0051 (declaration site) and T0111 (call site)
// are two INDEPENDENT diagnostics that both fire for the same malformed
// where-clause once it is actually called — not two severities chosen
// between for one situation.  T0051 alone needs no call at all.
test "unknown constraint at declaration alone (no call) emits T0051, no T0111" {
  val src = "package P\nfunc f[T](x: in T): T where T: Addd { x }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0051"), "unknown constraint, uncalled: T0051 at declaration")
  assertTrue(not hasDiagCode(cr, "T0111"), "unknown constraint, uncalled: no T0111 (no call site to check)")
}

test "unknown constraint, once called, emits BOTH T0051 and T0111" {
  val src = "package P\nfunc f[T](x: in T): T where T: Addd { x }\nfunc g(): Int { f(42) }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0051"), "unknown constraint, called: T0051 still fires at declaration")
  assertTrue(hasDiagCode(cr, "T0111"), "unknown constraint, called: T0111 also fires at the call site")
}

// #5549 / D-progress-807: `Copyable` was speced (D034) but never
// implemented in the self-hosted checker — dropped from the practical
// marker vocabulary (docs/01 §generics).  It now behaves exactly like
// any other unrecognised where-clause name: T0051 at declaration.
test "Copyable where-bound is an unknown constraint, T0051" {
  val src = "package P\nfunc f[T](x: in T): T where T: Copyable { x }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0051"), "Copyable dropped from the marker vocabulary: T0051")
}

// #5549 / D-progress-807: `hasDerive` gained a `TyPrim` arm mirroring
// `mono.l`'s `primitiveSatisfiesMarker` — a primitive type argument must
// satisfy a capability marker bound without any `derives` clause (it has
// none to opt into).  Previously `hasDerive` returned `false` for every
// `TyPrim`, so this call wrongly raised T0108.
test "primitive type argument satisfies a capability marker where-bound, no T0108" {
  val src = "package P\nfunc add2[T](a: in T, b: in T): T where T: Add { default() }\nfunc f(): Int { add2(1, 2) }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0108"), "Int satisfies where T: Add: no T0108")
}

test "primitive type argument satisfies Compare/Equals/Hash/Default where-bounds, no T0108" {
  val src = "package P\nfunc cmp[T](a: in T, b: in T): T where T: Compare + Equals + Hash + Default { a }\nfunc f(): Int { cmp(1, 2) }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0108"), "Int satisfies Compare/Equals/Hash/Default: no T0108")
}

test "String satisfies Add where-bound via concatenation, no T0108" {
  val src = "package P\nfunc cat[T](a: in T, b: in T): T where T: Add { default() }\nfunc f(): String { cat(\"a\", \"b\") }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0108"), "String satisfies where T: Add (concatenation): no T0108")
}

test "primitive type argument still rejects a non-arithmetic capability, T0108" {
  // Bool has no Add/Sub/Mul/Div/Mod capability -- confirms the TyPrim arm
  // is a real capability table, not a blanket "primitives always satisfy".
  val src = "package P\nfunc add2[T](a: in T, b: in T): T where T: Add { default() }\nfunc f(): Bool { add2(true, false) }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0108"), "Bool does not satisfy where T: Add: T0108")
}

// ─────────────────────────────────────────────────────────────────────────────
// #2179: inferGenericArgs handles nested generic positions (e.g. Seq[T] fields).
// Uses a locally-defined generic wrapper so stdlib is not needed during the
// single-file parseCheck (check() has no imported packages).
// ─────────────────────────────────────────────────────────────────────────────
test "union case with nested generic field infers parent type" {
  val src = "package P\nrecord Seq[T] { head: T }\nunion Box[T] { case Wrap(items: Seq[T]) }\nfunc f(xs: in Seq[Int]): Box[Int] { Wrap(items = xs) }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "nested Seq[T] field: type inferred correctly, no errors")
}

// ─────────────────────────────────────────────────────────────────────────────
// #3157: named constructor args may be supplied in any order — the type
// checker must pair each named arg's type with its declared field by name,
// not positionally.  Pair[A, B] { first: A; second: B } constructed as
// Pair(second = "x", first = 1) must infer A=Int, B=String, not A=String, B=Int.
// ─────────────────────────────────────────────────────────────────────────────
test "generic ctor named args in reverse order infer correct type args" {
  val src = "package P\nrecord Pair[A, B] { first: A; second: B }\nfunc f(): Pair[Int, String] { Pair(second = \"x\", first = 1) }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "named args in reverse order: no errors")
}

test "generic ctor named args in declaration order also work" {
  val src = "package P\nrecord Pair[A, B] { first: A; second: B }\nfunc f(): Pair[Int, String] { Pair(first = 1, second = \"x\") }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "named args in declaration order: no errors")
}

// ─────────────────────────────────────────────────────────────────────────────
// #3156: missing a required field on a generic constructor should emit T0105
// (missing required field), not T0110 (cannot infer type arguments).
// ─────────────────────────────────────────────────────────────────────────────
test "generic ctor missing required field emits T0105 not T0110" {
  val src = "package P\nrecord Pair[A, B] { first: A; second: B }\nfunc f(): Unit { val _ = Pair(first = 1) }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0105"), "missing required field: T0105")
  assertTrue(not hasDiagCode(cr, "T0110"), "missing required field: not T0110")
}

// ─────────────────────────────────────────────────────────────────────────────
// #3066: function-call named args are validated against their named parameter,
// not positionally.  `foo(b = 2, a = "x")` for `foo(a: String, b: Int = 0)`
// is clean; `foo(b = "x", a = 2)` mismatches both parameters (T0043).
// ─────────────────────────────────────────────────────────────────────────────
test "named args reversed heterogeneous clean" {
  val src = "package P\nfunc foo(a: in String, b: in Int = 0): Unit {}\nfunc f(): Unit { foo(b = 2, a = \"x\") }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "named args reversed: types align by name, no T0043")
}

test "named args reversed wrong types rejected" {
  val src = "package P\nfunc foo(a: in String, b: in Int = 0): Unit {}\nfunc f(): Unit { foo(b = \"x\", a = 2) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0043"), "named args reversed with wrong types: T0043")
}

// #3066: the T0085 l-value check pairs an out-of-order named `out` argument
// with its declared parameter — a `var` supplied by name is accepted, a `val`
// supplied by name is rejected.
test "named out arg out of order aligned" {
  val ok = "package P\nfunc g(x: out Int, label: in String): Unit { x = 5 }\nfunc f(): Unit {\n  var y = 0\n  g(label = \"L\", x = y)\n}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0085"), "named out arg (var) out of order: no T0085")
  val bad = "package P\nfunc g(x: out Int, label: in String): Unit { x = 5 }\nfunc f(): Unit {\n  val y = 0\n  g(label = \"L\", x = y)\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0085"), "named out arg (val) out of order: T0085")
}

// ─────────────────────────────────────────────────────────────────────────────
// #3160: a value expression used as a type argument in an alias RHS is T0109
// (not the misleading T0012 "primitive does not take type arguments").
// ─────────────────────────────────────────────────────────────────────────────
test "alias rhs value type arg emits T0109" {
  val src = "package P\nimport Std.Collections\nalias Bad = List[1]\nfunc f(x: in Bad): Unit {}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0109"), "alias RHS value type-arg: T0109")
  assertTrue(not hasDiagCode(cr, "T0012"), "alias RHS value type-arg: not T0012")
}

// ─────────────────────────────────────────────────────────────────────────────
// #2611: an alias target resolves with scope priority — when the current
// package declares `record Random` and an imported package also exports a
// `Random`, `alias R = Random` must bind to the current-package type, so a
// body constructing the local `Random` satisfies an `R` return cleanly.
// ─────────────────────────────────────────────────────────────────────────────
test "alias target prefers current package over import" {
  val dep = parse("package Q\npub record Random {\n  q: Int\n}\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(ImportedPackage(name = "Q", items = dep.file.items, imports = collectImportNames(dep.file.imports)))
  val src = "package P\nimport Q\nrecord Random {\n  x: Int\n}\nalias R = Random\nfunc f(): R { Random(x = 1) }\n"
  val cr = checkWithImportedPackages(parse(src).file, packages)
  assertEqualInt(diagCount(cr), 0, "alias target: current-package Random wins over imported Q.Random")
}

// ─────────────────────────────────────────────────────────────────────────────
// #2355: a value-position `try` handler that can produce a value must be
// compatible with the try body type (both feed one shared temp).  A diverging
// (`panic`/throw → Never) handler stays accepted.
// ─────────────────────────────────────────────────────────────────────────────
test "try value handler type mismatch rejected" {
  val bad = "package P\nfunc f(): Int {\n  val x: Int = try {\n    1\n  } catch Bug as b {\n    \"error\"\n  }\n  x\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0067"), "try value: String handler vs Int body: T0067")
}

test "try value diverging handler accepted" {
  val ok = "package P\nfunc f(): Int {\n  val x: Int = try {\n    1\n  } catch Bug as b {\n    panic(\"boom\")\n  }\n  x\n}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0067"), "try value: Never handler is compatible with any body")
}

test "try value matching handler accepted" {
  val ok = "package P\nfunc f(): Int {\n  val x: Int = try {\n    1\n  } catch Bug as b {\n    0\n  }\n  x\n}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0067"), "try value: Int handler matches Int body")
}

// Statement-position try whose value is discarded: a Unit handler beside a
// value-producing body must stay accepted (the shared temp is never read).
test "try statement unit handler accepted" {
  val ok = "package P\nfunc consume(n: in Int): Unit {}\nfunc f(): Unit {\n  try {\n    1\n  } catch Bug as b {\n    consume(0)\n  }\n}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0067"), "try statement: Unit handler absorbed, no T0067")
}

// #3262: a *value-position* try with a non-Unit body and a Unit handler must
// raise T0067.  If the catch fires, the shared codegen temp the value binds to
// is left unassigned, so silently absorbing the Unit handler (as the earlier
// blanket Unit leniency did) was unsound.
test "try value unit handler rejected" {
  val bad = "package P\nfunc f(): Int {\n  val x: Int = try {\n    42\n  } catch Bug as b {\n    ()\n  }\n  x\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0067"), "try value: Unit handler vs Int body: T0067")
}

// #3262 companion: the statement-position counterpart of the case above stays
// clean — the trailing `try` is a Unit-returning function body, so its value is
// discarded and a Unit handler beside a value-producing body is fine.
test "try statement unit handler with value body accepted" {
  val ok = "package P\nfunc f(): Unit {\n  try {\n    42\n  } catch Bug as b {\n    ()\n  }\n}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0067"), "try statement: Unit handler beside Int body absorbed, no T0067")
}

// #3361: a *non-trailing* try inside a value-position block discards its value,
// so a Unit handler beside a non-Unit body must stay absorbed even when the
// enclosing function returns Int.  The `tryValuePos = valuePos and (i == last)`
// guard makes the non-trailing case statement-position; this pins it so a
// future isLast refactor cannot silently regress it back to a spurious T0067.
test "try non-trailing value-position block stays clean" {
  val ok = "package P\nfunc f(): Int {\n  try {\n    42\n  } catch Bug as b {\n    ()\n  }\n  99\n}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0067"), "non-trailing try: Unit handler discarded, no T0067")
}

// ─────────────────────────────────────────────────────────────────────────────
// #3187: a refutable `for` pattern is rejected by the type checker (T0112) —
// codegen has no failure path for a non-matching element, so accepting it
// produced a broken binary behind an F0021 println.  Irrefutable tuple
// patterns stay accepted.
// ─────────────────────────────────────────────────────────────────────────────
test "for refutable pattern rejected" {
  val bad = "package P\nunion Opt[T] {\n  case Sm(value: T)\n  case Nn\n}\nfunc f(xs: in slice[Opt[Int]]): Unit {\n  for Sm(v) in xs {\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0112"), "for over constructor pattern: T0112")
}

test "for tuple pattern accepted" {
  val ok = "package P\nfunc f(xs: in slice[(Int, String)]): Int {\n  var total = 0\n  for (n, s) in xs {\n    total = total + n\n  }\n  total\n}\n"
  val cr = parseCheck(ok)
  assertTrue(not hasDiagCode(cr, "T0112"), "for over tuple pattern: no T0112")
  assertEqualInt(diagCount(cr), 0, "for over tuple pattern: clean")
}

// ─────────────────────────────────────────────────────────────────────────────
// #2993: config block well-formedness (D046 / docs/25-config-blocks.md).
// Field types outside Bool/Int/Long/Float/Double/String are rejected with
// G0009; non-literal or kind-mismatched defaults with G0010; duplicate field
// names with G0013.  Before this guard, a Float/Long config field silently
// miscompiled (zero-filled default, invalid IL on the env-parse path).
// ─────────────────────────────────────────────────────────────────────────────
test "config field type guard" {
  val bad = "package P\nconfig S { c: Char }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "G0009"), "config: Char field rejected with G0009")
  val badList = "package P\nconfig S { xs: slice[String] }\n"
  assertTrue(hasDiagCode(parseCheck(badList), "G0009"), "config: list field rejected with G0009")
  val ok = "package P\nconfig S2 { a: Bool = true; b: Int = 1; c: Long = 2; d: Float = 0.5; e: Double = 1.5; f: String = \"x\"; g: Int }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "config: full v1 type set accepted")
}

test "config default literal guard" {
  val bad = "package P\nconfig S3 { p: Int = \"oops\" }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "G0010"), "config: kind-mismatched default rejected with G0010")
  val nonLit = "package P\nconfig S5 { p: Int = f() }\nfunc f(): Int { 1 }\n"
  assertTrue(hasDiagCode(parseCheck(nonLit), "G0010"), "config: non-literal default rejected with G0010")
  val neg = "package P\nconfig S4 { off: Int = -1; r: Float = -0.5; w: Long = -9000000000; d: Double = -2.5 }\n"
  assertEqualInt(diagCount(parseCheck(neg)), 0, "config: negated numeric defaults accepted")
  val widen = "package P\nconfig S6 { cap: Long = 5; rate: Float = 2; scale: Double = 3 }\n"
  assertEqualInt(diagCount(parseCheck(widen)), 0, "config: Int literal widens to Long/Float/Double")
}

test "config duplicate field" {
  val dup = "package P\nconfig S7 { p: Int = 1; p: Int = 2 }\n"
  assertTrue(hasDiagCode(parseCheck(dup), "G0013"), "config: duplicate field rejected with G0013")
}

// #3261: the refutability check must recurse into tuple elements — a
// constructor pattern nested inside an otherwise-irrefutable tuple is
// still refutable and must be rejected.
test "for tuple-of-refutable pattern rejected" {
  val bad = "package P\nunion Opt[T] {\n  case Sm(value: T)\n  case Nn\n}\nfunc f(xs: in slice[(Int, Opt[Int])]): Unit {\n  for (n, Sm(v)) in xs {\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0112"), "for tuple containing constructor: T0112")
}

test "for nested tuple pattern accepted" {
  val ok = "package P\nfunc f(xs: in slice[(Int, (Int, String))]): Int {\n  var total = 0\n  for (a, (b, s)) in xs {\n    total = total + a + b\n  }\n  total\n}\n"
  val cr = parseCheck(ok)
  assertTrue(not hasDiagCode(cr, "T0112"), "for over nested tuple pattern: no T0112")
  assertEqualInt(diagCount(cr), 0, "for over nested tuple pattern: clean")
}

// ─────────────────────────────────────────────────────────────────────────────
// docs/59 A1: `for`-loop element typing over ranges and List.  Before this a
// range-driven loop variable was `TyError` (universal wildcard), so the loop
// body was effectively unchecked, and the range bounds themselves were never
// visited by the checker at all.
// ─────────────────────────────────────────────────────────────────────────────
test "for range binds Int" {
  val ok = "package P\nfunc f(n: in Int): Int {\n  var total = 0\n  for i in 0 ..< n {\n    total = total + i\n  }\n  total\n}\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "range-for: Int loop var in arithmetic is clean")
  val bad = "package P\nfunc g(n: in Int): Unit {\n  for i in 0 ..< n {\n    val s: String = i\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0060"), "range-for: String binding of an Int loop var is T0060")
}

test "for range binds Long" {
  val ok = "package P\nfunc f(): Long {\n  var total: Long = 0\n  for i in 1i64 ..= 3i64 {\n    total = total + i\n  }\n  total\n}\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "range-for: Long bounds bind a Long loop var")
  val bad = "package P\nfunc g(): Unit {\n  for i in 1i64 ..= 3i64 {\n    val n: Int = i\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0060"), "range-for: Int binding of a Long loop var is T0060")
}

test "for range bound exprs are checked" {
  val bad = "package P\nfunc h(k: in Int): Int { k }\nfunc f(): Unit {\n  for i in 0 ..< h(\"s\") {\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0043"), "range-for: a bad call inside a bound is now caught (T0043)")
}

// Known-mismatched bound widths (Int lo, Long hi) have no working lowering on
// either backend (the JVM counting-for panics; MSIL emits width-mismatched IL),
// so the checker degrades the binding to the lenient wildcard rather than
// claiming a type — no new rejections for a shape codegen owns.
test "for range mixed-width bounds degrade" {
  val src = "package P\nfunc f(n: in Long): Unit {\n  for i in 0 ..< n {\n    val s: String = i\n  }\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "range-for: mixed Int/Long bounds keep the lenient wildcard")
}

test "for over List binds element type" {
  val ok = "package P\nextern type List[T] = \"System.Collections.Generic.List`1\"\nfunc f(xs: in List[String]): Int {\n  var n = 0\n  for s in xs {\n    n = n + s.length\n  }\n  n\n}\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "list-for: String element member access is clean")
  val bad = "package P\nextern type List[T] = \"System.Collections.Generic.List`1\"\nfunc g(xs: in List[String]): Unit {\n  for s in xs {\n    val i: Int = s\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0060"), "list-for: Int binding of a String element is T0060")
}

// ─────────────────────────────────────────────────────────────────────────────
// docs/59 A3: generic record field access keeps the receiver's instantiation —
// `b.value` on `Box[Int]` is `Int`, mirroring the union path
// (`caseFieldTypesInstantiated`).  Before this the field type resolved under an
// empty generic context to a swallowed `TyError`, so anything flowed.
// ─────────────────────────────────────────────────────────────────────────────
test "generic record field instantiated" {
  val ok = "package P\nrecord Box[T] { value: T }\nfunc f(): Int {\n  val b = Box(value = 41)\n  b.value + 1\n}\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "box-field: Box[Int].value flows into arithmetic cleanly")
  val bad = "package P\nrecord Box[T] { value: T }\nfunc g(): Int {\n  val b = Box(value = \"s\")\n  b.value\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0070"), "box-field: Box[String].value mismatches Int return (T0070)")
}

test "generic record field from annotated param" {
  val bad = "package P\nrecord Box[T] { value: T }\nfunc f(b: in Box[String]): Int {\n  b.value\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0070"), "box-param: Box[String].value mismatches Int return (T0070)")
  val badBind = "package P\nrecord Box[T] { value: T }\nfunc g(b: in Box[String]): Unit {\n  val n: Int = b.value\n}\n"
  assertTrue(hasDiagCode(parseCheck(badBind), "T0060"), "box-param: Int binding of a String field is T0060")
}

// A non-generic record's fields are unaffected, and a generic receiver whose
// instantiation could not be inferred (no targs) stays lenient — the erased
// wildcard, never a new rejection.
test "generic record field degrades without targs" {
  val ok = "package P\nrecord Box[T] { value: T }\nfunc f[T](b: in Box[T]): Int {\n  val n: Int = b.value\n  n\n}\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "box-generic-ctx: uninstantiated T stays lenient")
  val plain = "package P\nrecord Point { x: Int }\nfunc g(p: in Point): Int {\n  p.x + 1\n}\n"
  assertEqualInt(diagCount(parseCheck(plain)), 0, "plain record field access unchanged")
}

// ─────────────────────────────────────────────────────────────────────────────
// Const patterns (docs/46, D101).  checkConstRefPattern diagnostics; the
// positive runtime behaviour lives in const_pattern_self_test.l.  #3485.
// ─────────────────────────────────────────────────────────────────────────────
test "const pattern: undefined name rejected (T0072)" {
  val bad = "package P\nfunc f(x: in Int): Int {\n  match x {\n    case @NOPE -> 1\n    case _ -> 0\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0072"), "const pattern @NOPE (undefined): T0072")
}

test "const pattern: non-val name rejected (T0072)" {
  val bad = "package P\nfunc g(): Int { 1 }\nfunc f(x: in Int): Int {\n  match x {\n    case @g -> 1\n    case _ -> 0\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0072"), "const pattern @g (a func): T0072")
}

test "const pattern: non-literal val rejected (T0069)" {
  val bad = "package P\nfunc now(): Int { 1 }\nval DYN = now()\nfunc f(x: in Int): Int {\n  match x {\n    case @DYN -> 1\n    case _ -> 0\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0069"), "const pattern @DYN (dynamic init): T0069")
}

test "const pattern: type mismatch rejected (T0068)" {
  val bad = "package P\nval NAME = \"hi\"\nfunc f(x: in Int): Int {\n  match x {\n    case @NAME -> 1\n    case _ -> 0\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0068"), "const pattern @NAME (String const, Int scrutinee): T0068")
}

test "const pattern: matching type accepted (no diagnostics)" {
  val ok = "package P\nval WIRE = 2\nfunc f(x: in Int): Int {\n  match x {\n    case @WIRE -> 1\n    case _ -> 0\n  }\n}\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "const pattern @WIRE (Int const, Int scrutinee): clean")
}

// #3488: Bool exhaustiveness must resolve const patterns, not just literals.
test "const pattern: Bool match over both consts is exhaustive (no T0016)" {
  val ok = "package P\nval ON = true\nval OFF = false\nfunc f(b: in Bool): Int {\n  match b {\n    case @ON -> 1\n    case @OFF -> 0\n  }\n}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0016"), "Bool match over @ON/@OFF: no false non-exhaustive")
}

test "const pattern: Bool match missing a const arm is non-exhaustive (T0016)" {
  val bad = "package P\nval ON = true\nfunc f(b: in Bool): Int {\n  match b {\n    case @ON -> 1\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0016"), "Bool match over only @ON: T0016 missing false")
}

// #3510: a type-annotated Bool const (`val ON: Bool = true`) must also be
// resolved by the Bool-exhaustiveness check.  The annotation lives in the
// val's declared type, not its initializer expression, so `constBoolOfExpr`
// still sees a bare `ELiteral(LBool(_))` — confirm no false T0016.
test "const pattern: annotated Bool consts are exhaustive (no T0016) (#3510)" {
  val ok = "package P\nval ON: Bool = true\nval OFF: Bool = false\nfunc f(b: in Bool): Int {\n  match b {\n    case @ON -> 1\n    case @OFF -> 0\n  }\n}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0016"), "annotated Bool consts @ON/@OFF: no false non-exhaustive")
}

// #3509: T0071 (generic-typed const pattern) is a defensive arm in
// checkConstRefPattern that is unreachable from well-formed source: a
// module-level `val`/`const` cannot carry a free type variable, so such a
// declaration fails earlier with T0010 (unknown type name) — and a generic
// container const is rejected as non-literal (T0069) before T0071 is ever
// reached.  There is therefore no positive parse-check that isolates T0071;
// the closest source form (`val EMPTY: Box[T] = Wrap(0)`) emits T0010 + T0069.
test "const pattern: generic container const rejected before T0071 (#3509)" {
  val bad = "package P\nunion Box[T] {\n  case Wrap(v: T)\n}\nval EMPTY: Box[T] = Wrap(0)\nfunc f(x: in Box[Int]): Int {\n  match x {\n    case @EMPTY -> 1\n    case _ -> 0\n  }\n}\n"
  val cr = parseCheck(bad)
  assertTrue(hasDiagCode(cr, "T0010"), "generic-typed const: T0010 unknown type 'T' fires first")
  assertTrue(hasDiagCode(cr, "T0069"), "generic container const is also rejected as non-literal (T0069)")
  // Pin the invariant directly: T0071 must NOT be reachable here, so a future
  // refactor that accidentally made it reachable would fail this test (#3517).
  assertTrue(not hasDiagCode(cr, "T0071"), "T0071 is not reached: T0010/T0069 fire first")
}

// ─────────────────────────────────────────────────────────────────────────────
// W0006 — extern-boundary leak lint (`checkExternBoundaryLeaks` /
// `checkExternLeakType`, #3943).  Previously untested (#3957).
// ─────────────────────────────────────────────────────────────────────────────
// Reuses `importedItemsOf` (defined above, §1484) to collect the imported
// package's items into a list suitable for `checkWithImports`, so every item
// registers with `isImported = true` — the precondition W0006 requires
// before it will fire on a leaked type.
test "extern boundary leak fires for imported nested extern type" {
  val importedItems = importedItemsOf(
    "package Kernel\npub extern type ArrayEnum = \"System.Text.Json.JsonElement+ArrayEnumerator\"\n"
  )
  val src = "package App\npub func f(x: in ArrayEnum): Unit {\n}\n"
  val cr = checkWithImports(parse(src).file, importedItems)
  assertTrue(hasDiagCode(cr, "W0006"), "extern-leak: public fn exposing imported nested extern type triggers W0006")
}

// A kernel file that declares the nested extern type *locally* (not
// imported) is exempt — the FFI boundary is meant to live in that file.
test "extern boundary leak exempts kernel-local declaration" {
  val src = "package Kernel\nextern type ArrayEnum = \"System.Text.Json.JsonElement+ArrayEnumerator\"\npub func f(x: in ArrayEnum): Unit {\n}\n"
  assertTrue(
    not hasDiagCode(parseCheck(src), "W0006"),
    "extern-leak: kernel-local (non-imported) extern type is exempt"
  )
}

test "extern boundary leak does not fire for non-pub top-level function" {
  val importedItems = importedItemsOf(
    "package Kernel\npub extern type ArrayEnum = \"System.Text.Json.JsonElement+ArrayEnumerator\"\n"
  )
  val src = "package App\nfunc f(x: in ArrayEnum): Unit {\n}\n"
  val cr = checkWithImports(parse(src).file, importedItems)
  assertTrue(not hasDiagCode(cr, "W0006"), "extern-leak: non-pub top-level function does not trigger W0006")
}

// #3961: the lint must also catch an `impl` block method, not just
// top-level `IFunc` items.  Unlike a top-level function, an impl-block
// method carries no `pub`/`internal` modifier at all (grammar:
// `ImplMember` is always a bare `FunctionDecl`), so every impl method is
// checked unconditionally.
test "extern boundary leak fires for impl block method" {
  val importedItems = importedItemsOf(
    "package Kernel\npub extern type ArrayEnum = \"System.Text.Json.JsonElement+ArrayEnumerator\"\n"
  )
  val src = "package App\npub interface Scanner {\n  func scan(x: in ArrayEnum): Unit\n}\nrecord S { }\nimpl Scanner for S {\n  func scan(x: in ArrayEnum): Unit {\n  }\n}\n"
  val cr = checkWithImports(parse(src).file, importedItems)
  assertTrue(
    hasDiagCode(cr, "W0006"),
    "extern-leak: impl-block method exposing imported nested extern type triggers W0006"
  )
}

// #3964: a leak nested inside a generic type argument (e.g. `Box[ArrayEnum]`)
// must also be caught, not just a bare reference to the extern type.
test "extern boundary leak fires through generic type argument" {
  val importedItems = importedItemsOf(
    "package Kernel\npub extern type ArrayEnum = \"System.Text.Json.JsonElement+ArrayEnumerator\"\n"
  )
  val src = "package App\nunion Box[T] { case BoxOf(value: T) }\npub func f(x: in Box[ArrayEnum]): Unit {\n}\n"
  val cr = checkWithImports(parse(src).file, importedItems)
  assertTrue(
    hasDiagCode(cr, "W0006"),
    "extern-leak: nested generic type argument exposing imported nested extern type triggers W0006"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// docs/59 A4: method-style calls on user types are arity/argument-checked.
// ─────────────────────────────────────────────────────────────────────────────
test "record body method call: valid call has no diagnostics" {
  val src = "package P\nrecord Counter {\n  n: Int\n  func bump(by: in Int): Int { self.n + by }\n}\nfunc consume(c: in Counter): Int { c.bump(2) }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "valid record method call: no diagnostics")
}

test "record body method call: wrong arg type is T0043" {
  val src = "package P\nrecord Counter {\n  n: Int\n  func bump(by: in Int): Int { self.n + by }\n}\nfunc consume(c: in Counter): Int { c.bump(\"x\") }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0043"), "method arg type mismatch: T0043")
}

test "impl method call: wrong arity is T0042" {
  val src = "package P\ninterface Greeter {\n  func greet(name: in String): String\n}\nrecord G {\n  z: Int\n}\nimpl Greeter for G {\n  func greet(name: in String): String { name }\n}\nfunc consume(g: in G): String { g.greet(\"a\", \"b\") }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0042"), "impl method wrong arity: T0042")
}

test "method return type flows onward" {
  val src = "package P\nrecord Named {\n  tag: Int\n  func name(): String { \"n\" }\n}\nfunc wantInt(x: in Int): Int { x }\nfunc consume(n: in Named): Int { wantInt(n.name()) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0043"), "String method result into Int param: T0043 (return type known)")
}

test "generic record method call: owner generics substituted from receiver" {
  val src = "package P\nrecord Box[T] {\n  v: T\n  func get(): T { self.v }\n}\nfunc consume(b: in Box[Int]): String { b.get() }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0070"), "Box[Int].get(): Int returned where String declared: T0070")
}

test "interface method call: arg types checked" {
  val src = "package P\ninterface Speaker {\n  func speak(volume: in Int): String\n}\nfunc consume(s: in Speaker): String { s.speak(\"loud\") }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0043"), "interface method arg mismatch: T0043")
}

test "dot-named type-associated function callable method-style with typed return" {
  val src = "package P\nrecord Wrap {\n  v: Int\n}\nfunc Wrap.unwrap(w: in Wrap): Int { w.v }\nfunc consume(x: in Wrap): String { x.unwrap() }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0113"), "dot-named method-style call resolves: no T0113")
  assertTrue(hasDiagCode(cr, "T0070"), "dot-named call result Int where String declared: T0070")
}

// ─────────────────────────────────────────────────────────────────────────────
// docs/59 A5: unknown members on member-complete receivers are T0113.
// ─────────────────────────────────────────────────────────────────────────────
test "unknown member on known record is T0113" {
  val src = "package P\nrecord Point {\n  x: Int\n}\nfunc consume(p: in Point): Int { p.nope }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0113"), "unknown field on local record: T0113")
  assertTrue(diagMessageFor(cr, "T0113").contains("Point"), "T0113 names the receiver type")
}

test "unknown method call on known record is T0113" {
  val src = "package P\nrecord Point {\n  x: Int\n}\nfunc consume(p: in Point): Int { p.frobnicate(1) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0113"), "unknown method on local record: T0113")
}

test "typo'd chained member path is T0113" {
  val src = "package P\nrecord Inner {\n  v: Int\n}\nrecord Outer {\n  inner: Inner\n}\nfunc consume(o: in Outer): Int { o.inner.typo }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0113"), "typo on chained member path: T0113")
}

test "toString on a record stays lenient" {
  val src = "package P\nrecord Point {\n  x: Int\n}\nfunc consume(p: in Point): String { p.toString() }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0113"), "toString is a universal codegen intrinsic: no T0113")
}

test "derive-synthesised method names stay lenient before the derive pass" {
  val src = "package P\n@derive(Equals)\nrecord Point {\n  x: Int\n}\nfunc consume(a: in Point, b: in Point): Bool { a.equals(b) }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0113"), "equals resolves post-check via the derive pass: no T0113")
}

test "unknown member on a union receiver stays lenient" {
  val src = "package P\nunion U {\n  case A\n}\nfunc consume(u: in U): Int { u.whatever }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0113"), "unions are not member-complete: no T0113")
}

test "unknown member on an imported record stays lenient" {
  val importedItems = importedItemsOf("package Dep\npub record Widget {\n  w: Int\n}\n")
  val src = "package App\nimport Dep\nfunc consume(x: in Widget): Int { x.mystery() }\n"
  val cr = checkWithImports(parse(src).file, importedItems)
  assertTrue(not hasDiagCode(cr, "T0113"), "imported records may come from method-dropping contract reprs: no T0113")
}

// ─────────────────────────────────────────────────────────────────────────────
// #5603: a concrete non-Unit function must have a value-producing body.
// ─────────────────────────────────────────────────────────────────────────────
test "non-Unit function with absent body is T0114" {
  val src = "package P\nfunc f(): Int\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0114"), "absent body on non-Unit func: T0114")
}

test "non-Unit function with empty block body is T0114" {
  val src = "package P\nfunc f(): Int {\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0114"), "empty block body on non-Unit func: T0114")
}

test "@axiom body-less function stays accepted" {
  val src = "package P\n@axiom\nfunc f(): Int\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0114"), "@axiom body-less: no T0114")
}

test "@externTarget body-less function stays accepted" {
  val src = "package P\n@externTarget(\"System.Math::Abs\")\nfunc abs(x: in Int): Int\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0114"), "@externTarget body-less: no T0114")
}

test "interface method signature stays accepted" {
  val src = "package P\ninterface I {\n  func m(): Int\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0114"), "interface method sig: no T0114")
}

test "Unit function with absent body stays accepted" {
  val src = "package P\nfunc f(): Unit\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0114"), "Unit body-less func: no T0114")
}

// ─────────────────────────────────────────────────────────────────────────────
// #6361: a qualified call into a fully-known Lyric package (an import, not an
// extern type) whose trailing segment doesn't exist anywhere in that package
// must be a compile-time T0020, not a silently-swallowed `TyError` that lets
// codegen (or nothing at all) decide what the call means at runtime.  The
// multi-segment `EPath` `resolveExprPath` sees here is exactly the shape
// `Lyric.AliasRewriter.rewriteFile` produces for a bare `import Std.Char` +
// `Std.Char.isUpperCase(...)` call site, so the rewriter runs first.
// ─────────────────────────────────────────────────────────────────────────────
test "unknown qualified name on a known package is T0020, not silently swallowed (#6361)" {
  val pkg = ImportedPackage(
    name = "Std.Char",
    items = importedItemsOf("package Std.Char\npub func isUpper(c: in Char): Bool { true }\n"),
    imports = newList()
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(pkg)
  val src = "package App\nimport Std.Char\nfunc consume(): Bool { Std.Char.isUpperCase('a') }\n"
  val rewritten = rewriteFile(parse(src).file)
  val cr = checkWithImportedPackages(rewritten, packages)
  assertTrue(hasDiagCode(cr, "T0020"), "typo'd qualified stdlib call ('isUpperCase' vs 'isUpper'): T0020")
  assertTrue(diagMessageFor(cr, "T0020").contains("Std.Char.isUpperCase"), "T0020 names the full qualified path")
}

// D-progress-718 taught `Lyric.AliasRewriter` to flatten a call-callee chain
// of ANY segment depth (e.g. `CloudAgents.SessionStore.getSessions`), not
// just a single-alias-hop `Pkg.foo(...)`. `resolveExprPath`'s T0020 gate
// (`pi < path.segments.count - 1`) is written segment-count-agnostic, but
// the #6361 self-tests above only exercise a 2-segment package (`Std.Char`)
// — this closes the coverage gap for a 3-segment package name so a deeper
// qualified typo is confirmed to still raise T0020 naming the full chain.
test "unknown qualified name on a 3-segment package is T0020 (#6361 deep-chain coverage)" {
  val pkg = ImportedPackage(
    name = "CloudAgents.Kernel.SessionStore",
    items = importedItemsOf("package CloudAgents.Kernel.SessionStore\npub func getSessions(): Int { 1 }\n"),
    imports = newList()
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(pkg)
  val src = "package App\nimport CloudAgents.Kernel.SessionStore\nfunc consume(): Int { CloudAgents.Kernel.SessionStore.getSession() }\n"
  val rewritten = rewriteFile(parse(src).file)
  val cr = checkWithImportedPackages(rewritten, packages)
  assertTrue(hasDiagCode(cr, "T0020"), "typo'd 3-segment qualified call ('getSession' vs 'getSessions'): T0020")
  assertTrue(
    diagMessageFor(cr, "T0020").contains("CloudAgents.Kernel.SessionStore.getSession"),
    "T0020 names the full 3-segment qualified path"
  )
}

test "correctly-spelled qualified name on a known package has no T0020 (#6361 regression guard)" {
  val pkg = ImportedPackage(
    name = "Std.Char",
    items = importedItemsOf("package Std.Char\npub func isUpper(c: in Char): Bool { true }\n"),
    imports = newList()
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(pkg)
  val src = "package App\nimport Std.Char\nfunc consume(): Bool { Std.Char.isUpper('a') }\n"
  val rewritten = rewriteFile(parse(src).file)
  val cr = checkWithImportedPackages(rewritten, packages)
  assertTrue(not hasDiagCode(cr, "T0020"), "correctly-spelled qualified call: no T0020")
}

// A qualified call into an `extern package { ... }` block member, addressed
// through the ENCLOSING file's own package path (the real-world shape:
// `lyric-grpc`'s `grpc.l` calls `Grpc.Kernel.Net.netOpenChannel(...)`, a
// sibling in-project package's `_kernel/` file whose body-less signature
// lives inside such a block). `registerItem`'s `IExtern` arm never adds
// these to `symbols` — they're resolved by codegen, not the ordinary call
// path — so this exercises the same #6361 tightening from the other side:
// the checker must recognise the block member as legitimate (via
// `symTableHasExternBlockMember`), not just typos as illegitimate. Uses
// `Lyric.Pipeline.pipeAddCrossPackageItems` to build `items` exactly as the
// real MSIL/JVM bridges do, so an `extern package` block reaches the
// consumer's `registerItem` pass only if it survives that same filter.
test "qualified call into a cross-package extern-package-block member has no T0020 (#6361)" {
  // `other` guarantees `symTablePackageHasAnySymbol(tbl, "Lib.Kernel")` is
  // true via an ordinary registered symbol, so the assertion below actually
  // exercises `symTableHasExternBlockMember` for `doThing` rather than
  // vacuously passing because the package looked entirely unknown.
  val kernelSrc = "package Lib.Kernel\n" + "pub func other(): Int { 1 }\n" + "@axiom(\"test axiom\")\n" +
    "extern package Foo.Bar {\n" +
    "  pub func doThing(): Int\n" +
    "}\n"
  val kernelItems: List[Item] = newList()
  pipeAddCrossPackageItems(parse(kernelSrc).file, kernelItems)
  val pkg = ImportedPackage(name = "Lib.Kernel", items = kernelItems, imports = newList())
  val packages: List[ImportedPackage] = newList()
  packages.add(pkg)
  val src = "package App\nimport Lib.Kernel\nfunc consume(): Int { Lib.Kernel.doThing() }\n"
  val rewritten = rewriteFile(parse(src).file)
  val cr = checkWithImportedPackages(rewritten, packages)
  assertTrue(
    not hasDiagCode(cr, "T0020"),
    "qualified call into a sibling package's extern-package-block member: no T0020"
  )
}

// #6378: a package whose file is NOTHING BUT one or more `extern package
// { ... }` blocks (no ordinary `pub func`/`pub val`/etc. at all — the real
// shape of `AwsXRay.Kernel.Net` in `lyric-aws-xray/src/_kernel/xray_kernel_jvm.l`)
// never adds anything to `tbl.symbols`, so `symTablePackageHasAnySymbol`
// alone can't distinguish "package known, name typo'd" from "package never
// resolved at all" — reopening #6361's exact silent-TyError gap for this one
// package shape. `symTablePackageHasAnyExternBlockMember` closes it. Unlike
// the `Lib.Kernel` case above, this kernel package has NO `other()` helper —
// the whole point is that `tbl.symbols` never gets an entry for it at all.
test "typo'd qualified call into an all-extern-package-block package is T0020 (#6378)" {
  val kernelSrc = "package Lib.OnlyExtern\n" + "@axiom(\"test axiom\")\n" + "extern package Foo.Bar {\n" +
    "  pub func doThing(): Int\n" +
    "}\n"
  val kernelItems: List[Item] = newList()
  pipeAddCrossPackageItems(parse(kernelSrc).file, kernelItems)
  val pkg = ImportedPackage(name = "Lib.OnlyExtern", items = kernelItems, imports = newList())
  val packages: List[ImportedPackage] = newList()
  packages.add(pkg)
  val src = "package App\nimport Lib.OnlyExtern\nfunc consume(): Int { Lib.OnlyExtern.doThingTypo() }\n"
  val rewritten = rewriteFile(parse(src).file)
  val cr = checkWithImportedPackages(rewritten, packages)
  assertTrue(
    hasDiagCode(cr, "T0020"),
    "typo'd qualified call into an all-extern-package-block package: T0020, not silently swallowed"
  )
  assertTrue(diagMessageFor(cr, "T0020").contains("Lib.OnlyExtern.doThingTypo"), "T0020 names the full qualified path")
}

test "correctly-spelled qualified call into an all-extern-package-block package has no T0020 (#6378 regression guard)" {
  val kernelSrc = "package Lib.OnlyExtern\n" + "@axiom(\"test axiom\")\n" + "extern package Foo.Bar {\n" +
    "  pub func doThing(): Int\n" +
    "}\n"
  val kernelItems: List[Item] = newList()
  pipeAddCrossPackageItems(parse(kernelSrc).file, kernelItems)
  val pkg = ImportedPackage(name = "Lib.OnlyExtern", items = kernelItems, imports = newList())
  val packages: List[ImportedPackage] = newList()
  packages.add(pkg)
  val src = "package App\nimport Lib.OnlyExtern\nfunc consume(): Int { Lib.OnlyExtern.doThing() }\n"
  val rewritten = rewriteFile(parse(src).file)
  val cr = checkWithImportedPackages(rewritten, packages)
  assertTrue(
    not hasDiagCode(cr, "T0020"),
    "correctly-spelled qualified call into an all-extern-package-block package: no T0020"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// #6362: field-style access (`e.message`, no call parens) to a name that
// exists ONLY as a D037 dot-named (UFCS) function — never as a real record
// field or union field — silently typed as `TyError` with no diagnostic
// (the `sigs.containsKey(tname + "." + name)` leniency in
// `maybeUnknownMemberDiag` was written for the CALL arm's `resolveMethodCallPick`
// fallback, but `inferMember`'s field-access arm reused the same helper and
// inherited the same leniency for a receiver shape it was never meant to
// cover). Reached codegen as a `TyError`-typed member read and produced
// `InvalidProgramException` at runtime. The exact repro is the stdlib's own
// `IOError.message` (`lyric-stdlib/std/errors.l`), a cross-package union —
// `inferMember` now checks `sigs` for a dot-named match BEFORE falling back to
// `maybeUnknownMemberDiag`, so this fires regardless of whether the receiver
// type is locally declared or imported (dot-named signatures are known
// globally, unlike record-field enumeration, which `T0113`/`memberCompleteTypes`
// restricts to locally-declared types — see docs/59 A5).
// ─────────────────────────────────────────────────────────────────────────────
test "field-style access to a UFCS-only function on an imported union is T0116 (#6362)" {
  val imp = importedItemsOf(
    "package Std.Errors\npub union IOError {\n  case NotFound(path: String)\n}\npub func IOError.message(e: in IOError): String {\n  match e {\n    case NotFound(path) -> \"not found: \" + path\n  }\n}\n"
  )
  val src = "package App\nimport Std.Errors\nfunc consume(e: in IOError): String { e.message }\n"
  val cr = checkWithImports(parse(src).file, imp)
  assertTrue(hasDiagCode(cr, "T0116"), "field-style access to UFCS-only 'message' on IOError: T0116")
  assertTrue(diagMessageFor(cr, "T0116").contains("IOError"), "T0116 names the receiver type")
  assertTrue(diagMessageFor(cr, "T0116").contains("message"), "T0116 names the field")
}

test "call-style access to the same UFCS function still compiles cleanly (#6362 regression guard)" {
  val imp = importedItemsOf(
    "package Std.Errors\npub union IOError {\n  case NotFound(path: String)\n}\npub func IOError.message(e: in IOError): String {\n  match e {\n    case NotFound(path) -> \"not found: \" + path\n  }\n}\n"
  )
  val src = "package App\nimport Std.Errors\nfunc consume(e: in IOError): String { e.message() }\n"
  val cr = checkWithImports(parse(src).file, imp)
  assertTrue(not hasDiagCode(cr, "T0116"), "call-style e.message(): no T0116")
  assertTrue(not hasDiagCode(cr, "T0113"), "call-style e.message(): no T0113")
  assertEqualInt(diagCount(cr), 0, "call-style e.message(): no diagnostics at all")
}

test "field-style access to a real record field alongside an unrelated UFCS function stays clean (#6362 regression guard)" {
  val src = "package P\nrecord Point {\n  x: Int\n}\nfunc Point.length(p: in Point): Int { p.x }\nfunc consume(p: in Point): Int { p.x }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0116"), "real field 'x' access: no T0116 even though 'Point.length' exists")
  assertEqualInt(diagCount(cr), 0, "real field access: no diagnostics at all")
}

test "field-style access to a record field bound through a union case pattern stays clean (#6362 regression guard)" {
  val src = "package P\nrecord Point {\n  x: Int\n}\nunion Wrapper {\n  case Wrap(inner: Point)\n}\nfunc consume(w: in Wrapper): Int {\n  match w {\n    case Wrap(inner) -> inner.x\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0116"), "field access on a union-case-bound record: no T0116")
  assertEqualInt(diagCount(cr), 0, "field access on a union-case-bound record: no diagnostics at all")
}

// `lyric-stdlib/std/app.l`'s real shape: an opaque type whose accessor UFCS
// function shares its wrapped field's name and reads it field-style inside
// its own body. Opaque fields aren't enumerated by `fieldsOfRecord` (they're
// visible only within the declaring package, via the construction-only
// `ctorAllFields` path), so `inferMemberBase` always returns `TyError` for
// them — the #6362 fix's dot-named check must not treat that as proof the
// name is UFCS-only, or this exact stdlib pattern misfires T0116.
test "field-style access to an opaque type's own field, inside its same-named accessor, stays clean (#6362 regression guard)" {
  val src = "package P\nopaque type Config {\n  path: String\n}\nfunc Config.path(config: in Config): String {\n  config.path\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0116"), "opaque field read inside its own same-named accessor: no T0116")
  assertEqualInt(diagCount(cr), 0, "opaque field read inside its own same-named accessor: no diagnostics at all")
}

// #6382 (review follow-up on #6362): the same-package opaque exemption above
// must NOT extend to an IMPORTED opaque type's own accessor. Outside its
// declaring package, an opaque type's representation is never legitimately
// readable field-style at all (that's the whole point of `opaque` — see this
// repo's glossary), so `cfg.path` here can only mean the UFCS function
// `Config.path`, exactly like the union case above. Confirmed end-to-end
// against the real `Std.App.Config` shape before this fix: compiled cleanly
// and crashed at runtime with `InvalidProgramException`, the exact bug class
// #6362 exists to close.
test "field-style access to an imported opaque type's accessor is T0116, not exempted like the local case (#6382)" {
  val imp = importedItemsOf(
    "package Lib\npub opaque type Config {\n  path: String\n}\npub func Config.path(config: in Config): String {\n  return config.path\n}\n"
  )
  val src = "package App\nimport Lib\nfunc consume(cfg: in Config): String { cfg.path }\n"
  val cr = checkWithImports(parse(src).file, imp)
  assertTrue(hasDiagCode(cr, "T0116"), "field-style access to an imported opaque type's UFCS-only accessor: T0116")
  assertTrue(diagMessageFor(cr, "T0116").contains("Config"), "T0116 names the receiver type")
  assertTrue(diagMessageFor(cr, "T0116").contains("path"), "T0116 names the field")
}

test "call-style access to the same imported opaque accessor still compiles cleanly (#6382 regression guard)" {
  val imp = importedItemsOf(
    "package Lib\npub opaque type Config {\n  path: String\n}\npub func Config.path(config: in Config): String {\n  return config.path\n}\n"
  )
  val src = "package App\nimport Lib\nfunc consume(cfg: in Config): String { cfg.path() }\n"
  val cr = checkWithImports(parse(src).file, imp)
  assertTrue(not hasDiagCode(cr, "T0116"), "call-style cfg.path(): no T0116")
  assertEqualInt(diagCount(cr), 0, "call-style cfg.path(): no diagnostics at all")
}

// #6383 (second review follow-up on #6362): the local-opaque exemption must
// be scoped to the field's OWN name, not "any name on a local opaque type."
// `isOpaqueOwnFieldName` checks the accessed name against `ctorAllFields`
// (the same, only-visible-in-declaring-package field list) rather than
// exempting every field-style read on a local opaque receiver — an
// unrelated dot-named function sharing the type stays subject to T0116
// exactly like it would on a record or union.
test "field-style access to an unrelated UFCS function on a local opaque type is T0116, not exempted (#6383)" {
  val src = "package P\nopaque type Config {\n  path: String\n}\nfunc Config.summary(c: in Config): String {\n  return \"config\"\n}\nfunc consume(c: in Config): String {\n  c.summary\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0116"), "field-style access to an unrelated UFCS function on a local opaque type: T0116")
  assertTrue(diagMessageFor(cr, "T0116").contains("Config"), "T0116 names the receiver type")
  assertTrue(diagMessageFor(cr, "T0116").contains("summary"), "T0116 names the field")
}

test "call-style access to the same unrelated local-opaque UFCS function still compiles cleanly (#6383 regression guard)" {
  val src = "package P\nopaque type Config {\n  path: String\n}\nfunc Config.summary(c: in Config): String {\n  return \"config\"\n}\nfunc consume(c: in Config): String {\n  c.summary()\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0116"), "call-style c.summary(): no T0116")
  assertEqualInt(diagCount(cr), 0, "call-style c.summary(): no diagnostics at all")
}

// #6467: T0064/T0065 (early `return` inside a function body) now render the
// alias the user wrote too, matching T0070/T0114 — `checkStatement` receives
// `returnTyExpr: Option[TypeExpr]` threaded alongside `returnTy`, seeded from
// `fn.ret` at `checkFunctionBody`'s `newScopeForFunction` call. The early
// return sits inside an `if` block so the assertion also proves the thread
// survives a nested `checkBlock` recursion, not just the function's own
// top-level block.
test "T0065 early-return mismatch names the alias the user wrote (#6467)" {
  val src = "package P\nalias Meters = Long\nfunc f(b: in Bool): Meters {\n  if b {\n    return \"oops\"\n  }\n  return 0i64\n}\n"
  val cr = parseCheckAliasResolved(src)
  val m = diagMessageFor(cr, "T0065")
  assertTrue(Str.contains(m, "Meters (aka Long)"), "T0065 message names the alias: " + m)
}

// No-alias control: a plain `Long`-returning function's early-return
// mismatch renders unchanged (bare type name, no "aka").
test "T0065 early-return mismatch with no alias renders unchanged (#6467)" {
  val src = "package P\nfunc f(b: in Bool): Long {\n  if b {\n    return \"oops\"\n  }\n  return 0i64\n}\n"
  val cr = parseCheckAliasResolved(src)
  val m = diagMessageFor(cr, "T0065")
  assertTrue(Str.contains(m, "Long") and not Str.contains(m, "aka"), "T0065 message has no alias: " + m)
}

// T0064 (return-without-value mismatch) shares the same `returnTyExpr`
// thread as T0065 — cover it too so both SReturn arms are pinned.
test "T0064 return-without-value mismatch names the alias the user wrote (#6467)" {
  val src = "package P\nalias Meters = Long\nfunc f(): Meters {\n  return\n}\n"
  val cr = parseCheckAliasResolved(src)
  val m = diagMessageFor(cr, "T0064")
  assertTrue(Str.contains(m, "Meters (aka Long)"), "T0064 message names the alias: " + m)
}

// #6467 family 2: call-argument-vs-declared-parameter mismatches (T0043) also
// render the alias — `ResolvedParam` gains a `tyExpr: Option[TypeExpr] = None`
// field (defaulted, so the three construction sites that don't have a source
// `TypeExpr` in hand are untouched), populated at `resolveFunctionSig` /
// `resolveMethodSigParts` from the same alias-resolved `p.ty` that seeds
// `Scope.returnTyExpr`.  `substituteMethodSig` threads it through unchanged.
test "T0043 call-argument mismatch names the alias the user wrote (#6467)" {
  val src = "package P\nalias Meters = Long\nfunc takesMeters(m: in Meters): Unit {\n}\nfunc f(): Unit {\n  takesMeters(\"oops\")\n}\n"
  val cr = parseCheckAliasResolved(src)
  val m = diagMessageFor(cr, "T0043")
  assertTrue(Str.contains(m, "Meters (aka Long)"), "T0043 message names the alias: " + m)
}

test "T0043 call-argument mismatch with no alias renders unchanged (#6467)" {
  val src = "package P\nfunc takesLong(m: in Long): Unit {\n}\nfunc f(): Unit {\n  takesLong(\"oops\")\n}\n"
  val cr = parseCheckAliasResolved(src)
  val m = diagMessageFor(cr, "T0043")
  assertTrue(Str.contains(m, "Long") and not Str.contains(m, "aka"), "T0043 message has no alias: " + m)
}

// #6467 family 2: impl-vs-interface signature mismatches (T0106/T0107) don't
// need any `ResolvedParam`/`ResolvedSignature` plumbing at all —
// `checkImplConformance` already compares the raw `sig.params[pi].ty` /
// `fn.params[pi].ty` (and `sig.ret` / `fn.ret`) `TypeExpr`s directly, so this
// is a `renderTypeExpr`/`renderOptTypeExpr` call-site swap only.
test "T0106 impl param type mismatch names the interface's alias (#6467)" {
  val src = "package P\nalias Meters = Long\ninterface Sizer {\n  func size(m: in Meters): Int\n}\nrecord Box {\n  n: Int\n}\nimpl Sizer for Box {\n  func size(m: in String): Int {\n    0\n  }\n}\n"
  val cr = parseCheckAliasResolved(src)
  val m = diagMessageFor(cr, "T0106")
  assertTrue(Str.contains(m, "Meters (aka Long)"), "T0106 message names the interface's alias: " + m)
}

test "T0107 impl return type mismatch names the interface's alias (#6467)" {
  val src = "package P\nalias Meters = Long\ninterface Namer {\n  func name(): Meters\n}\nrecord Box {\n  n: Int\n}\nimpl Namer for Box {\n  func name(): String {\n    \"x\"\n  }\n}\n"
  val cr = parseCheckAliasResolved(src)
  val m = diagMessageFor(cr, "T0107")
  assertTrue(Str.contains(m, "Meters (aka Long)"), "T0107 message names the interface's alias: " + m)
}

// ─────────────────────────────────────────────────────────────────────────────
// #6481: protected-type entry/func bodies are now type-checked (D-progress-772).
// `checkProtectedDeclTypes` only ever resolved an entry/func member's
// param/return TYPE REFERENCES — the body itself silently compiled unchecked
// until now.  Covers the exact #6476 repro shape (a well-typed-looking `?`
// unwrap whose trailing value doesn't match the declared `Result` return),
// the alias-aware T0070 rendering (mirrors the #6467 family above, now also
// reachable from a protected-type member), an unknown bare name inside an
// entry body, a well-typed control (a bare-name write to a `var` field must
// stay clean), an immutable `let` field write (reuses the ordinary
// `LocalBinding.isMutable` -> T0087 path, no new mode-checker rule), a
// wrong-type call argument inside an entry body, and the `PMFunc` (protected
// `func` member) analog — the same gap existed there and is fixed the same
// way.
test "protected entry body: #6476 repro shape rejected with T0070" {
  val src = "package P\nunion Result[T, E] { case Ok(value: T); case Err(error: E) }\n" +
    "protected type Bag {\n  var count: Int = 0\n  entry f(r: in Result[Int, String]): Result[Int, String] {\n    val v = r?\n    v\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(
    hasDiagCode(cr, "T0070"),
    "entry body: #6476 repro shape (Int trailing value vs Result[Int,String] return) rejected with T0070"
  )
}

test "protected entry body: T0070 names the alias the user wrote (#6481, mirrors #6467)" {
  val src = "package P\nalias Meters = Long\nprotected type Bag {\n  var count: Int = 0\n  entry f(): Meters {\n    \"oops\"\n  }\n}\n"
  val cr = parseCheckAliasResolved(src)
  val m = diagMessageFor(cr, "T0070")
  assertTrue(Str.contains(m, "Meters (aka Long)"), "entry body T0070 message names the alias: " + m)
}

test "protected entry body: unknown name rejected with T0020" {
  val src = "package P\nprotected type Bag {\n  var count: Int = 0\n  entry f(): Unit {\n    count = unknownName\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0020"), "entry body: unknown bare name rejected with T0020")
}

test "protected entry body: well-typed write to a var field stays clean (control)" {
  val src = "package P\nprotected type Bag {\n  var count: Int = 0\n  entry inc(): Unit {\n    count = count + 1\n  }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "entry body: well-typed var-field write has no diagnostics")
}

test "protected entry body: write to an immutable let field rejected with T0087" {
  val src = "package P\nprotected type Bag {\n  let capacity: Int = 10\n  entry f(): Unit {\n    capacity = 5\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0087"), "entry body: bare-name write to a `let` field rejected with T0087")
}

test "protected entry body: wrong-type call argument rejected with T0043" {
  val src = "package P\nfunc takesInt(n: in Int): Unit {\n}\nprotected type Bag {\n  var count: Int = 0\n  entry f(): Unit {\n    takesInt(\"oops\")\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0043"), "entry body: wrong-type call argument rejected with T0043")
}

test "protected func member body: ill-typed trailing expression rejected with T0070" {
  val src = "package P\nprotected type Bag {\n  var count: Int = 0\n  func bad(): Int {\n    val v: String = \"x\"\n    v\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0070"), "func member body: ill-typed trailing expr rejected with T0070")
}

// #6485: the `self.`-spelling twin of the #6481 matrix above.  `self` is a
// keyword — every occurrence parses to the dedicated `ESelf` AST node, never
// `EPath(["self"])` — so it never went through the `extraLocals`/
// `scopeTryFind` machinery #6481 seeded for the bare-name spelling: `self.x`
// typed as the placeholder `TySelf`, which `inferMemberBase` cannot resolve
// to a field, and silently degraded to `TyError` with no diagnostic at all
// (the exact bug in #6485 — `entry f(): Unit { self.count = "oops" }`
// compiled clean). `checkFunctionBody`'s new `selfFields` map (built from the
// SAME `extraLocals` list #6481 already threads in) closes this for reads,
// writes, and unknown names.
//
// Mutability enforcement for the `self.`-prefixed write spelling is
// deliberately NOT duplicated here: it is already the mode checker's job
// (V0015, `checkFieldWriteTarget`'s `ESelf` arm, shipped for protected types
// by #6203 — see `modechecker_self_test.l`'s "protected-type entry
// self-field write to a non-var field is V0015 (#6203)"). The type checker's
// T0087 assignment-target-mutability check only ever matches a bare-name
// `EPath` target (see `checkFunctionBody`'s header comment and the T0087
// call sites in `typechecker_exprs.l`/`typechecker_stmts.l`) — it was never
// extended to `EMember` targets, on purpose, so a `self.<letField> = v`
// write is rejected by exactly one pass (the control test below proves the
// type checker stays silent on it, so the two passes never double-report).
test "protected entry body: self.count write-type mismatch rejected (#6485)" {
  val src = "package P\nprotected type Bag {\n  var count: Int = 0\n  entry f(): Unit {\n    self.count = \"oops\"\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0063"), "entry body: self.count = \"oops\" write-type mismatch rejected with T0063")
}

test "protected entry body: unknown self field rejected with T0020 (#6485)" {
  val src = "package P\nprotected type Bag {\n  var count: Int = 0\n  entry f(): Int {\n    self.nope\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0020"), "entry body: self.nope (unknown field) rejected with T0020")
}

test "protected entry body: well-typed self.count write and read stay clean (#6485 control)" {
  val src = "package P\nprotected type Bag {\n  var count: Int = 0\n  entry inc(): Unit {\n    self.count = self.count + 1\n  }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "entry body: well-typed self.count write+read has no diagnostics")
}

test "protected entry body: self.<letField> write is not double-reported by the type checker (#6485)" {
  // V0015 (mode checker) already rejects this write; the type checker must
  // stay silent so the two passes report it exactly once between them.
  val src = "package P\nprotected type Bag {\n  let capacity: Int = 10\n  entry f(): Unit {\n    self.capacity = 5\n  }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(
    diagCount(cr),
    0,
    "entry body: self.<letField> write has no type-checker diagnostics (V0015 owns mutability)"
  )
}

// #6486 review: the read-case unknown-field test above (#6485) has no
// WRITE-side twin — `self.nope = 5` reaches the exact same `EMember(ESelf,
// name)` branch via `SAssign`'s target-type inference (`checkStatement`
// infers `target` with the general `inferExpr`, so there is only one
// resolution path for both reads and writes), so this closes the matrix
// without any production-code change.
test "protected entry body: self.nope write (unknown field) rejected with T0020 (#6486 review)" {
  val src = "package P\nprotected type Bag {\n  var count: Int = 0\n  entry f(): Unit {\n    self.nope = 5\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0020"), "entry body: self.nope = 5 (unknown field write) rejected with T0020")
}

// ─────────────────────────────────────────────────────────────────────────────
// #6487: `RMFunc` (record-body method) and `IMplFunc` (impl-block method)
// bodies are now type-checked (D-progress-774) — the larger sibling of
// #6481/#6485's protected-member body-checking above. Neither member kind
// was ever routed through `checkFunctionBody` at all (not even ordinary
// arg/return-type checks), so `func doubled(self: in Thing): Int { "oops" }`
// and `impl Scorer for Thing { func score(self: in Self): Int { "oops" } }`
// both compiled with zero diagnostics — the exact issue repro. `self.field`
// resolves via the SAME `sc.selfFields`/`sc.selfChecked` machinery #6485
// built, seeded from the record's own fields (record methods) or the impl
// target's fields substituted through the impl's own generics (impl
// methods, `implTargetFieldLocals`) — but WITHOUT the bare-name spelling
// protected members get (`self.field` is the only spelling either member
// kind supports; codegen never desugars a bare identifier for `RMFunc`/
// `IMplFunc`, only for protected `entry`/`func`).
test "record body method: String body for Int method rejected with T0070 (#6487 repro)" {
  val src = "package P\nrecord Thing {\n  n: Int\n  func doubled(self: in Thing): Int {\n    \"oops-record-method\"\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(
    hasDiagCode(cr, "T0070"),
    "record method body: String trailing expr vs declared Int return rejected with T0070"
  )
}

test "impl method: String body for Int method rejected with T0070 (#6487 repro)" {
  val src = "package P\ninterface Scorer {\n  func score(self: in Self): Int\n}\nrecord Thing {\n  n: Int\n}\nimpl Scorer for Thing {\n  func score(self: in Self): Int {\n    \"oops-impl-method\"\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(
    hasDiagCode(cr, "T0070"),
    "impl method body: String trailing expr vs declared Int return rejected with T0070"
  )
}

test "record body method: unknown name in body rejected with T0020 (#6487)" {
  val src = "package P\nrecord Thing {\n  n: Int\n  func bad(): Int {\n    unknownName\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0020"), "record method body: unresolved bare name rejected with T0020")
}

test "impl method: unknown name in body rejected with T0020 (#6487)" {
  val src = "package P\ninterface Scorer {\n  func score(): Int\n}\nrecord Thing {\n  n: Int\n}\nimpl Scorer for Thing {\n  func score(): Int {\n    unknownName\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0020"), "impl method body: unresolved bare name rejected with T0020")
}

test "record body method: self.field read+write well-typed stays clean (#6487 control)" {
  val src = "package P\nrecord Box {\n  n: Int\n  func setN(v: in Int): Unit {\n    self.n = v\n  }\n  func getN(): Int {\n    self.n\n  }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "record method body: well-typed self.n write+read has no diagnostics")
}

test "record body method: self.field write-type mismatch rejected with T0063 (#6487)" {
  val src = "package P\nrecord Box {\n  n: Int\n  func bad(): Unit {\n    self.n = \"oops\"\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0063"), "record method body: self.n = \"oops\" write-type mismatch rejected with T0063")
}

test "record body method: unknown self field rejected with T0020 (#6487)" {
  val src = "package P\nrecord Box {\n  n: Int\n  func bad(): Int {\n    self.nope\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0020"), "record method body: self.nope (unknown field) rejected with T0020")
}

test "impl method: self.field read well-typed stays clean (#6487 control)" {
  val src = "package P\ninterface Scorer {\n  func score(): Int\n}\nrecord Thing {\n  n: Int\n}\nimpl Scorer for Thing {\n  func score(): Int {\n    self.n\n  }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "impl method body: well-typed self.n read has no diagnostics")
}

test "impl method: self.field write-type mismatch rejected with T0063 (#6487)" {
  val src = "package P\ninterface Setter {\n  func setN(v: in Int): Unit\n}\nrecord Thing {\n  n: Int\n}\nimpl Setter for Thing {\n  func setN(v: in Int): Unit {\n    self.n = \"oops\"\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0063"), "impl method body: self.n = \"oops\" write-type mismatch rejected with T0063")
}

test "impl method: unknown self field rejected with T0020 (#6487)" {
  val src = "package P\ninterface Scorer {\n  func score(): Int\n}\nrecord Thing {\n  n: Int\n}\nimpl Scorer for Thing {\n  func score(): Int {\n    self.nope\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0020"), "impl method body: self.nope (unknown field) rejected with T0020")
}

test "generic record method body: self.field types as the owner's own type param, no diagnostics (#6487)" {
  val src = "package P\nrecord Box[T] {\n  v: T\n  func get(): T {\n    self.v\n  }\n}\nfunc consume(b: in Box[Int]): Int {\n  b.get()\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "generic record method body: well-typed self.v: T has no diagnostics")
}

// Deliberately NOT a "self.v (T) vs a concrete declared return is T0070"
// case: `typeEquiv` (typechecker_types.l) treats an unconstrained `TyVar`
// as universally equivalent to anything on either side (the same wildcard
// leniency `TyError` gets), a pre-existing rule that predates #6487 and
// applies to every generic-bodied function, not just record/impl methods —
// so `self.v: T` never conflicts with a concrete declared return inside the
// owning generic method itself (the CALL SITE is where a closed `Box[Int]`
// substitutes `T` and a real mismatch becomes T0070, already covered by the
// docs/59 A4 test above, "generic record method call: owner generics
// substituted from receiver"). This test instead proves the generic-owner
// case doesn't accidentally widen `selfFields` lookup into leniency too — an
// unknown field on a generic record's own method body still rejects.
test "generic record method body: unknown self field still rejected with T0020 (#6487)" {
  val src = "package P\nrecord Box[T] {\n  v: T\n  func bad(): T {\n    self.nope\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0020"), "generic record method body: self.nope (unknown field) rejected with T0020")
}

test "record body method: T0070 names the alias the user wrote (#6487, mirrors #6481/#6467)" {
  val src = "package P\nalias Meters = Long\nrecord Box {\n  n: Int\n  func bad(): Meters {\n    \"oops\"\n  }\n}\n"
  val cr = parseCheckAliasResolved(src)
  val m = diagMessageFor(cr, "T0070")
  assertTrue(Str.contains(m, "Meters (aka Long)"), "record method body T0070 message names the alias: " + m)
}

// #6483: protected-type `entry`/`func` members register into the method-sig
// space, so a sibling member called by bare name (or through `self.`) from
// another member body resolves — and a genuinely-unknown bare name in the
// same position still gets its T0020.
test "protected member: bare sibling entry/func calls resolve (#6483)" {
  val src = "package P\nprotected type Counter {\n  var total: Int = 0\n  entry add(n: in Int): Unit {\n    total = total + n\n  }\n  func doubled(): Int {\n    total * 2\n  }\n  entry bumpAndDouble(n: in Int): Int {\n    add(n)\n    doubled()\n  }\n  entry viaSelf(n: in Int): Int {\n    self.add(n)\n    self.doubled()\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0020"), "protected member body: bare + self. sibling calls resolve (no T0020)")
}

test "protected member: unknown bare call still rejected with T0020 (#6483)" {
  val src = "package P\nprotected type Counter {\n  var total: Int = 0\n  entry bump(): Unit {\n    nosuch()\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0020"), "unknown bare call inside a protected member body: T0020 still fires")
}

// #6488 review: a cross-compile-unit `impl` whose target record arrives as
// an IMPORTED item (the restored-package preamble shape — a consumer package
// writing `impl Iface for RestoredRecord`) must resolve `self.field` through
// `implTargetFieldLocals`/`findRecordDeclByTypeId` exactly like a same-file
// impl, and still reject an unknown field.
test "impl over an imported record: self.field resolves (#6488)" {
  val libPr = parse("package Lib\npub record Counter {\n  n: Int\n}\npub interface Scorer {\n  func score(): Int\n}\n")
  val pr = parse("package App\nimpl Scorer for Counter {\n  func score(): Int {\n    self.n\n  }\n}\n")
  val cr = checkWithImports(pr.file, libPr.file.items)
  assertTrue(not hasDiagCode(cr, "T0020"), "imported-record impl body: self.n resolves (no T0020)")
  assertTrue(not hasDiagCode(cr, "T0070"), "imported-record impl body: Int field matches Int return (no T0070)")
}

test "impl over an imported record: unknown self field still rejected (#6488)" {
  val libPr = parse("package Lib\npub record Counter {\n  n: Int\n}\npub interface Scorer {\n  func score(): Int\n}\n")
  val pr = parse("package App\nimpl Scorer for Counter {\n  func score(): Int {\n    self.nope\n  }\n}\n")
  val cr = checkWithImports(pr.file, libPr.file.items)
  assertTrue(hasDiagCode(cr, "T0020"), "imported-record impl body: self.nope rejected with T0020")
}

// #6488 review: checker-level pins for the ECall bare-sibling fallback
// (#1722/#6435): a bare call to a sibling method of the enclosing type
// resolves through the implicit `self`, while a genuinely-unknown bare
// name in the same position still gets its T0020.
test "record method: bare sibling-method call resolves through implicit self (#6488)" {
  val src = "package P\nrecord Counter {\n  n: Int\n  func base(): Int {\n    self.n\n  }\n  func viaBare(): Int {\n    base()\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0020"), "bare sibling-method call inside a record method body: no T0020")
}

test "record method: unknown bare call still rejected with T0020 (#6488)" {
  val src = "package P\nrecord Counter {\n  n: Int\n  func viaBare(): Int {\n    nosuch()\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0020"), "unknown bare call inside a record method body: T0020 still fires")
}

// #6488 review: inside a checked member body a whole-`self` read has the
// concrete receiver type — a record method passing `self` to a sibling UFCS
// function (the lyric-cache `evictKey(self, key)` shape) must not T0043.
test "record method: self as call argument matches the concrete receiver type (#6488)" {
  val src = "package P\nrecord Store {\n  n: Int\n  func poke(): Int {\n    sibling(self)\n  }\n}\nfunc sibling(s: in Store): Int {\n  s.n\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0043"), "self as call argument: no T0043 against the concrete parameter type")
}

test "impl method: self as call argument matches the concrete receiver type (#6488)" {
  val src = "package P\ninterface Poker {\n  func poke(): Int\n}\nrecord Store {\n  n: Int\n}\nimpl Poker for Store {\n  func poke(): Int {\n    sibling(self)\n  }\n}\nfunc sibling(s: in Store): Int {\n  s.n\n}\n"
  val cr = parseCheck(src)
  assertTrue(
    not hasDiagCode(cr, "T0043"),
    "impl-body self as call argument: no T0043 against the concrete parameter type"
  )
}

// #6488 review: forwarding an `out` param through a call that assigns it
// (`writeVia(dst: out Int) { writeRaw(dst) }`) must not T0086 — the
// syntax-only collector credits bare-variable call arguments (deliberate
// false-negative trade-off, same as the ELambda carve-out).
test "out param forwarded through a call: no T0086 (#6488)" {
  val src = "package P\nfunc writeRaw(dst: out Int): Unit { dst = 7 }\nfunc writeVia(dst: out Int): Unit { writeRaw(dst) }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0086"), "out param forwarded via call argument: no T0086")
}

test "impl method out param forwarded via bare sibling call: no T0086 (#6488)" {
  val src = "package P\ninterface W {\n  func writeRaw(dst: out Int): Unit\n  func writeVia(dst: out Int): Unit\n}\nrecord S {\n  v: Int\n}\nimpl W for S {\n  func writeRaw(dst: out Int): Unit {\n    dst = self.v\n  }\n  func writeVia(dst: out Int): Unit {\n    writeRaw(dst)\n  }\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0086"), "impl-body out param forwarded via bare sibling call: no T0086")
}

test "out param never mentioned still fires T0086 after the call-argument credit (#6488)" {
  val src = "package P\nfunc helper(v: in Int): Unit { val _ = v }\nfunc f(x: out Int): Unit { helper(1) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0086"), "out param never mentioned anywhere: T0086 still fires")
}

// #4775: `null` has no meaning as a pattern (the language has no null
// literal or null pattern, D107) — the lexer treats it as an ordinary
// identifier, so `case null -> ...` silently parsed as a catch-all binding
// named `null` and matched every value, null or not.  Reject it with a hard
// diagnostic instead.
test "case null: T0073 fires, null pattern rejected (#4775)" {
  val src = "package P\nfunc f(x: in Int): Int {\n  match x {\n    case null -> 1\n    case _ -> 2\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0073"), "case null: T0073 fires")
}

test "case null as a non-first arm still fires T0073 (#4775)" {
  val src = "package P\nfunc f(x: in Int): Int {\n  match x {\n    case 0 -> 1\n    case null -> 2\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0073"), "non-first-arm case null: T0073 still fires")
}

test "nested case null (inside a constructor pattern) still fires T0073 (#4775)" {
  val src = "package P\nimport Std.Core\nfunc f(x: in Option[Int]): Int {\n  match x {\n    case Some(null) -> 1\n    case None -> 2\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0073"), "nested case Some(null): T0073 fires")
}

test "an ordinary identifier binding pattern does not fire T0073 (#4775)" {
  val src = "package P\nfunc f(x: in Int): Int {\n  match x {\n    case n -> n\n  }\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0073"), "ordinary binding pattern: no T0073")
}
