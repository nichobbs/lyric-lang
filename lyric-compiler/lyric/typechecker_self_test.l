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
  val srcSame = "package App\n" + "func collide(x: in Int): Int { x + 1 }\n" + "func use(): Int { collide(7) }\n"
  val prSame = parse(srcSame)
  val crSame = checkWithImports(prSame.file, importedItems)
  assertTrue(
    diagCount(crSame) == 0,
    "first-wins: same-name same-arity user redeclaration does not crash and emits no diagnostics"
  )

  // (b) same name + different arity: user overload registers on its
  // own arity-qualified key; both calls resolve.
  val srcDiff = "package App2\n" + "func collide(x: in Int, y: in Int): Int { x + y }\n" +
    "func use(): Int { collide(7, 8) }\n"
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
  val ok = "package P\nfunc use(n: in Int): Unit {}\nfunc f(): Unit {\n  try {\n    1\n  } catch Bug as b {\n    use(0)\n  }\n}\n"
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
  val badList = "package P\nconfig S { xs: [String] }\n"
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
