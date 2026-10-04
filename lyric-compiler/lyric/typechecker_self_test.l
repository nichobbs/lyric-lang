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

// The symbols the checked source declares: the FFI intrinsic types the
// checker registers itself (`NativePtr`, D158) are not counted.
func symCount(cr: in CheckResult): Int {
  var n = 0
  for sym in cr.symbols.symbols {
    if not cr.symbols.nativeIntrinsicTypes.containsKey(sym.name) {
      n = n + 1
    }
  }
  n
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

// #7545: true when some diagnostic's message contains `needle` — used to
// assert on the slice/List conversion-hint suffix (`typeMismatchHint`)
// without pinning the whole message string.
func diagMessagesContain(cr: in CheckResult, needle: in String): Bool {
  var i = 0
  while i < cr.diagnostics.count {
    if Str.contains(cr.diagnostics[i].message, needle) {
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

// #7665: `slice[T].toList()`'s result type must always be the genuine
// stdlib `List[T]` `lowerSliceToListMsil` (`Msil.Codegen`) actually
// constructs at runtime, never a same-named local type — resolving `List`
// by a bare, shadowable name lookup let a local `record List` intercept
// the type-checker's resolution while codegen still built a real BCL
// `List<E>` regardless, so a `val` binding with an incompatible declared
// type silently accepted it (via `typeEquiv`'s `TyError`-equals-anything
// rule) instead of failing to compile, then crashed with
// `InvalidCastException` at runtime.  `isStdCollectionsHostType` fixes
// this by resolving `List` through its owning package
// (`Std.CollectionsHost`) rather than by name, mirroring
// `isStdCoreMonadType`'s precedent for `Std.Core.Result`/`Option`. #7696
// reuses this same fake-stdlib-package harness for the bracket-literal
// (`[...]`) direct-List-typing arms, which switched to the identical
// id-based resolution (see the "list literal ..." tests below).
func stdCollectionsHostPackages(): List[ImportedPackage] {
  // #7737: `Map` and the key/value collections too, so the index/iteration
  // paths that recognise them by identity can be tested against the real
  // declaring package.
  val pkg = parse(
    "package Std.CollectionsHost\nextern type List[T] = \"System.Collections.Generic.List`1\"\n" +
      "extern type Map[K, V] = \"System.Collections.Generic.Dictionary`2\"\n" +
      "extern type MapKeyCollection[K, V] = \"System.Collections.Generic.Dictionary`2+KeyCollection\"\n" +
      "extern type MapValueCollection[K, V] = \"System.Collections.Generic.Dictionary`2+ValueCollection\"\n" +
      "extern type Set[T] = \"System.Collections.Generic.HashSet`1\"\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Std.CollectionsHost",
      items = pkg.file.items,
      imports = collectImportNames(pkg.file.imports),
      wholeImports = collectWholeImportNames(pkg.file.imports)
    )
  )
  packages
}

// #7702: the type the checker recorded for the qualified/method call that
// starts at `callText`'s first occurrence in `src` (`SymbolTable.callResultTypes`,
// keyed by the call's `recordCopySiteKey`), rendered as `Head[Arg, ...]` with
// every path joined by `.`; "" when no type was recorded. A call whose result
// degraded to `TyError` records nothing, so a clean diagnostic count alone
// cannot tell a genuinely resolved `.toList()` from a vacuous one, and this
// can.
func recordedCallType(cr: in CheckResult, src: in String, callText: in String): String {
  val start = Str.indexOfRaw(src, callText)
  if start < 0 {
    return ""
  }
  val prefix = toString(start) + ":"
  val keys = mapKeys(cr.symbols.callResultTypes)
  var i = 0
  while i < keys.count {
    if Str.startsWith(keys[i], prefix) {
      match mapGet(cr.symbols.callResultTypes, keys[i]) {
        case Some(te) -> return typeExprText(te)
        case None -> ()
      }
    }
    i = i + 1
  }
  ""
}

func typeExprText(te: in TypeExpr): String {
  match te.kind {
    case TRef(path) -> joinSegments(path.segments)
    case TGenericApp(head, args) -> {
      var s = joinSegments(head.segments) + "["
      var i = 0
      while i < args.count {
        if i > 0 {
          s = s + ", "
        }
        s = s + match args[i] { case TAType(ty) -> typeExprText(ty); case _ -> "?" }
        i = i + 1
      }
      s + "]"
    }
    case TSlice(element) -> "slice[" + typeExprText(element) + "]"
    case TTuple(types) -> {
      var s = "("
      var i = 0
      while i < types.count {
        if i > 0 {
          s = s + ", "
        }
        s = s + typeExprText(types[i])
        i = i + 1
      }
      s + ")"
    }
    case _ -> "?"
  }
}

func joinSegments(segs: in List[String]): String {
  var s = ""
  var i = 0
  while i < segs.count {
    if i > 0 {
      s = s + "."
    }
    s = s + segs[i]
    i = i + 1
  }
  s
}

// #7702: the package whose type the bare name `name` resolves to in `cr`'s
// symbol table ("" when unresolved). `callResultTypes` spells a type by its
// bare name only when that name denotes the SAME type id at the use site, so
// pairing a bare `List[...]` recording with this lookup pins the recorded type
// to `Std.CollectionsHost`'s `List` by identity, not just by name.
func bareTypeOrigin(cr: in CheckResult, name: in String): String {
  match symTableTryFindOne(cr.symbols, name) {
    case Some(sym) -> sym.originPackage
    case None -> ""
  }
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

// D-progress-969: a negated literal adopts the other operand's type like the
// literal itself, and a generic's type parameter takes the wider numeric type
// when a literal argument widens at a bare `T` parameter.
test "negated literal and widening generic argument" {
  val neg = "package P\npub func f(x: in Long): Bool {\n  x == -1\n}\n"
  assertEqualInt(diagCount(parseCheck(neg)), 0, "int-lit: Long == -1 type-checks")
  // A negated literal never adopts a type with no negative values.
  val negU = "package P\npub func f(x: in UInt): Bool {\n  x == -1\n}\n"
  assertTrue(diagCount(parseCheck(negU)) > 0, "int-lit: UInt == -1 is rejected")
  val negN = "package P\npub func f(x: in Nat): Bool {\n  x == -1\n}\n"
  assertTrue(diagCount(parseCheck(negN)) > 0, "int-lit: Nat == -1 is rejected")
  val posU = "package P\npub func f(x: in UInt): Bool {\n  x == 1\n}\n"
  assertEqualInt(diagCount(parseCheck(posU)), 0, "int-lit: UInt == 1 type-checks")
  val gen = "package P\nunion R[T] {\n  case Good(v: T)\n  case Bad\n}\npub func pick[T](r: in R[T], d: in T): T {\n  match r {\n    case Good(v) -> v\n    case Bad -> d\n  }\n}\npub func big(): R[Long] {\n  Good(v = 5000000000i64)\n}\npub func useLong(): Long {\n  pick(big(), 0)\n}\n"
  assertEqualInt(diagCount(parseCheck(gen)), 0, "generic: T binds Long, the Int literal widens")
  val wrong = "package P\nunion R[T] {\n  case Good(v: T)\n  case Bad\n}\npub func pick[T](r: in R[T], d: in T): T {\n  match r {\n    case Good(v) -> v\n    case Bad -> d\n  }\n}\npub func big(): R[Long] {\n  Good(v = 5000000000i64)\n}\npub func useString(): String {\n  val s: String = pick(big(), 0)\n  s\n}\n"
  assertTrue(hasDiagCode(parseCheck(wrong), "T0060"), "generic: a Long result assigned to String is T0060")
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

// ─────────────────────────────────────────────────────────────────────────────
// #7752: an `if`/`match` in a position with a known expected type is checked
// branch by branch against that type instead of joining its branch types
// bottom-up, and a union-case construction adopts the expected instantiation
// (so `Ok(value = English(…))` is a `Result[Greeter, String]`, not a
// `Result[English, <error>]` whose `E` degraded to a wildcard).
// ─────────────────────────────────────────────────────────────────────────────
func expectedBranchPrelude(): String {
  "package P\npub interface Greeter {\n  func greet(): Int\n}\nrecord En {\n  n: Int\n}\nrecord Fr {\n  n: Int\n}\nrecord Other {\n  n: Int\n}\nimpl Greeter for En {\n  func greet(): Int { return self.n }\n}\nimpl Greeter for Fr {\n  func greet(): Int { return self.n }\n}\nunion Res[T, E] {\n  case Ok2(value: T)\n  case Err2(err: E)\n}\nunion Opt[T] {\n  case Some2(value: T)\n  case None2\n}\nrecord Box[T] {\n  v: T\n}\nfunc useRes(r: in Res[Greeter, String]): Int {\n  match r {\n    case Ok2(g) -> g.greet()\n    case Err2(_) -> 0\n  }\n}\nfunc useG(g: in Greeter): Int { g.greet() }\n"
}

test "expected type: if branches over different records in tail position (#7752)" {
  val src = expectedBranchPrelude() +
    "func mk(c: in Bool, d: in Bool): Res[Greeter, String] {\n  if c {\n    Ok2(value = En(n = 1))\n  } else if d {\n    Ok2(value = Fr(n = 2))\n  } else {\n    Err2(err = \"x\")\n  }\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "tail if: Ok2(En)/Ok2(Fr)/Err2 checked against Res[Greeter, String]")
}

test "expected type: match arms over different records in tail position (#7752)" {
  val src = expectedBranchPrelude() +
    "func mk(n: in Int): Res[Greeter, String] {\n  match n {\n    case 0 -> Ok2(value = En(n = 1))\n    case 1 -> Ok2(value = Fr(n = 2))\n    case _ -> Err2(err = \"x\")\n  }\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "tail match: arms checked against Res[Greeter, String]")
}

test "expected type: return, annotated bindings, assignment, argument and field positions (#7752)" {
  val ret = expectedBranchPrelude() +
    "func mk(c: in Bool): Res[Greeter, String] {\n  return if c { Ok2(value = En(n = 1)) } else { Ok2(value = Fr(n = 2)) }\n}\n"
  assertEqualInt(diagCount(parseCheck(ret)), 0, "return if")
  val binding = expectedBranchPrelude() +
    "func f(c: in Bool): Int {\n  val r: Res[Greeter, String] = if c { Ok2(value = En(n = 1)) } else { Ok2(value = Fr(n = 2)) }\n  var g: Greeter = match c {\n    case true -> En(n = 3)\n    case false -> Fr(n = 4)\n  }\n  g = if c { Fr(n = 5) } else { En(n = 6) }\n  useRes(r) + g.greet()\n}\n"
  assertEqualInt(diagCount(parseCheck(binding)), 0, "annotated val/var and assignment")
  val arg = expectedBranchPrelude() +
    "func f(c: in Bool): Int {\n  useRes(if c { Ok2(value = En(n = 1)) } else { Ok2(value = Fr(n = 2)) }) + useG(match c {\n    case true -> En(n = 3)\n    case false -> Fr(n = 4)\n  })\n}\n"
  assertEqualInt(diagCount(parseCheck(arg)), 0, "call arguments")
  val field = expectedBranchPrelude() +
    "record Holder {\n  r: Res[Greeter, String]\n  g: Greeter\n}\nfunc f(c: in Bool): Holder {\n  Holder(r = if c { Ok2(value = En(n = 1)) } else { Ok2(value = Fr(n = 2)) }, g = if c { En(n = 3) } else { Fr(n = 4) })\n}\n"
  assertEqualInt(diagCount(parseCheck(field)), 0, "record constructor fields")
  val opt = expectedBranchPrelude() +
    "func f(c: in Bool, d: in Bool): Opt[Greeter] {\n  if c { Some2(value = En(n = 1)) } else if d { Some2(value = Fr(n = 2)) } else { None2 }\n}\n"
  assertEqualInt(diagCount(parseCheck(opt)), 0, "Opt[Greeter] from Some2/None2 branches")
  val plain = expectedBranchPrelude() + "func f(c: in Bool): Greeter {\n  if c { En(n = 1) } else { Fr(n = 2) }\n}\n"
  assertEqualInt(diagCount(parseCheck(plain)), 0, "plain interface from record branches")
}

test "expected type: union-case construction adopts the expected instantiation (#7752)" {
  // Before #7752 both were rejected: the construction typed as
  // `Res[En, <error>]`, which a binding's / argument's (non-covariant)
  // check does not accept for `Res[Greeter, String]`.
  val binding = expectedBranchPrelude() +
    "func f(): Int {\n  val r: Res[Greeter, String] = Ok2(value = En(n = 1))\n  useRes(r)\n}\n"
  assertEqualInt(diagCount(parseCheck(binding)), 0, "annotated val adopts Res[Greeter, String]")
  val arg = expectedBranchPrelude() + "func f(): Int {\n  useRes(Ok2(value = Fr(n = 2)))\n}\n"
  assertEqualInt(diagCount(parseCheck(arg)), 0, "call argument adopts Res[Greeter, String]")
}

test "expected type: a branch that does not fit is still rejected (#7752)" {
  val tail = expectedBranchPrelude() +
    "func f(c: in Bool): Res[Greeter, String] {\n  if c { Ok2(value = En(n = 1)) } else { Ok2(value = Other(n = 2)) }\n}\n"
  val tailCr = parseCheck(tail)
  assertTrue(hasDiagCode(tailCr, "T0067"), "Other does not implement Greeter: T0067")
  assertEqualInt(countDiagCode(tailCr, "T0067"), 1, "exactly one T0067")
  assertTrue(not hasDiagCode(tailCr, "T0070"), "no redundant T0070")
  val plain = expectedBranchPrelude() + "func f(c: in Bool): Greeter {\n  if c { En(n = 1) } else { Other(n = 2) }\n}\n"
  assertTrue(hasDiagCode(parseCheck(plain), "T0067"), "plain interface: Other branch rejected")
  val binding = expectedBranchPrelude() +
    "func f(c: in Bool): Int {\n  val g: Greeter = match c {\n    case true -> En(n = 1)\n    case false -> Other(n = 2)\n  }\n  g.greet()\n}\n"
  assertTrue(hasDiagCode(parseCheck(binding), "T0067"), "annotated val: Other arm rejected")
  val arg = expectedBranchPrelude() + "func f(c: in Bool): Int {\n  useG(if c { En(n = 1) } else { Other(n = 2) })\n}\n"
  assertTrue(hasDiagCode(parseCheck(arg), "T0067"), "call argument: Other branch rejected")
  // All branches agreeing on a type the position does not accept falls back
  // to the consumer's own diagnostic, exactly as before.
  val same = expectedBranchPrelude() +
    "func f(c: in Bool): Greeter {\n  if c { Other(n = 1) } else { Other(n = 2) }\n}\n"
  assertTrue(hasDiagCode(parseCheck(same), "T0070"), "both branches Other: T0070 against Greeter")
}

test "expected type: no closed expectation keeps the bottom-up join (#7752)" {
  // A generic `T` is a wildcard to `typeEquiv`; checking branches against it
  // would accept anything, so the ordinary join (and its T0067) applies.
  val gen = expectedBranchPrelude() + "func f[T](c: in Bool, t: in T): T {\n  if c { 1 } else { \"s\" }\n}\n"
  assertTrue(hasDiagCode(parseCheck(gen), "T0067"), "generic T expectation: Int vs String still T0067")
  val unann = expectedBranchPrelude() +
    "func f(c: in Bool): Int {\n  val g = if c { En(n = 1) } else { Fr(n = 2) }\n  0\n}\n"
  assertTrue(hasDiagCode(parseCheck(unann), "T0067"), "unannotated val: no expectation, En vs Fr T0067")
}

test "expected type: adoption never widens a value or a nested generic argument (#7752)" {
  // A `Res[En, String]` VALUE is a different runtime instantiation from
  // `Res[Greeter, String]` (CLR generics are invariant) — only a
  // construction is typed at the expected instantiation.
  val value = expectedBranchPrelude() +
    "func f(a: in Res[En, String]): Int {\n  val r: Res[Greeter, String] = a\n  useRes(r)\n}\n"
  assertTrue(hasDiagCode(parseCheck(value), "T0060"), "value of Res[En, String] still not a Res[Greeter, String]")
  // A generic type argument (`Box[Greeter]`) is built from the argument's own
  // instantiation by codegen, so it is not adopted either.
  val nested = expectedBranchPrelude() +
    "func f(): Int {\n  val r: Res[Box[Greeter], String] = Ok2(value = Box(v = En(n = 1)))\n  0\n}\n"
  assertTrue(hasDiagCode(parseCheck(nested), "T0060"), "Ok2(Box[En]) is not a Res[Box[Greeter], String]")
}

test "union case with an unknown named field is rejected (#7752)" {
  val src = expectedBranchPrelude() + "func f(): Res[Int, String] {\n  Err2(error = \"x\")\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0101"), "Err2 has no field 'error' (its field is 'err'): T0101")
  assertTrue(diagMessagesContain(cr, "'Err2' has no field 'error'"), "T0101 names the case and the field")
  val ok = expectedBranchPrelude() + "func f(): Res[Int, String] {\n  Err2(err = \"x\")\n}\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "correctly named case field")
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

// ─────────────────────────────────────────────────────────────────────────────
// #3362: `unifyBranchTypes`'s Unit absorption was position-blind — it
// collapsed an if/match to `Unit` whenever either branch was Unit-typed,
// regardless of whether the if/match's own value was actually consumed
// (value position) or discarded (statement position — the case the test
// directly above, and #3262/#3361's `try` analog further below, cover).  In
// value position a lone Unit branch beside a real value is now a genuine
// T0067 mismatch instead of a silent `Unit` collapse; statement position
// keeps the original lenient absorption unchanged.
// ─────────────────────────────────────────────────────────────────────────────
// Unannotated `val` has no declared type to check the initialiser against, so
// pre-#3362 this silently bound `x : Unit` with zero diagnostics.
test "if value position mixed unit rejected: unannotated val (#3362)" {
  val bad = "package P\nfunc f(c: in Bool): Unit {\n  val x = if c { 1 } else { () }\n}\n"
  assertTrue(
    hasDiagCode(parseCheck(bad), "T0067"),
    "if value-position: unannotated val with Int/Unit if branches now rejected"
  )
}

test "match value position mixed unit rejected: unannotated val (#3362)" {
  val bad = "package P\nfunc f(c: in Bool): Unit {\n  val x = match c { case true -> 1; case false -> () }\n}\n"
  assertTrue(
    hasDiagCode(parseCheck(bad), "T0067"),
    "match value-position: unannotated val with Int/Unit match arms now rejected"
  )
}

// The annotated-`val` form (the issue's own literal example) was already
// accidentally caught before #3362 — not via `unifyBranchTypes`, but via the
// separate strict `argSatisfiesParam` check (T0060) that ran after the
// (wrongly Unit-typed) if-expression was bound, since `Unit` doesn't satisfy
// a declared `Int`.  Post-#3362 the diagnostic source changes: the if itself
// now raises T0067 directly (value position), yielding `TyError` — which
// `argSatisfiesParam`'s `typeEquiv` treats as satisfying any declared type,
// so the old T0060 no longer additionally fires.  Pinned here (asserting the
// new T0067, and that T0060 does NOT double up) so a future refactor cannot
// silently regress this back to leniency, and to confirm #3362's fix does
// not merely re-derive an already-working path under a different code.
test "if value position mixed unit rejected: annotated val (#3362)" {
  val bad = "package P\nfunc f(c: in Bool): Unit {\n  val x: Int = if c { 42 } else { () }\n}\n"
  val cr = parseCheck(bad)
  assertTrue(
    hasDiagCode(cr, "T0067"),
    "if value-position: annotated val with Int/Unit branches rejected by the if itself (T0067)"
  )
  assertTrue(
    not hasDiagCode(cr, "T0060"),
    "if value-position: T0067 alone — TyError satisfies argSatisfiesParam, no redundant T0060"
  )
}

// The sharper #3362 case: a function's trailing-expression return silently
// skipped its own T0070 check whenever the *inferred* body type happened to
// be `Unit` — comparing the body against itself instead of against the
// declared return type.  Fixing `checkFunctionBody`'s guard alone would still
// leave this uncaught without also fixing `unifyBranchTypes`: the if/match
// itself must raise a diagnostic before the (now-unconditional) T0070 check
// ever runs, and a mismatched-branch if/match unifies to the `TyError`
// universal absorber, which `typeAssignable` accepts against any declared
// return type (`typeEquiv` treats `TyError` as equivalent to everything,
// #2099) — so T0067 alone is the diagnostic here, not a redundant T0070.
test "if trailing return mixed unit rejected (#3362)" {
  val bad = "package P\nfunc f(c: in Bool): Int {\n  if c { 42 } else { () }\n}\n"
  val cr = parseCheck(bad)
  assertTrue(hasDiagCode(cr, "T0067"), "if trailing-return: Int/Unit branches now rejected with T0067")
  assertTrue(
    not hasDiagCode(cr, "T0070"),
    "if trailing-return: T0067 alone — TyError absorbs into the declared Int return, no redundant T0070"
  )
}

test "match trailing return mixed unit rejected (#3362)" {
  val bad = "package P\nfunc f(c: in Bool): Int {\n  match c { case true -> 42; case false -> () }\n}\n"
  val cr = parseCheck(bad)
  assertTrue(hasDiagCode(cr, "T0067"), "match trailing-return: Int/Unit arms now rejected with T0067")
  assertTrue(not hasDiagCode(cr, "T0070"), "match trailing-return: T0067 alone, no redundant T0070")
}

// Statement-position regression guards: an if/match whose value is discarded
// must stay exactly as lenient as before #3362, whether both branches are
// Unit or one branch is a discarded non-Unit value.
test "if statement position both unit accepted (#3362)" {
  val ok = "package P\nfunc consume(n: in Int): Unit {}\nfunc f(c: in Bool): Unit {\n  if c { consume(1) } else { consume(2) }\n}\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "if statement-position: both-Unit branches stay clean")
}

test "match statement position both unit accepted (#3362)" {
  val ok = "package P\nfunc consume(n: in Int): Unit {}\nfunc f(c: in Bool): Unit {\n  match c { case true -> consume(1); case false -> consume(2) }\n}\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "match statement-position: both-Unit arms stay clean")
}

test "if statement position unit vs value accepted (#3362)" {
  val ok = "package P\nfunc f(c: in Bool): Unit {\n  if c { 1 } else { () }\n}\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "if statement-position: Int-vs-Unit branches stay clean when discarded")
}

test "match statement position unit vs value accepted (#3362)" {
  val ok = "package P\nfunc f(c: in Bool): Unit {\n  match c { case true -> 1; case false -> () }\n}\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "match statement-position: Int-vs-Unit arms stay clean when discarded")
}

// #6730: an else-less `if` always yields Unit regardless of its then-branch,
// even when the whole else-less `if` sits in value position (e.g. as the
// initializer of a `val`). The then-branch's own value is provably
// discarded either way, so a nested if/else inside it must be typed
// leniently (statement position), not spuriously rejected as if the outer
// `if`'s value position propagated all the way down.
test "else-less if in value position types its then-branch leniently (#6730)" {
  val ok = "package P\nfunc f(c: in Bool, d: in Bool): Unit {\n  val x = if c { if d { 1 } else { () } }\n}\n"
  assertEqualInt(
    diagCount(parseCheck(ok)),
    0,
    "else-less if: nested if/else Int-vs-Unit mismatch stays clean when the outer if has no else"
  )
}

test "else-less if with a genuinely bad nested match statement stays clean too (#6730)" {
  val ok = "package P\nfunc f(c: in Bool, d: in Bool): Unit {\n  val x = if c { match d { case true -> 1; case false -> () } }\n}\n"
  assertEqualInt(
    diagCount(parseCheck(ok)),
    0,
    "else-less if: nested match Int-vs-Unit mismatch stays clean when the outer if has no else"
  )
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
// element returned where `Char` is expected MUST mismatch (T0070) — `Byte`
// does not widen to `Char` — whereas `TyError` would have unified silently.
test "index byte element typed" {
  val src = "package P\nfunc f(a: in slice[Byte]): Char { a[0] }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0070"), "index-byte: slice[Byte] element is Byte, mismatches Char return")
}

// A returned value initialises the result, so it widens along the lossless
// chains like any initialiser (docs/01 §4.1, #7805).
test "return widens along the lossless chains" {
  val ok = "package P\nfunc f(u: in UInt): ULong { return u }\nfunc g(u: in UInt): ULong { u }\nfunc h(b: in Byte): Int = b\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "return-widen: UInt/Byte widen at return and body value")
  val cross = "package P\nfunc f(i: in Int): ULong { return i }\n"
  assertTrue(hasDiagCode(parseCheck(cross), "T0065"), "return-widen: Int does not widen to ULong")
}

test "slice literal elements widen to the expected element type" {
  val ok = "package P\nfunc f(u: in UInt): slice[ULong] { val xs: slice[ULong] = [u, 1u64]\n xs }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "slice-widen: UInt element in a slice[ULong] literal")
  val bad = "package P\nfunc f(i: in Int): slice[ULong] { val xs: slice[ULong] = [i]\n xs }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0041"), "slice-widen: Int element rejected in a slice[ULong] literal")
}

test "toULong applies only to the unsigned chain" {
  val ok = "package P\nfunc f(u: in UInt, b: in Byte): ULong { u.toULong() + b.toULong() }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "toULong: UInt and Byte receivers")
  val bad = "package P\nfunc f(i: in Int): ULong { i.toULong() }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0103"), "toULong: Int receiver rejected with T0103")
}

test "toUInt applies only to Byte and UInt (#7812)" {
  val ok = "package P\nfunc f(u: in UInt, b: in Byte): UInt { u.toUInt() + b.toUInt() }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "toUInt: UInt and Byte receivers")
  val badI = "package P\nfunc f(i: in Int): UInt { i.toUInt() }\n"
  assertTrue(hasDiagCode(parseCheck(badI), "T0103"), "toUInt: Int receiver rejected with T0103")
  val badL = "package P\nfunc f(l: in ULong): UInt { l.toUInt() }\n"
  assertTrue(hasDiagCode(parseCheck(badL), "T0103"), "toUInt: ULong receiver (a narrowing) rejected with T0103")
}

// #7812: an operand whose checked type is `UInt`/`ULong`, at a position whose
// lowering depends on signedness, is a conversion site (the identity
// `.toUInt()`/`.toULong()`); a suffixed literal already says so, and a signed
// operand or a sign-independent position records nothing.
test "unsigned operands at signedness-sensitive positions are conversion sites (#7812)" {
  val src = "package P\nrecord H {\n  v: ULong\n  u: UInt\n}\nfunc f(h: in H): Bool {\n  println(h.v)\n  println(\"\${h.u}\")\n  h.v > 1u64 and h.u / 2u32 == 1u32\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "unsigned operands type-check")
  assertEqualInt(cr.symbols.argConversionSites.count, 4, "println arg, interpolated segment, > operand and / operand")
  val signed = parseCheck(
    "package P\nrecord H {\n  v: Long\n  u: ULong\n}\nfunc f(h: in H): Bool {\n  println(h.v)\n  h.v > 1 and h.u == 2u64 and h.u + h.u == 4u64\n}\n"
  )
  assertEqualInt(diagCount(signed), 0, "signed and sign-independent operands type-check")
  assertEqualInt(signed.symbols.argConversionSites.count, 0, "no site for a signed operand, ==, or +")
}

// The methods of the conversion sites `cr` recorded, comma-separated.
func conversionMethodsOf(cr: in CheckResult): String {
  val ms: List[String] = newList()
  for k in mapKeys(cr.symbols.argConversionSites) {
    match mapGet(cr.symbols.argConversionSites, k) {
      case Some(site) -> ms.add(site.method)
      case None -> ()
    }
  }
  Str.joinList(",", ms)
}

// #7841: an unsuffixed literal assigned or compound-assigned to a `Byte`,
// `UInt` or `ULong` takes the target's type, as at a binding, and is given
// its suffix; one that does not fit is T0015, not a type mismatch.
test "an unsuffixed literal takes the type of an assignment target (#7841)" {
  for ty in ["Byte", "UInt", "ULong", "Int", "Long"] {
    for op in ["=", "+=", "-=", "*=", "/=", "%="] {
      val src = "package P\nfunc f(x0: in " + ty + "): " + ty + " {\n  var x = x0\n  x " + op + " 7\n  x\n}\n"
      val cr = parseCheck(src)
      assertEqualInt(diagCount(cr), 0, ty + " x " + op + " 7: " + diagCodesOf(cr))
    }
  }
  val u = parseCheck("package P\nfunc f(): UInt {\n  var x: UInt = 10u32\n  x %= 7\n  x\n}\n")
  assertEqualInt(diagCount(u), 0, "UInt %= 7: " + diagCodesOf(u))
  assertEqualInt(u.symbols.argConversionSites.count, 1, "the literal takes the u32 suffix")
  assertEqual(conversionMethodsOf(u), intLiteralSiteMethod(U32), "u32 literal site")
  val b = parseCheck("package P\nfunc f(): Byte {\n  var x: Byte = 1u8\n  x += 200\n  x = 255\n  x\n}\n")
  assertEqualInt(diagCount(b), 0, "Byte += 200 and = 255: " + diagCodesOf(b))
  assertEqual(conversionMethodsOf(b), intLiteralSiteMethod(U8) + "," + intLiteralSiteMethod(U8), "u8 literal sites")
  val ul = parseCheck("package P\nfunc f(): ULong {\n  var x: ULong = 1u64\n  x *= 3000000000\n  x\n}\n")
  assertEqualInt(diagCount(ul), 0, "ULong *= 3000000000: " + diagCodesOf(ul))
  assertEqual(conversionMethodsOf(ul), intLiteralSiteMethod(U64), "u64 literal site")
  val neg = parseCheck("package P\nfunc f(): UInt {\n  var x: UInt = 1u32\n  x += -1\n  x\n}\n")
  assertEqualInt(countDiagCode(neg, "T0015"), 1, "UInt += -1: " + diagCodesOf(neg))
  assertEqualInt(countDiagCode(neg, "T0063"), 0, "an out-of-range literal is not also a type mismatch")
  assertTrue(diagMessagesContain(neg, "literal -1 is out of range for type UInt"), "message")
  val big = parseCheck("package P\nfunc f(): Byte {\n  var x: Byte = 1u8\n  x = 256\n  x\n}\n")
  assertEqualInt(countDiagCode(big, "T0015"), 1, "Byte = 256: " + diagCodesOf(big))
  val binds = parseCheck(
    "package P\nfunc f(): ULong {\n  val a: UInt = 7\n  val b: Byte = 255\n  val c: ULong = 9\n  c + a.toULong() + b.toULong()\n}\n"
  )
  assertEqualInt(diagCount(binds), 0, "annotated bindings: " + diagCodesOf(binds))
  val badBind = parseCheck("package P\nfunc f(): UInt {\n  val a: UInt = -7\n  a\n}\n")
  assertEqualInt(countDiagCode(badBind, "T0015"), 1, "val a: UInt = -7: " + diagCodesOf(badBind))
  val arg = parseCheck("package P\nfunc g(u: in UInt): UInt { u }\nfunc f(): UInt { g(7) }\n")
  assertEqualInt(diagCount(arg), 0, "an argument: " + diagCodesOf(arg))
}

// #7842: a literal or range pattern against a `UInt`/`ULong`/`Byte`
// scrutinee is typed against it: an unsuffixed literal or bound takes its
// suffix, a bound of another shape is an unsigned operand, and a literal the
// type cannot hold is T0015.
test "literal and range patterns take an unsigned scrutinee's type (#7842)" {
  val lit = parseCheck(
    "package P\nfunc f(x: in UInt): Int {\n  match x {\n    case 4000000000 -> 1\n    case 3000000000 ..= 3999999999 -> 2\n    case _ -> 3\n  }\n}\n"
  )
  assertEqualInt(diagCount(lit), 0, "UInt patterns: " + diagCodesOf(lit))
  assertEqualInt(lit.symbols.argConversionSites.count, 3, "the literal and both bounds take the u32 suffix")
  assertEqual(
    conversionMethodsOf(lit),
    intLiteralSiteMethod(U32) + "," + intLiteralSiteMethod(U32) + "," + intLiteralSiteMethod(U32),
    "u32 sites"
  )
  val nested = parseCheck(
    "package P\nunion Opt {\n  case Has(n: ULong)\n  case Empty\n}\nfunc f(x: in Opt): Int {\n  match x {\n    case Has(0 ..= 9) -> 1\n    case Has(10) -> 2\n    case _ -> 3\n  }\n}\n"
  )
  assertEqualInt(diagCount(nested), 0, "nested ULong patterns: " + diagCodesOf(nested))
  assertEqualInt(nested.symbols.argConversionSites.count, 3, "nested literal and bounds take the u64 suffix")
  val constBound = parseCheck(
    "package P\nval Hi: UInt = 4000000000u32\nfunc f(x: in UInt): Int {\n  match x {\n    case 1u32 ..= Hi -> 1\n    case _ -> 2\n  }\n}\n"
  )
  assertEqualInt(diagCount(constBound), 0, "a named bound: " + diagCodesOf(constBound))
  assertEqual(conversionMethodsOf(constBound), "toUInt", "a UInt bound of another shape is an unsigned operand")
  val neg = parseCheck(
    "package P\nfunc f(x: in UInt): Int {\n  match x {\n    case -1 -> 1\n    case -5 ..= 3 -> 2\n    case _ -> 3\n  }\n}\n"
  )
  assertEqualInt(countDiagCode(neg, "T0015"), 2, "a negative literal and bound: " + diagCodesOf(neg))
  val byte = parseCheck(
    "package P\nfunc f(x: in Byte): Int {\n  match x {\n    case 200 ..= 255 -> 1\n    case 256 -> 2\n    case _ -> 3\n  }\n}\n"
  )
  assertEqualInt(countDiagCode(byte, "T0015"), 1, "a Byte pattern of 256: " + diagCodesOf(byte))
  val signed = parseCheck(
    "package P\nfunc f(x: in Int): Int {\n  match x {\n    case -1 -> 1\n    case 0 ..= 9 -> 2\n    case _ -> 3\n  }\n}\n"
  )
  assertEqualInt(diagCount(signed), 0, "signed patterns: " + diagCodesOf(signed))
  assertEqualInt(signed.symbols.argConversionSites.count, 0, "no site for a signed scrutinee")
}

// A scalar given to a generic constructor or a tuple element widens to the
// slot the expected type fixes (docs/01 §4.1, #7813); an existing container
// value does not: `Opt[UInt]` and `Opt[ULong]` stay distinct types.
test "generic constructor arguments and tuple elements widen" {
  val ok = "package P\nunion Opt[T] { case Has(value: T); case Gone }\n" + "func f(u: in UInt, i: in Int): Unit {\n" +
    "  val a: Opt[ULong] = Has(u)\n  val b: (ULong, Int) = (u, 1)\n  val c: Opt[(Long, Int)] = Has((i, 1))\n}\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "ctor-widen: Has(u), (u, 1) and Has((i, 1)) widen")
  val cross = "package P\nunion Opt[T] { case Has(value: T); case Gone }\n" +
    "func f(i: in Int): Unit { val a: Opt[ULong] = Has(i) }\n"
  assertTrue(hasDiagCode(parseCheck(cross), "T0060"), "ctor-widen: Int does not widen to ULong")
}

test "an existing container value does not widen" {
  val src = "package P\nunion Opt[T] { case Has(value: T); case Gone }\n" +
    "func f(o: in Opt[UInt], t: in (UInt, Int)): Unit {\n" +
    "  val p: Opt[ULong] = o\n  val q: (ULong, Int) = t\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 2, "container-widen: both bindings rejected")
  assertTrue(hasDiagCode(cr, "T0060"), "container-widen: T0060")
  assertTrue(
    diagMessagesContain(cr, "not the contents of an existing Opt[UInt] value"),
    "container-widen: the hint names the existing value"
  )
  assertTrue(
    diagMessagesContain(cr, "converted explicitly with .toULong()"),
    "container-widen: the hint names the conversion"
  )
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

// #6836: `checkClosed`/`checkClosedFloat`'s `sym` parameter used to do
// double duty as both the diagnostic's display string and the empty-
// bounds predicate selector (`if sym == "..=" {...} else if sym ==
// "..<" {...} else { false }`). Once the formatter's `bareDotDot` field
// (#2280) let a range subtype's `..</..` spelling reach this check as
// `sym == ".."`, that matched neither branch and silently skipped the
// check for the bare-`..` spelling specifically — only `..=` and `..<`
// were covered by the test above, so the gap went unnoticed. Both
// half-open spellings (and a float-backed range) must report T0090
// identically, since the grammar defines them as synonyms.
test "range subtype empty bounds for explicit '..<' spelling" {
  val src = "package P\ntype Bad = Int range 5 ..< 5\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0090"), "range-empty (..<): T0090 emitted")
}

test "range subtype empty bounds for bare '..' spelling (#6836)" {
  val src = "package P\ntype Bad = Int range 5 .. 5\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0090"), "range-empty (bare ..): T0090 emitted")
}

test "range subtype empty bounds for a float-backed bare '..' spelling (#6836)" {
  val src = "package P\ntype Bad = Float range 1.0 .. 1.0\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0090"), "range-empty (float, bare ..): T0090 emitted")
}

// #6661 residual (D-progress-840): `Short`/`UShort`/`UByte` are not real
// Lyric surface types (no `PrimType` case, absent from docs/01 §2.1's
// primitive table) — `isNumericPrimitiveName` used to wrongly admit them,
// so a range subtype declared over one type-checked cleanly and then
// crashed the JVM backend (`Jvm.Lowering.jvmVerifierTypeOfUnderlying`'s
// defense-in-depth panic) instead of failing at compile time. These three
// must now be rejected with T0091, exactly like any other non-numeric
// underlying type.
test "range subtype over UShort rejected (#6661)" {
  val src = "package P\ntype Small = UShort range 0 ..= 100\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0091"), "range-ushort: T0091 emitted, not silently accepted")
}

test "range subtype over UByte rejected (#6661)" {
  val src = "package P\ntype Small = UByte range 0 ..= 100\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0091"), "range-ubyte: T0091 emitted, not silently accepted")
}

test "range subtype over Short rejected (#6661)" {
  val src = "package P\ntype Small = Short range 0 ..= 100\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0091"), "range-short: T0091 emitted, not silently accepted")
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
  packages.add(
    ImportedPackage(
      name = "PkgA",
      items = pkgA.file.items,
      imports = collectImportNames(pkgA.file.imports),
      wholeImports = collectWholeImportNames(pkgA.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "PkgB",
      items = pkgB.file.items,
      imports = collectImportNames(pkgB.file.imports),
      wholeImports = collectWholeImportNames(pkgB.file.imports)
    )
  )
  // Only `wantB` is imported from PkgB, so the bare `Greeter` means PkgA's.
  val src = "package App\nimport PkgA\nimport PkgB.{wantB}\nrecord Hello { x: Int }\nimpl Greeter for Hello {\n  func greet(): String { \"hi\" }\n}\nfunc f(): Unit {\n  val s = wantB(Hello(x = 1))\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, packages)
  assertTrue(
    hasDiagCode(cr, "T0043"),
    "interface-subtyping cross-package: impl of PkgA.Greeter does not satisfy a PkgB.Greeter parameter"
  )
}

// A qualified call reaches a generic function of the named package.  The
// arity-keyed overload slots hold non-generic signatures only, so
// `Ui.Testing.findAll(...)` used to bind to another package's non-generic
// `findAll` of the same arity (found by the browser test for #7836).
test "qualified call binds to the named package's generic function" {
  val xml = parse(
    "package Xml\npub record Node { n: Int }\npub func findAll(node: in Node, name: in String): Node { node }\n"
  )
  val ui = parse(
    "package Ui.Testing\npub record Box[T] { v: T }\npub func findAll[M](v: in Box[M], k: in Int): Box[M] { v }\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Xml",
      items = xml.file.items,
      imports = collectImportNames(xml.file.imports),
      wholeImports = collectWholeImportNames(xml.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "Ui.Testing",
      items = ui.file.items,
      imports = collectImportNames(ui.file.imports),
      wholeImports = collectWholeImportNames(ui.file.imports)
    )
  )
  val srcs: List[String] = newList()
  srcs.add(
    "package App\nimport Xml\nimport Ui.Testing as UiTest\nimport Ui.Testing.{Box}\nfunc f(b: in Box[Int]): Int {\n  val x: Box[Int] = UiTest.findAll(b, 1)\n  x.v\n}\n"
  )
  srcs.add(
    "package App\nimport Xml\nimport Ui.Testing\nfunc f(b: in Box[Int]): Int {\n  val x: Box[Int] = Ui.Testing.findAll(b, 1)\n  x.v\n}\n"
  )
  for src in srcs {
    val cr = checkWithImportedPackages(pipePrepareForCheck(parse(src).file, false).file, packages)
    assertEqualInt(diagCount(cr), 0, "the generic Ui.Testing.findAll, not Xml.findAll")
  }
  val bad = "package App\nimport Xml\nimport Ui.Testing as UiTest\nimport Ui.Testing.{Box}\nfunc f(b: in Box[Int]): Int {\n  val x: Box[Int] = UiTest.findAll(b, \"one\")\n  x.v\n}\n"
  val badCr = checkWithImportedPackages(pipePrepareForCheck(parse(bad).file, false).file, packages)
  assertTrue(hasDiagCode(badCr, "T0043"), "a wrong argument is reported against Ui.Testing.findAll")
  assertTrue(
    diagMessageFor(badCr, "T0043").contains("parameter type Int"),
    "checked against the Int parameter, not Xml's"
  )
}

// #7512: the same mismatch written as a package-qualified call is reported
// too, against the named package's signature.  The checker sees the file
// after the build's pre-check rewrites (`pipePrepareForCheck`), where the
// alias rewriter has turned `PkgB.wantB` into a qualified call.
test "qualified call: impl of another package's same-named interface is T0043" {
  val pkgA = parse("package PkgA\npub interface Greeter {\n  func greet(): String\n}\n")
  val pkgB = parse(
    "package PkgB\npub interface Greeter {\n  func greet(): String\n}\npub func wantB(g: in Greeter): String { \"\" }\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgA",
      items = pkgA.file.items,
      imports = collectImportNames(pkgA.file.imports),
      wholeImports = collectWholeImportNames(pkgA.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "PkgB",
      items = pkgB.file.items,
      imports = collectImportNames(pkgB.file.imports),
      wholeImports = collectWholeImportNames(pkgB.file.imports)
    )
  )
  val bad = "package App\nimport PkgA\nimport PkgB\nrecord Hello { x: Int }\nimpl PkgA.Greeter for Hello {\n  func greet(): String { \"hi\" }\n}\nfunc f(): Unit {\n  val s = PkgB.wantB(Hello(x = 1))\n}\n"
  assertTrue(
    hasDiagCode(checkWithImportedPackages(pipePrepareForCheck(parse(bad).file, false).file, packages), "T0043"),
    "qualified call: impl of PkgA.Greeter does not satisfy a PkgB.Greeter parameter"
  )
  val ok = "package App\nimport PkgA\nimport PkgB\nrecord Hello { x: Int }\nimpl PkgB.Greeter for Hello {\n  func greet(): String { \"hi\" }\n}\nfunc f(): Unit {\n  val s = PkgB.wantB(Hello(x = 1))\n}\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(pipePrepareForCheck(parse(ok).file, false).file, packages), "T0043"),
    0,
    "qualified call: impl of PkgB.Greeter satisfies the PkgB.Greeter parameter"
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
  packages.add(
    ImportedPackage(
      name = "PkgA",
      items = pkgA.file.items,
      imports = collectImportNames(pkgA.file.imports),
      wholeImports = collectWholeImportNames(pkgA.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "PkgB",
      items = pkgB.file.items,
      imports = collectImportNames(pkgB.file.imports),
      wholeImports = collectWholeImportNames(pkgB.file.imports)
    )
  )
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
  packages.add(
    ImportedPackage(
      name = "PkgA",
      items = pkgA.file.items,
      imports = collectImportNames(pkgA.file.imports),
      wholeImports = collectWholeImportNames(pkgA.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "PkgB",
      items = pkgB.file.items,
      imports = collectImportNames(pkgB.file.imports),
      wholeImports = collectWholeImportNames(pkgB.file.imports)
    )
  )
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
  packages.add(
    ImportedPackage(
      name = "PkgR",
      items = pkgR.file.items,
      imports = collectImportNames(pkgR.file.imports),
      wholeImports = collectWholeImportNames(pkgR.file.imports)
    )
  )
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

// #7839: a `ULong` bound or literal above Long.MaxValue is carried as a
// negative 64-bit pattern, so range checks on a `ULong` base order unsigned.
test "ulong range subtype bounds above Long max are ordered unsigned" {
  val ok = parseCheck("package P\ntype Big = ULong range 9223372036854775808u64 ..= 18446744073709551615u64\n")
  assertTrue(not hasDiagCode(ok, "T0090"), "ULong range above Long.Max: no T0090")
  val low = parseCheck("package P\ntype Wide = ULong range 0u64 ..= 18446744073709551615u64\n")
  assertTrue(not hasDiagCode(low, "T0090"), "ULong full range: no T0090")
  val bad = parseCheck("package P\ntype Bad = ULong range 18446744073709551615u64 ..= 9223372036854775808u64\n")
  assertTrue(hasDiagCode(bad, "T0090"), "ULong reversed range: T0090")
  assertTrue(
    diagMessagesContain(bad, "18446744073709551615 ..= 9223372036854775808"),
    "ULong reversed range: bounds shown unsigned"
  )
  val halfOpen = parseCheck("package P\ntype H = ULong range 18446744073709551615u64 ..< 18446744073709551615u64\n")
  assertTrue(hasDiagCode(halfOpen, "T0090"), "ULong empty half-open range: T0090")
}

test "ulong inline refined literal above Long max is ordered unsigned" {
  val inRange = parseCheck(
    "package P\nfunc f(): Unit {\n  val x: ULong range 0u64 ..= 18446744073709551615u64 = 18446744073709551614u64\n}\n"
  )
  assertTrue(not hasDiagCode(inRange, "T0015"), "ULong inline range: 2^64-2 in bounds")
  val above = parseCheck(
    "package P\nfunc f(): Unit {\n  val x: ULong range 0u64 ..= 10u64 = 18446744073709551615u64\n}\n"
  )
  assertTrue(hasDiagCode(above, "T0015"), "ULong inline range: 2^64-1 above 10")
  assertTrue(diagMessagesContain(above, "literal 18446744073709551615 "), "ULong inline range: literal shown unsigned")
  val below = parseCheck(
    "package P\nfunc f(): Unit {\n  val x: ULong range 9223372036854775808u64 ..= 18446744073709551615u64 = 5u64\n}\n"
  )
  assertTrue(hasDiagCode(below, "T0015"), "ULong inline range: 5 below 2^63")
  val plain = parseCheck("package P\nfunc f(): Unit {\n  val x: ULong = 18446744073709551615u64\n}\n")
  assertEqualInt(diagCount(plain), 0, "ULong max literal: clean")
}

// #7847: a signed suffix's minimum is written as a unary minus on the
// magnitude one past its maximum; the pair has the suffix's type.  `i8` is
// an `Int` literal: `Byte` is unsigned and cannot hold -128.
test "signed suffix minimums type as their suffix's type" {
  val src = "package P\nfunc f(): Unit {\n  val a: Int = -128i8\n  val b: Int = -32768i16\n  val c: Int = -2147483648i32\n  val d: Long = -9223372036854775808i64\n  val e: Int = -0x8000_0000i32\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "signed minimums: clean")
}

test "i8 literals are Int not Byte" {
  val asInt = parseCheck("package P\nfunc f(): Int {\n  127i8\n}\n")
  assertEqualInt(diagCount(asInt), 0, "127i8 returned as Int: clean")
  val asByte = parseCheck("package P\nfunc f(): Unit {\n  val b: Byte = 1i8\n}\n")
  assertTrue(diagCount(asByte) > 0, "1i8 bound to Byte: rejected (no implicit narrowing)")
  val u8Byte = parseCheck("package P\nfunc f(): Unit {\n  val b: Byte = 255u8\n}\n")
  assertEqualInt(diagCount(u8Byte), 0, "255u8 bound to Byte: clean")
}

// #7346: an unsuffixed literal outside Int's range is not an Int.
test "int literal out of range for Int is T0015" {
  val cr = parseCheck("package P\nfunc f(): Unit {\n  val x: Int = 2147483648\n}\n")
  assertTrue(hasDiagCode(cr, "T0015"), "2147483648 into Int: T0015")
  assertTrue(not hasDiagCode(cr, "T0060"), "2147483648 into Int: no duplicate T0060")
  val cr2 = parseCheck("package P\nfunc f(): Unit {\n  var y: Int = -2147483649\n}\n")
  assertTrue(hasDiagCode(cr2, "T0015"), "-2147483649 into Int: T0015")
}

test "int literal boundaries and Long defaults" {
  val src = "package P\nfunc f(): Unit {\n  val a: Int = 2147483647\n  val b: Int = -2147483648\n" +
    "  val c: Long = 3000000000\n  val d = 3000000000\n  val e: Long = d\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "Int bounds and Long-valued literals are clean")
}

test "an out-of-range literal argument is a type error" {
  val cr = parseCheck("package P\nfunc g(x: in Int): Int = x\nfunc f(): Int = g(2147483648)\n")
  assertTrue(diagCount(cr) > 0, "a Long-valued literal is not an Int argument")
}

// #7361: a compound assignment to a distinct type is rewritten to
// `x = T.from(x.value op y.value)`, so its target must be free of side
// effects.
test "compound assignment to a distinct type needs a path target (T0134)" {
  val ok = parseCheck(
    "package P\ntype C = Long range 0 ..= 9 derives Add\nfunc f(a: in C, b: in C): C {\n  var x = a\n  x += b\n  x\n}\n"
  )
  assertTrue(not hasDiagCode(ok, "T0134"), "a variable target is accepted")
  val bad = parseCheck(
    "package P\ntype C = Long derives Add\nfunc f(xs: inout slice[C], b: in C): Unit {\n  xs[0] += b\n}\n"
  )
  assertTrue(hasDiagCode(bad, "T0134"), "an indexed target is T0134")
}

// #7425: `x op= y` needs the derive `x op y` needs.
test "compound assignment to a distinct type needs its derive (T0030)" {
  val bad = parseCheck(
    "package P\ntype UserId = Long derives Compare, Hash\nfunc f(a: in UserId, b: in UserId): UserId {\n  var x = a\n  x += b\n  x\n}\n"
  )
  assertTrue(hasDiagCode(bad, "T0030"), "+= without derives Add is T0030")
  val sub = parseCheck(
    "package P\ntype C = Long derives Add\nfunc f(a: in C, b: in C): C {\n  var x = a\n  x -= b\n  x\n}\n"
  )
  assertTrue(hasDiagCode(sub, "T0030"), "-= needs derives Sub, not Add")
  val ok = parseCheck(
    "package P\ntype C = Long derives Add, Mul\nfunc f(a: in C, b: in C): C {\n  var x = a\n  x += b\n  x *= b\n  x\n}\n"
  )
  assertTrue(not hasDiagCode(ok, "T0030"), "derived operators are accepted")
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
  imports.add(
    ImportedPackage(
      name = "Pa",
      items = pkgA.file.items,
      imports = collectImportNames(pkgA.file.imports),
      wholeImports = collectWholeImportNames(pkgA.file.imports)
    )
  )
  imports.add(
    ImportedPackage(
      name = "Pb",
      items = pkgB.file.items,
      imports = collectImportNames(pkgB.file.imports),
      wholeImports = collectWholeImportNames(pkgB.file.imports)
    )
  )
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
  imports.add(
    ImportedPackage(
      name = "Pa",
      items = pkgA.file.items,
      imports = collectImportNames(pkgA.file.imports),
      wholeImports = collectWholeImportNames(pkgA.file.imports)
    )
  )
  imports.add(
    ImportedPackage(
      name = "Pb",
      items = pkgB.file.items,
      imports = collectImportNames(pkgB.file.imports),
      wholeImports = collectWholeImportNames(pkgB.file.imports)
    )
  )
  imports.add(
    ImportedPackage(
      name = "Pc",
      items = pkgC.file.items,
      imports = collectImportNames(pkgC.file.imports),
      wholeImports = collectWholeImportNames(pkgC.file.imports)
    )
  )
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
    ImportedPackage(
      name = "Acme",
      items = pkgAcme.file.items,
      imports = collectImportNames(pkgAcme.file.imports),
      wholeImports = collectWholeImportNames(pkgAcme.file.imports)
    )
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
// #7737: indexing types the element only for the stdlib `List` (by
// identity), so the stdlib package is in scope here rather than a local
// same-named extern.
test "index list element typed" {
  val src = "package P\nimport Std.CollectionsHost\nfunc f(xs: in List[Long]): Int { xs[0] }\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
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
  val src = "package P\ngeneric[T] func head(xs: in slice[T]): T { xs[0] }\nfunc f(bs: in slice[Byte]): Char { head(bs) }\n"
  assertTrue(
    hasDiagCode(parseCheck(src), "T0070"),
    "generic slice param: head(slice[Byte]) returns Byte, mismatches Char"
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
  packages.add(
    ImportedPackage(
      name = "PkgA",
      items = pkgA.file.items,
      imports = collectImportNames(pkgA.file.imports),
      wholeImports = collectWholeImportNames(pkgA.file.imports)
    )
  )
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

// Component-wise derives on records (D155): only Add and Sub, only on a
// non-generic record whose fields share one numeric primitive type and which
// has no invariant (T0152).
test "a homogeneous numeric record may derive Add and Sub" {
  val src = "package P\n@derive(Add, Sub)\nrecord V { x: Float\n y: Float }\nfunc f(a: in V, b: in V): V { a + b - b }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "Vec2-shaped record")
}

test "record arithmetic derives outside the homogeneous numeric shape are T0152" {
  val mixed = "package P\n@derive(Add)\nrecord V { x: Float\n y: Double }\n"
  assertTrue(hasDiagCode(parseCheck(mixed), "T0152"), "mixed field types")
  val nonNumeric = "package P\n@derive(Sub)\nrecord V { x: Int\n name: String }\n"
  assertTrue(hasDiagCode(parseCheck(nonNumeric), "T0152"), "a String field")
  val mul = "package P\n@derive(Mul)\nrecord V { x: Int }\n"
  assertTrue(hasDiagCode(parseCheck(mul), "T0152"), "Mul")
  val generic1 = "package P\n@derive(Add)\nrecord V[T] { x: T }\n"
  assertTrue(hasDiagCode(parseCheck(generic1), "T0152"), "generic record")
  val inv = "package P\n@derive(Add)\nrecord V { x: Int\n invariant: x >= 0 }\n"
  assertTrue(hasDiagCode(parseCheck(inv), "T0152"), "a record with an invariant")
  val empty = "package P\n@derive(Add)\nrecord V { }\n"
  assertTrue(hasDiagCode(parseCheck(empty), "T0152"), "no fields")
}

test "compound arithmetic on a record needs a variable or field target" {
  val src = "package P\n@derive(Add)\nrecord V { x: Int }\nrecord W { var v: V }\nfunc g(): W { W(v = V(x = 0)) }\nfunc f(v: in V) { g().v += v }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0134"), "a field of a call result")
}

test "compound arithmetic on a record without the derive is T0030" {
  val plain = "package P\nrecord V { x: Int }\nfunc f(a: in V, b: in V) {\n var r = a\n r += b\n}\n"
  assertTrue(hasDiagCode(parseCheck(plain), "T0030"), "+= without derives Add")
  val sub = "package P\n@derive(Add)\nrecord V { x: Int }\nfunc f(a: in V, b: in V) {\n var r = a\n r -= b\n}\n"
  assertTrue(hasDiagCode(parseCheck(sub), "T0030"), "-= with only derives Add")
  val ok = "package P\n@derive(Add)\nrecord V { x: Int }\nfunc f(a: in V, b: in V) {\n var r = a\n r += b\n}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0030"), "+= with derives Add")
}

test "== on a record with a function field is T0153" {
  val bad = "package P\nrecord H { f: (Int) -> Int }\nfunc g(a: in H, b: in H): Bool { a == b }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0153"), "a function field")
  val nested = "package P\nrecord Box[T] { value: T }\nrecord H { f: (Int) -> Int }\nfunc g(a: in Box[Box[H]], b: in Box[Box[H]]): Bool { a == b }\n"
  assertTrue(hasDiagCode(parseCheck(nested), "T0153"), "a function field under a generic record nested in itself")
  val mutable = "package P\nrecord H { var f: (Int) -> Int }\nfunc g(a: in H, b: in H): Bool { a == b }\n"
  assertTrue(not hasDiagCode(parseCheck(mutable), "T0153"), "a mutable record keeps identity")
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
  // #7696: the literal-typed-as-List rule now keys on `List`'s TypeId
  // (`isStdCollectionsHostType`), not its bare name — so this needs the
  // GENUINE `Std.CollectionsHost.List` in scope (`stdCollectionsHostPackages`)
  // rather than a locally-declared same-named record. See the "user record
  // named List" test below for what changed.
  val src = "package P\nimport Std.CollectionsHost\nrecord R { items: List[Int] }\nfunc f(): R { R(items = [1, 2, 3]) }\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(diagCount(cr), 0, "a list literal types directly as List[Int] in a ctor field")
}

// #7696: a package's own unrelated `record List[T]` (never importing the
// real `Std.CollectionsHost.List`) must NOT get list-literal typing — before
// the id-based fix above, this test's bracket literal type-checked
// vacuously AND codegen would have built a genuine BCL `List<T>`/`ArrayList`
// at the construction site regardless, ignoring the user's own record
// entirely (the same checker/codegen split #7665 fixed for `.toList()`).
test "a user record named List does not accept a bracket literal as if it were Std List (#7696)" {
  val src = "package P\nrecord List[T] { }\nrecord R { items: List[Int] }\nfunc f(): R { R(items = [1, 2, 3]) }\n"
  val cr = parseCheck(src)
  assertTrue(
    hasDiagCode(cr, "T0104"),
    "a bracket literal does not construct an arbitrary same-named user record via ctor-field typing"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// #7545: `slice[T]` and `List[T]` have distinct runtime representations on
// every backend and are no longer mutually assignable — only the explicit
// `.toList()`/`.toArray()` conversion (docs/01 §2.7) bridges them. A bracket
// LITERAL used directly where a `List[T]` is expected is the one exception
// (it is typed as `List[T]` up front, never as `slice[T]`), since both
// backends' own literal codegen already builds whichever representation the
// context calls for.
// ─────────────────────────────────────────────────────────────────────────────
test "slice VALUE (not a literal) rejected as a List ctor field argument" {
  val src = "package P\nrecord List[T] { }\nrecord R { items: List[Int] }\nfunc f(xs: in slice[Int]): R { R(items = xs) }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0104"), "a slice[Int]-typed parameter does not satisfy a List[Int] ctor field")
}

test "slice VALUE (not a literal) rejected as a List call argument" {
  val src = "package P\nrecord List[T] { }\nfunc g(xs: in List[Int]): Int { 0 }\nfunc f(xs: in slice[Int]): Int { g(xs) }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0043"), "a slice[Int]-typed argument does not satisfy a List[Int] parameter")
}

test "List VALUE rejected as a slice call argument (reverse direction)" {
  val src = "package P\nrecord List[T] { }\nfunc g(xs: in slice[Int]): Int { 0 }\nfunc f(xs: in List[Int]): Int { g(xs) }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0043"), "a List[Int]-typed argument does not satisfy a slice[Int] parameter")
}

test "slice-typed val rejected against a List[T]-annotated binding" {
  val src = "package P\nrecord List[T] { }\nfunc f(xs: in slice[Int]): Unit { val ys: List[Int] = xs }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0060"), "a slice[Int] value does not satisfy a List[Int]-annotated val binding")
}

// #7696: this source raises TWO independent diagnostics — the `var ys:
// List[Int] = xs` initialiser is the VAR-binding check (T0061, not the
// val-binding T0060 this test originally asserted; `ys` is declared `var`),
// and the subsequent `ys = xs` plain assignment is separately rejected by
// the assignment check (T0063). Pinned precisely (both codes, and that
// T0060 — which cannot fire for a `var` binding — never does) rather than an
// "either" disjunction, so a future regression in either check is caught.
test "slice-typed value rejected on assignment to a List[T]-typed var" {
  val src = "package P\nrecord List[T] { }\nfunc f(xs: in slice[Int]): Unit { var ys: List[Int] = xs; ys = xs }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0061"), "the `var ys: List[Int] = xs` initialiser is rejected by the var-binding check")
  assertTrue(hasDiagCode(cr, "T0063"), "the subsequent `ys = xs` assignment is independently rejected too")
  assertTrue(not hasDiagCode(cr, "T0060"), "T0060 is the val-binding code; this source never binds with val/let")
}

test "slice-typed value rejected against a List[T] declared return type" {
  val src = "package P\nrecord List[T] { }\nfunc f(xs: in slice[Int]): List[Int] { xs }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0070"), "a slice[Int] value does not satisfy a List[Int] declared return type")
}

// #7696: return position now matches every other List[T]-expected position
// (docs/decisions/D-progress-1026-return-position-list-literals.md) — a
// bracket literal as the block's trailing/implicit value types directly as
// List[Int], same as a `val`/ctor-field/call-argument literal already did.
// This supersedes the old "still needs .toList()" pre-#7696 behaviour this
// test used to pin.
test "a list literal in List[T] return position (block trailing value) types directly as List[T] (#7696)" {
  val src = "package P\nimport Std.CollectionsHost\nfunc f(): List[Int] { [1, 2, 3] }\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(diagCount(cr), 0, "the block's trailing bracket literal types directly as List[Int]")
}

test "a list literal in List[T] return position (explicit `return`) types directly as List[T] (#7696)" {
  val src = "package P\nimport Std.CollectionsHost\nfunc f(): List[Int] { return [1, 2, 3] }\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(diagCount(cr), 0, "`return [1, 2, 3]` against a declared List[Int] return type type-checks")
}

test "a list literal in List[T] return position (expression-bodied function) types directly as List[T] (#7696)" {
  val src = "package P\nimport Std.CollectionsHost\nfunc f(): List[Int] = [1, 2]\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(diagCount(cr), 0, "an expression-bodied function's literal body types directly as List[Int]")
}

test "a list literal in List[T] return position (if arm) types directly as List[T] (#7696)" {
  val src = "package P\nimport Std.CollectionsHost\nfunc f(c: in Bool): List[Int] {\n  if c { [1, 2, 3] } else { [4, 5, 6] }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(diagCount(cr), 0, "both if-arms' bracket literals type directly as List[Int]")
}

test "a list literal in List[T] return position (match arm, bare-expr body) types directly as List[T] (#7696)" {
  val src = "package P\nimport Std.CollectionsHost\nfunc f(c: in Bool): List[Int] {\n  match c {\n    case true -> [1, 2, 3]\n    case false -> [4, 5, 6]\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(diagCount(cr), 0, "both bare-expr match-arm bracket literals type directly as List[Int]")
}

// A `slice[T]` VALUE (not a literal) must still be rejected at every one of
// the return-position forms above — #7696 only extends the LITERAL's
// direct-List-typing to return position; it does not resurrect #7545's
// removed slice-satisfies-List exemption for a genuine value.
test "a slice VALUE is still rejected via explicit `return` against a List[T] return type (#7696)" {
  val src = "package P\nimport Std.CollectionsHost\nfunc f(xs: in slice[Int]): List[Int] { return xs }\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertTrue(hasDiagCode(cr, "T0065"), "a slice[Int] value passed to `return` does not satisfy a List[Int] return type")
}

test "a slice VALUE is still rejected in an expression-bodied function against a List[T] return type (#7696)" {
  val src = "package P\nimport Std.CollectionsHost\nfunc f(xs: in slice[Int]): List[Int] = xs\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertTrue(hasDiagCode(cr, "T0070"), "a slice[Int] value does not satisfy an expression-bodied List[Int] return type")
}

test "a slice VALUE is still rejected in an if return-position arm against a List[T] return type (#7696)" {
  val src = "package P\nimport Std.CollectionsHost\nfunc f(c: in Bool, xs: in slice[Int]): List[Int] {\n  if c { xs } else { xs }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertTrue(hasDiagCode(cr, "T0070"), "a slice[Int] if-arm value does not satisfy a List[Int] return type")
}

// #7737: `.toList()` builds the stdlib `List`, so the hint is only offered
// against that type (by identity); see the "user record named List" hint
// tests further down for the shadowed case.
test "slice/List mismatch diagnostics suggest the explicit conversion" {
  val src = "package P\nimport Std.CollectionsHost\nfunc g(xs: in List[Int]): Int { 0 }\nfunc f(xs: in slice[Int]): Int { g(xs) }\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(countDiagCode(cr, "T0043"), 1, "a slice[Int] value does not satisfy the stdlib List[Int]")
  assertTrue(diagMessagesContain(cr, ".toList()"), "the T0043 message suggests .toList()")
  assertEqual(bareTypeOrigin(cr, "List"), "Std.CollectionsHost", "the parameter's List is the stdlib one")
}

// #7702: `.toList()`'s result type is the stdlib `Std.CollectionsHost.List`,
// which only exists with that package in scope. Under the bare `parseCheck`
// harness (no stdlib) it degraded to `TyError`, which every parameter accepts,
// so the zero-diagnostic assertion held vacuously. The recorded call type pins
// the real resolution, and the negative case below would pass vacuously too if
// it did not resolve.
test ".toList() bridges a slice value into a List[T] parameter" {
  val src = "package P\nimport Std.CollectionsHost\nfunc g(xs: in List[Int]): Int { 0 }\nfunc f(xs: in slice[Int]): Int { g(xs.toList()) }\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(diagCount(cr), 0, ".toList() converts slice[Int] to List[Int] at a call argument")
  assertEqual(
    recordedCallType(cr, src, "xs.toList()"),
    "List[Int]",
    "the .toList() argument resolves to List[Int], not TyError"
  )
  assertEqual(
    bareTypeOrigin(cr, "List"),
    "Std.CollectionsHost",
    "the recorded List is the stdlib Std.CollectionsHost.List"
  )
}

test ".toList() of a slice[String] is rejected by a List[Int] parameter (#7702)" {
  val src = "package P\nimport Std.CollectionsHost\nfunc g(xs: in List[Int]): Int { 0 }\nfunc f(xs: in slice[String]): Int { g(xs.toList()) }\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(countDiagCode(cr, "T0043"), 1, "List[String] from .toList() does not satisfy a List[Int] parameter")
  assertEqual(
    recordedCallType(cr, src, "xs.toList()"),
    "List[String]",
    "the rejected argument is the resolved List[String], not TyError"
  )
}

test "a list literal in a plain (non-ctor) call argument still types as List[T]" {
  val src = "package P\nimport Std.CollectionsHost\nfunc g(xs: in List[Int]): Int { 0 }\nfunc f(): Int { g([1, 2, 3]) }\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(diagCount(cr), 0, "a bracket literal call argument types directly as List[Int]")
}

test "a list literal in a List[T]-annotated val binding still type-checks" {
  val src = "package P\nimport Std.CollectionsHost\nfunc f(): Unit { val xs: List[Int] = [1, 2, 3] }\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(diagCount(cr), 0, "a bracket literal binding initialiser types directly as List[Int]")
}

// #7702: this case used to run under the bare `parseCheck` harness with a
// local `record List[T]`, and passed only because `argSatisfiesParam`'s
// empty-literal exemption matched any type NAMED `List`. That accepted `[]`
// for a user's own record while codegen built a stdlib collection there
// instead. The exemption is now id-based, so with the stdlib `List` in scope
// this passes only when `[]` is accepted as the genuine
// `Std.CollectionsHost.List`, and the local-record form below is rejected.
test "an empty list literal still satisfies a List[T] ctor field" {
  val src = "package P\nimport Std.CollectionsHost\nrecord R { items: List[Int] }\nfunc f(): R { R(items = []) }\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(diagCount(cr), 0, "[] still satisfies a List[Int] ctor field")
  assertEqual(bareTypeOrigin(cr, "List"), "Std.CollectionsHost", "the field's List is the stdlib one")
}

test "an empty list literal does not satisfy a user record named List (#7702)" {
  val src = "package P\nrecord List[T] { }\nrecord R { items: List[Int] }\nfunc f(): R { R(items = []) }\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0104"), 1, "[] is not a same-named user record List[Int]")
}

test "a list literal with the wrong element type is rejected by a List[Int] ctor field (#7702)" {
  val src = "package P\nimport Std.CollectionsHost\nrecord R { items: List[Int] }\nfunc f(): R { R(items = [\"a\", \"b\"]) }\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(countDiagCode(cr, "T0104"), 1, "a slice[String] literal does not satisfy a List[Int] ctor field")
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

// #7844: an argument that leaves a type parameter open (a nullary case of a
// generic union, like `None`) does not hide what a later argument fixes, in a
// record or union-case constructor and in a generic function call.
test "a generic constructor binds a type parameter past an open argument (#7844)" {
  val decls = "package P\nunion Opt[T] { case Nada; case Has(v: T) }\n" +
    "record Holder[T] { value: Opt[T]; fallback: T }\nunion Shape[T] { case Pair(first: Opt[T], second: T); case Solo(only: T) }\n" +
    "func pick[T](a: in Opt[T], b: in T): T { b }\n"
  val src = decls + "func f(): Unit {\n  val h = Holder(value = Nada, fallback = 5)\n  val i: Int = h.fallback\n" +
    "  val p = Holder(Nada, 6)\n  val s: Shape[Int] = Pair(second = 7, first = Nada)\n  val n: Int = pick(Nada, 5)\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "Nada first, then a fixing argument: clean (" + diagCodesOf(cr) + ")")
  val bad = decls + "func f(): Unit {\n  val h = Holder(value = Nada, fallback = 5)\n  val s: String = h.fallback\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0060"), "Holder(value = Nada, fallback = 5) is a Holder[Int]: T0060")
}

// #7844: a receiver evaluated before an `await` in the arguments is hoisted to
// a local; when neither it, the other arguments nor the expected result type
// fixes its type arguments, the program must annotate it (T0154).
test "a hoisted receiver whose type nothing fixes is T0154 (#7844)" {
  val decls = "package P\nimport Std.CollectionsHost\nunion Opt[T] { case Nada; case Has(v: T) }\n" +
    "record Box[T] {\n  v: Opt[T]\n  func size(self: in Box[T], k: in Int): Int { k }\n" +
    "  func orDefault(self: in Box[T], d: in T): T { d }\n  func peek(self: in Box[T], k: in Int): Opt[T] { self.v }\n}\n" +
    "func emptyBox[T](): Box[T] { Box(v = Nada) }\nasync func five(): Int { 5 }\n"
  val bad = decls + "async func f(): Int {\n  emptyBox().size(await five())\n}\n"
  val badCr = checkWithImportedPackages(parse(bad).file, stdCollectionsHostPackages())
  assertEqualInt(countDiagCode(badCr, "T0154"), 1, "nothing fixes T: one T0154 (" + diagCodesOf(badCr) + ")")
  val fromArg = decls + "async func f(): Int {\n  emptyBox().orDefault(await five())\n}\n"
  val argCr = checkWithImportedPackages(parse(fromArg).file, stdCollectionsHostPackages())
  assertEqualInt(diagCount(argCr), 0, "the argument fixes T: clean (" + diagCodesOf(argCr) + ")")
  val fromResult = decls + "async func f(): Opt[Int] {\n  val r: Opt[Int] = emptyBox().peek(await five())\n  r\n}\n"
  val resCr = checkWithImportedPackages(parse(fromResult).file, stdCollectionsHostPackages())
  assertEqualInt(diagCount(resCr), 0, "the expected result fixes T: clean (" + diagCodesOf(resCr) + ")")
  val coll = decls + "async func f(): Unit {\n  newList().add(await five())\n}\n"
  val collCr = checkWithImportedPackages(parse(coll).file, stdCollectionsHostPackages())
  assertEqualInt(
    countDiagCode(collCr, "T0154"),
    0,
    "List.add's element fixes the list's: no T0154 (" + diagCodesOf(collCr) + ")"
  )
  val noAwait = decls + "func f(): Int {\n  emptyBox().size(5)\n}\n"
  val noAwaitCr = checkWithImportedPackages(parse(noAwait).file, stdCollectionsHostPackages())
  assertEqualInt(countDiagCode(noAwaitCr, "T0154"), 0, "no await, nothing hoisted: no T0154")
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

// #6739: the #3156 missing-field check above was scoped only to the generic
// constructor path — a non-generic record silently type-checked an
// all-named-args construction that omitted a required (no-default) field,
// then emitted invalid IL at codegen (InvalidProgramException at runtime).
test "non-generic ctor missing required field emits T0105" {
  val src = "package P\nrecord Three { a: String; b: String; c: String }\nfunc f(): Unit { val _ = Three(a = \"x\", b = \"y\") }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0105"), "non-generic missing required field: T0105")
}

test "non-generic ctor missing field with default is not reported" {
  val src = "package P\nrecord Three { a: String; b: String; c: String = \"z\" }\nfunc f(): Unit { val _ = Three(a = \"x\", b = \"y\") }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0105"), "non-generic missing defaulted field: no T0105")
}

test "non-generic ctor all required fields supplied is clean" {
  val src = "package P\nrecord Three { a: String; b: String; c: String }\nfunc f(): Unit { val _ = Three(a = \"x\", b = \"y\", c = \"z\") }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "non-generic all fields supplied: no errors")
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
  packages.add(
    ImportedPackage(
      name = "Q",
      items = dep.file.items,
      imports = collectImportNames(dep.file.imports),
      wholeImports = collectWholeImportNames(dep.file.imports)
    )
  )
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
// PR #6547 review findings #6602-#6605: four regressions introduced by the
// #3362 value-position-aware `unifyBranchTypes` fix, all in the same
// diverging-trailing-statement / value-position-threading area.  These pin
// the fixes so a future revert of any one of them is caught by CI.
// ─────────────────────────────────────────────────────────────────────────────
// #3362 regression guard: the generalized else-if/braced-block Unit-absorption
// shape stays diagnostic-free in both its sugared `else if` form and its
// fully-braced `else { if ... }` twin.
test "else if braced Unit absorption stays clean" {
  val sugared = "package P\nfunc consume(n: in Int): Unit {}\nfunc f(c: in Bool, d: in Bool): Unit {\n  if c { consume(1) } else if d { 2 } else { () }\n}\n"
  assertEqualInt(diagCount(parseCheck(sugared)), 0, "else-if sugar: mixed value/Unit arms absorbed, no diagnostics")
  val braced = "package P\nfunc consume(n: in Int): Unit {}\nfunc f(c: in Bool, d: in Bool): Unit {\n  if c { consume(1) } else { if d { 2 } else { () } }\n}\n"
  assertEqualInt(
    diagCount(parseCheck(braced)),
    0,
    "else-if braced twin: mixed value/Unit arms absorbed, no diagnostics"
  )
}

// #6602: an unconditional `do { }` loop (the language's unlabelled-`loop`
// form) that only exits via `return` diverges — its type is `Never`, so it
// satisfies a non-Unit declared return type instead of false-firing T0070.
test "unconditional do loop diverges no T0070" {
  val src = "package P\nfunc c(): Bool { true }\nfunc f(): Int {\n  do {\n    if c() { return 1 }\n  }\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "do-loop-only-return trailing statement: no spurious T0070")
}

// #6602: `while true { }` is the same unconditional-loop shape for divergence.
test "while true diverges no T0070" {
  val src = "package P\nfunc c(): Bool { true }\nfunc f(): Int {\n  while true {\n    if c() { return 1 }\n  }\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "while-true-only-return trailing statement: no spurious T0070")
}

// #6602 regression guard: a `do` loop that CAN exit via an escaping `break`
// is not unconditionally-divergent — it can still fall through with `Unit`.
// `checkFunctionBody`'s isUnit/isNever leniency absorbs a bare Unit-typed
// trailing statement either way, so this is pinned through a value-position
// consumer (a `val` binding) where Unit and Never are NOT interchangeable:
// wrongly typing the loop as `Never` here would silently swallow a real
// T0060 mismatch.
test "do loop with escaping break not divergent" {
  val src = "package P\nfunc f(c: in Bool): Unit {\n  val x: Int = {\n    do {\n      if c { break }\n    }\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0060"), "do-loop with an escaping break: still Unit-typed, T0060 fires")
}

// #6651: `breakTargetsLoop`'s `nested` parameter was threaded through
// `blockMayEscapeLoop`/`exprMayEscapeLoop`/`stmtMayEscapeLoop` but never
// actually consulted, so a bare `break` inside a NESTED inner loop was
// misclassified as escaping the OUTER loop under analysis.  Here the outer
// `do` loop's only `break` is scoped to the inner `for` loop, so the `do`
// loop itself never escapes and diverges (its only way out is `return`, of
// which there is none, so it's an infinite loop) — its type is `Never`,
// satisfying the declared `Int` return without a spurious T0070.  Before the
// fix, `breakTargetsLoop` ignored `nested` and unconditionally returned
// `true`, so the inner `break` was wrongly counted as escaping the `do`
// loop, typing it `Unit` and false-firing T0070.
test "nested loop break does not escape outer loop diverges no T0070" {
  val src = "package P\nfunc c(): Bool { true }\nfunc f(): Int {\n  do {\n    for i in 0 ..< 3 {\n      if c() { break }\n    }\n  }\n}\n"
  assertEqualInt(
    diagCount(parseCheck(src)),
    0,
    "do-loop whose only break is scoped to a nested for-loop: outer loop still diverges, no spurious T0070"
  )
}

// #6651 correct-positive companion: a bare `break` that sits directly in the
// OUTER loop's own body (beside, not inside, a nested inner loop) must still
// be recognised as escaping that outer loop — confirms the `nested` fix
// didn't overcorrect into never detecting a genuine escape.  Value-position
// pinning matches "do loop with escaping break not divergent" above.
test "outer loop direct break still escapes beside nested inner loop" {
  val src = "package P\nfunc c(): Bool { true }\nfunc f(cond: in Bool): Unit {\n  val x: Int = {\n    do {\n      for i in 0 ..< 3 {\n        if c() { break }\n      }\n      if cond { break }\n    }\n  }\n}\n"
  assertTrue(
    hasDiagCode(parseCheck(src), "T0060"),
    "do-loop with a direct escaping break beside a nested loop: still Unit-typed, T0060 fires"
  )
}

// #6603: `scope { }`'s checked body type (`Never`, when every path through it
// diverges) must propagate to the enclosing block instead of defaulting to
// `Unit` — the trailing statement here is `SExpr(EIf)`, not `SReturn`, so
// only capturing `checkBlock`'s actual result (not the syntax-only
// `statementDiverges`) catches this.
test "scope trailing if else diverges no T0070" {
  val src = "package P\nfunc g(): Int { 1 }\nfunc f(c: in Bool): Int {\n  scope {\n    if c { return g() } else { return 0 }\n  }\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "scope with fully-diverging if/else body: no spurious T0070")
}

// #6603: the simpler single-statement `scope { return g() }` shape.
test "scope return stays clean" {
  val src = "package P\nfunc g(): Int { 1 }\nfunc f(): Int {\n  scope {\n    return g()\n  }\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "scope { return g() }: no spurious T0070")
}

// #6681: `scope { }` is a `Unit`-typed construct at runtime — its own
// non-diverging trailing-expression value must never leak into the
// enclosing block's checked type. Before the fix, `checkBlock`'s `SScope`
// arm assigned `lastExprType` to the scope body's checked value type
// unconditionally, so `scope { 42 }` inside an `Int`-returning function
// passed `typeAssignable(Int, Int)` with zero diagnostics even though
// codegen never materializes a value for `scope { }` (msil `lowerBlockMsil`,
// jvm `05_stmts.l`) — an unverifiable-IL / garbage-return silent miscompile.
test "trailing scope leaking its value type is rejected with T0070 (#6681)" {
  val src = "package P\nfunc f(): Int {\n  scope {\n    42\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(
    hasDiagCode(cr, "T0070"),
    "scope { 42 } in an Int-returning function: T0070 (scope discards its value, is Unit)"
  )
}

// Companion to #6681: a `Unit`-returning function with a trailing
// `scope { 42 }` must still compile clean — once the fix correctly
// discards the scope's leaked value type, only the enclosing `Unit`
// return type is checked against the (now-Unit) scope type.
test "trailing scope in a Unit function stays clean (#6681)" {
  val src = "package P\nfunc f(): Unit {\n  scope {\n    42\n  }\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "scope { 42 } in a Unit-returning function: no spurious T0070")
}

// #6604: `inferLambda` threads the lambda's expected return type the same way
// `checkFunctionBody` threads `bodyValuePos` — a `Unit`-expected lambda whose
// trailing statement is a discarded mixed-type `if` must stay clean, not
// reintroduce the leniency regression #3362 fixed one layer up.
test "unit lambda mixed if body stays clean" {
  val src = "package P\nfunc compute(): Int { 1 }\nfunc each(f: in (Bool) -> Unit): Unit { f(true) }\nfunc g(): Unit {\n  each((c) -> { if c { compute() } else { () } })\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "Unit-returning lambda with discarded mixed-type if: no spurious T0067")
}

// #6604 regression guard: a stronger pin that actually distinguishes
// value-position from statement-position inside a lambda body (unlike the
// mixed-`if` shape above, whose Unit-absorption is already position-blind) —
// a trailing `try` whose non-Unit body sits beside a Unit handler is only
// safe to absorb when the lambda's expected return type is `Unit`.  Reverting
// `inferLambda`'s hardcoded `valuePos = true` reintroduces this exact T0067.
test "unit lambda try unit handler stays clean" {
  val src = "package P\nfunc each(f: in (Bool) -> Unit): Unit { f(true) }\nfunc g(): Unit {\n  each((c) -> {\n    try {\n      42\n    } catch Bug as b {\n      ()\n    }\n  })\n}\n"
  assertTrue(
    not hasDiagCode(parseCheck(src), "T0067"),
    "Unit-expected lambda: try body/Unit handler absorbed in statement position, no T0067"
  )
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

// #7229: a config field may be a range of Int / Long / Float / Double with
// literal, non-empty bounds; its default must lie inside the range.
test "config range fields" {
  val ok = "package P\nconfig R1 { port: Int range 1 ..= 65535 = 8080; ttl: Long range 1 .. = 60; ratio: Double range 0.0 ..< 1.0 = 0.5; cap: Int range ..= 100; neg: Int range -10 ..= -1 = -5 }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "config: range fields with in-range defaults accepted")
  val outside = "package P\nconfig R2 { port: Int range 1 ..= 65535 = 0 }\n"
  assertTrue(hasDiagCode(parseCheck(outside), "G0010"), "config: default below the range is G0010")
  val exclusive = "package P\nconfig R3 { ratio: Double range 0.0 ..< 1.0 = 1.0 }\n"
  assertTrue(hasDiagCode(parseCheck(exclusive), "G0010"), "config: default at an exclusive upper bound is G0010")
  val nonLit = "package P\nval lo = 1\nconfig R4 { port: Int range lo ..= 10 }\n"
  assertTrue(hasDiagCode(parseCheck(nonLit), "G0009"), "config: a non-literal bound is G0009")
  val empty = "package P\nconfig R5 { n: Int range 10 ..= 1 }\n"
  assertTrue(hasDiagCode(parseCheck(empty), "G0009"), "config: an empty range is G0009")
  val floatBound = "package P\nconfig R6 { n: Int range 0 ..= 1.5 }\n"
  assertTrue(hasDiagCode(parseCheck(floatBound), "G0009"), "config: a float bound on an Int field is G0009")
  val wide = "package P\nconfig R7 { n: Int range 0 ..= 3000000000 }\n"
  assertTrue(hasDiagCode(parseCheck(wide), "G0009"), "config: an Int bound outside Int is G0009")
  val str = "package P\nconfig R8 { s: String range 1 ..= 2 }\n"
  assertTrue(hasDiagCode(parseCheck(str), "G0009"), "config: a range of String is G0009")
}

// #7229: an aspect's own ranged config field is checked like a config block's.
test "aspect config range fields" {
  val bad = "package P\naspect Twice {\n  matches: name in { work }\n  config {\n    times: Int range 1 ..= 5 = 9\n  }\n  around(call) -> ret {\n    ret = call.proceed()\n  }\n}\nfunc work(x: in Int): Int = x\n"
  assertTrue(hasDiagCode(parseCheck(bad), "G0010"), "aspect config: default outside the range is G0010")
  val ok = "package P\naspect Twice {\n  matches: name in { work }\n  config {\n    times: Int range 1 ..= 5 = 2\n  }\n  around(call) -> ret {\n    ret = call.proceed()\n  }\n}\nfunc work(x: in Int): Int = x\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "G0010"), "aspect config: in-range default accepted")
  val str = "package P\naspect Twice {\n  matches: name in { work }\n  config {\n    s: String range 1 ..= 2 = \"a\"\n  }\n  around(call) -> ret {\n    ret = call.proceed()\n  }\n}\nfunc work(x: in Int): Int = x\n"
  assertTrue(hasDiagCode(parseCheck(str), "G0009"), "aspect config: a range of String is G0009")
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
// #6720: D-progress-818 broadened the `SFor` single-type-param generic
// fallback to type ANY single-param generic's element (motivated by the
// extern phantom-type-param collection idiom, e.g. `Set[T]`/
// `JHttpStringCollection[T]`), but that also silently typed the loop element
// for genuinely non-iterable single-param generics like a Lyric-native
// `Option[T]`-shaped union, with no diagnostic — codegen's index-loop
// fallback (`.Count`/`get_Item`) then fails at runtime.  T0126 rejects a
// `for` over a single-type-param generic that is NOT `List`/an extern type.
// ─────────────────────────────────────────────────────────────────────────────
test "for over a non-iterable Lyric-native single-param generic emits T0126" {
  val src = "package P\nunion Box[T] {\n  case Full(value: T)\n  case Empty\n}\nfunc f(b: in Box[Int]): Unit {\n  for x in b {\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0126"), "for over Box[T] (non-iterable union): T0126")
}

test "for over a non-iterable Lyric-native single-param generic record emits T0126" {
  val src = "package P\nrecord Wrap[T] {\n  value: T\n}\nfunc f(w: in Wrap[Int]): Unit {\n  for x in w {\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0126"), "for over Wrap[T] (non-iterable record): T0126")
}

// D-progress-1006: a `String` is not iterable — its elements would have to be
// UTF-16 code units, and a surrogate half is not a `Char` — so `for c in s`
// is T0126 with a message naming the code-point and code-unit views (before,
// it type-checked as `TyError` and failed at runtime on both backends).
test "for over a String emits T0126 naming codePoints" {
  val src = "package P\nfunc f(s: in String): Unit {\n  for c in s {\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0126"), "for over String: T0126")
  assertTrue(Str.contains(diagMessageFor(cr, "T0126"), "codePoints"), "T0126 names Std.String.codePoints")
}

test "for over a String-yielding async generator does not emit T0126" {
  val src = "package P\nasync func words(): String {\n  yield \"a\"\n}\nfunc f(): Unit {\n  for w in words() {\n  }\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0126"), "generator call iterates its yields, not a String")
}

// #7781: only single-type-parameter Lyric-native generics were T0126; a
// record/union/enum of any other arity fell through to a silent `TyError`
// loop element, which then masked every diagnostic about the loop variable
// in the body.  Each non-iterable type is now exactly one T0126, whatever its
// arity, and a valid iteration still types its element.
test "for over a two-param user record is exactly one T0126 (#7781)" {
  val src = "package P\nrecord Pair[A, B] {\n  a: A\n  b: B\n}\nfunc f(p: in Pair[Int, String]): Unit {\n  for x in p {\n    val s: String = x\n  }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0126"), 1, "a two-param record is not iterable")
  assertTrue(
    Str.contains(diagMessageFor(cr, "T0126"), "Pair[Int, String]"),
    "T0126 names the iterated type: " + diagMessageFor(cr, "T0126")
  )
}

test "for over a three-param user record is exactly one T0126 (#7781)" {
  val src = "package P\nrecord Triple[A, B, C] {\n  a: A\n  b: B\n  c: C\n}\nfunc f(t: in Triple[Int, Int, Int]): Unit {\n  for x in t {\n  }\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0126"), 1, "a three-param record is not iterable")
}

test "for over a user MapValueCollection[K, V] record is exactly one T0126 (#7781)" {
  val src = "package P\nrecord MapValueCollection[K, V] {\n  v: V\n}\nfunc f(vs: in MapValueCollection[String, Int]): Unit {\n  for v in vs {\n  }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0126"), 1, "a user MapValueCollection is not the stdlib one")
  assertTrue(
    Str.contains(diagMessageFor(cr, "T0126"), "only shares its name with the stdlib MapValueCollection"),
    "T0126 says the collection is not the stdlib one: " + diagMessageFor(cr, "T0126")
  )
}

test "for over a non-generic record is exactly one T0126 (#7781)" {
  val src = "package P\nrecord Point {\n  x: Int\n}\nfunc f(p: in Point): Unit {\n  for x in p {\n  }\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0126"), 1, "a non-generic record is not iterable")
}

test "for over a two-param union is exactly one T0126 (#7781)" {
  val src = "package P\nunion Either[L, R] {\n  case Left(l: L)\n  case Right(r: R)\n}\nfunc f(e: in Either[Int, String]): Unit {\n  for x in e {\n  }\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0126"), 1, "a two-param union is not iterable")
}

test "for over an enum is exactly one T0126 (#7781)" {
  val src = "package P\nenum Color {\n  case Red\n  case Green\n}\nfunc f(c: in Color): Unit {\n  for x in c {\n  }\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0126"), 1, "an enum is not iterable")
}

test "for over a distinct type is T0126 naming its value (#7781)" {
  val src = "package P\ntype Ids = slice[Int]\nfunc f(ids: in Ids): Unit {\n  for x in ids {\n  }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0126"), 1, "a distinct type is not iterable")
  assertTrue(
    Str.contains(diagMessageFor(cr, "T0126"), "`.value`"),
    "T0126 points at `.value`: " + diagMessageFor(cr, "T0126")
  )
}

test "for over an Int or a tuple is exactly one T0126 (#7781)" {
  val src = "package P\nfunc f(n: in Int, t: in (Int, Int)): Unit {\n  for x in n {\n  }\n  for y in t {\n  }\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0126"), 2, "an Int and a tuple are not iterable")
}

test "for over the stdlib Map is T0126 naming mapKeys (#7781)" {
  val src = "package P\nimport Std.CollectionsHost\nfunc f(m: in Map[String, Int]): Unit {\n  for k in m {\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(countDiagCode(cr, "T0126"), 1, "a bare Map has no iteration lowering")
  assertTrue(
    Str.contains(diagMessageFor(cr, "T0126"), "mapKeys"),
    "T0126 names mapKeys: " + diagMessageFor(cr, "T0126")
  )
}

test "a non-iterable for whose iterator already failed adds no T0126 (#7781)" {
  val src = "package P\nfunc f(): Unit {\n  for x in missing {\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0020"), "the unknown iterator is reported")
  assertEqualInt(countDiagCode(cr, "T0126"), 0, "an already-failed iterator is not also T0126")
}

test "a valid for still reports a mistyped use of its element (#7781)" {
  val src = "package P\nfunc f(xs: in slice[Int]): Unit {\n  for x in xs {\n    val s: String = x\n  }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0126"), 0, "a slice is iterable")
  assertEqualInt(countDiagCode(cr, "T0060"), 1, "the element is Int, so a String binding of it is rejected")
}

// #7771: whether a `for` iterates a generator call is decided by the
// signature the call binds to, not the callee's bare name + arity.  Every
// case below pairs a generator `each` with a non-generator reached under the
// same name and arity; the loop variable must take the type of whichever the
// call actually calls.  `diagCodesOf` names the codes in each failure message.
func diagCodesOf(cr: in CheckResult): String {
  var acc = ""
  var i = 0
  while i < cr.diagnostics.count {
    acc = acc + cr.diagnostics[i].code + ": " + cr.diagnostics[i].message + "; "
    i = i + 1
  }
  acc
}

func genEachPackage(src: in String, name: in String): List[ImportedPackage] {
  val pkg = parse(src)
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = name,
      items = pkg.file.items,
      imports = collectImportNames(pkg.file.imports),
      wholeImports = collectWholeImportNames(pkg.file.imports)
    )
  )
  packages
}

test "for over a package-local non-generator sharing an imported generator's name and arity" {
  val gen = genEachPackage(
    "package Gen\npub async func each(xs: in slice[Int]): Int {\n  for x in xs {\n    yield x\n  }\n}\n",
    "Gen"
  )
  val src = "package App\nimport Gen\nfunc each(xs: in slice[Int]): slice[Int] { xs }\n" +
    "func f(xs: in slice[Int]): Int {\n  var s = 0\n  for v in each(xs) {\n    val y: Int = v\n    s = s + y\n  }\n  s\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, gen)
  assertEqualInt(diagCount(cr), 0, "local non-generator each: loop variable is Int; " + diagCodesOf(cr))
}

test "for over a qualified non-generator sharing a local generator's name and arity" {
  val lists = genEachPackage("package Lists\npub func each(xs: in slice[Int]): slice[Int] { xs }\n", "Lists")
  val src = "package App\nimport Lists\n" +
    "async func each(xs: in slice[Int]): Int {\n  for x in xs {\n    yield x\n  }\n}\n" +
    "func f(xs: in slice[Int]): Int {\n  var s = 0\n  for v in Lists.each(xs) {\n    s = s + v\n  }\n  for g in each(xs) {\n" +
    "    s = s + g\n  }\n  s\n}\n"
  val cr = checkWithImportedPackages(rewriteFile(parse(src).file), lists)
  assertEqualInt(diagCount(cr), 0, "Lists.each(xs) iterates its slice[Int]; " + diagCodesOf(cr))
}

test "for over a method named like a generator types the loop variable from the method" {
  val src = "package P\nasync func each(n: in Int): Int {\n  yield n\n}\n" +
    "interface Scaler {\n  func each(n: in Int): slice[Int]\n}\nrecord Scale { ks: slice[Int] }\n" +
    "impl Scaler for Scale {\n  func each(n: in Int): slice[Int] { self.ks }\n}\n" +
    "record Bag { items: slice[Int] }\nfunc Bag.each(self: in Bag, n: in Int): slice[Int] { self.items }\n" +
    "func f(sc: in Scale, b: in Bag): Int {\n  var s = 0\n  for v in sc.each(2) {\n    s = s + v\n  }\n" +
    "  for w in b.each(3) {\n    s = s + w\n  }\n  s\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "impl method / type-associated each iterate their slice[Int]; " + diagCodesOf(cr))
}

test "for over a local function value shadowing a generator types the loop variable from the value" {
  val src = "package P\nasync func each(n: in Int): Int {\n  yield n\n}\n" +
    "func f(xs: in slice[Int]): Int {\n  val each = { (n: Int) -> xs }\n" +
    "  var s = 0\n  for v in each(3) {\n    s = s + v\n  }\n  s\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "the shadowing lambda's slice[Int] is iterated; " + diagCodesOf(cr))
}

test "for over a type-associated generator types the loop variable as its element" {
  val src = "package P\nrecord Bag { n: Int }\nasync func Bag.values(self: in Bag): Int {\n  yield self.n\n}\n" +
    "func f(b: in Bag): Unit {\n  for v in b.values() {\n    val t: String = v\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0060"), "b.values() yields Int, so binding it as String is rejected; " + diagCodesOf(cr))
}

test "s.codeUnitAt types as Int and checks its argument" {
  val ok = "package P\nfunc f(s: in String): Int {\n  s.codeUnitAt(0) + 1\n}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0043"), "codeUnitAt(Int): Int")
  val bad = "package P\nfunc f(s: in String): Int {\n  s.codeUnitAt(\"0\")\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0043"), "codeUnitAt(String): T0043")
}

test "for over an extern single-param generic collection does not emit T0126" {
  val src = "package P\nextern type Set[T] = \"System.Collections.Generic.HashSet`1\"\nfunc f(xs: in Set[String]): Int {\n  var n = 0\n  for s in xs {\n    n = n + s.length\n  }\n  n\n}\n"
  assertTrue(
    not hasDiagCode(parseCheck(src), "T0126"),
    "for over extern Set[T]: no T0126 (phantom-type-param idiom, #6565)"
  )
}

// #6565's actual motivating shape imports the extern generic collection from
// a separate package rather than declaring it locally — pin down that
// `symTableIsExternTypeId`'s linear scan over `tbl.symbols` sees imported
// `DKExternType` symbols too, not just same-file ones.
test "for over a cross-package imported extern single-param generic collection does not emit T0126" {
  val pkgKernel = parse("package Web.Kernel\npub extern type JHttpStringCollection[T] = \"java.util.Collection\"\n")
  val imports: List[ImportedPackage] = newList()
  imports.add(
    ImportedPackage(
      name = "Web.Kernel",
      items = pkgKernel.file.items,
      imports = collectImportNames(pkgKernel.file.imports),
      wholeImports = collectWholeImportNames(pkgKernel.file.imports)
    )
  )
  val app = parse(
    "package App\nimport Web.Kernel\nfunc f(xs: in Web.Kernel.JHttpStringCollection[String]): Int {\n  var n = 0\n  for s in xs {\n    n = n + s.length\n  }\n  n\n}\n"
  )
  val cr = checkWithImportedPackages(app.file, imports)
  assertTrue(
    not hasDiagCode(cr, "T0126"),
    "for over cross-package imported extern JHttpStringCollection[T]: no T0126 (#6565)"
  )
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

// #7439: a distinct type is nominal (docs/01 §2.3).  `.value` reads the
// underlying value, typed as the underlying type; any other member read is
// T0113 pointing at `.value` (it used to type-check unchecked and miscompile).
test "field read through a distinct type over a record is T0113" {
  val src = "package P\nrecord Widget {\n  n: Int\n}\ntype Wid = Widget\nfunc get(w: in Wid): Int { w.n }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0113"), "w.n on a distinct type: T0113")
  assertTrue(diagMessageFor(cr, "T0113").contains(".value"), "T0113 points at .value")
}

test "value on a distinct type has the underlying type" {
  val ok = "package P\nrecord Widget {\n  n: Int\n}\ntype Wid = Widget\nfunc get(w: in Wid): Int { w.value.n }\n"
  assertEqualInt(countDiagCode(parseCheck(ok), "T0113"), 0, "w.value.n: no T0113")
  assertEqualInt(countDiagCode(parseCheck(ok), "T0070"), 0, "w.value.n: Int")
  val bad = "package P\ntype UserId = Long\nfunc f(u: in UserId): String {\n  val s: String = u.value\n  s\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0060"), "UserId.value is a Long, not a String: T0060")
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

// #7575: an imported record's member surface is known too (its contract repr
// carries body methods since #6440), so an unknown field read on it is T0113
// instead of an unreported `TyError` that reached codegen as invalid IL.
test "unknown field on an imported record is T0113" {
  val importedItems = importedItemsOf("package Dep\npub record Widget {\n  w: Int\n}\n")
  val src = "package App\nimport Dep\nfunc consume(x: in Widget): Int { x.mystery }\n"
  val cr = checkWithImports(parse(src).file, importedItems)
  assertTrue(hasDiagCode(cr, "T0113"), "unknown field on imported record: T0113")
  assertTrue(diagMessageFor(cr, "T0113").contains("Widget"), "T0113 names the imported receiver type")
}

test "unknown method on an imported record is T0113" {
  val importedItems = importedItemsOf("package Dep\npub record Widget {\n  w: Int\n}\n")
  val src = "package App\nimport Dep\nfunc consume(x: in Widget): Int { x.mystery() }\n"
  assertTrue(
    hasDiagCode(checkWithImports(parse(src).file, importedItems), "T0113"),
    "unknown method on imported record: T0113"
  )
}

test "imported record members resolve without T0113" {
  val dep = "package Dep\npub record Widget {\n  w: Int\n  func twice(self: in Widget): Int { self.w * 2 }\n}\npub func Widget.half(x: in Widget): Int { x.w / 2 }\npub interface Sized {\n  func size(): Int\n}\nimpl Sized for Widget {\n  func size(): Int { 1 }\n}\n"
  val src = "package App\nimport Dep\nfunc consume(x: in Widget): Int { x.w + x.twice() + x.half() + x.size() }\n"
  val cr = checkWithImports(parse(src).file, importedItemsOf(dep))
  assertEqualInt(countDiagCode(cr, "T0113"), 0, "field, body method, dot-named function and impl method all resolve")
}

test "unknown method on an imported interface is T0113" {
  val importedItems = importedItemsOf("package Dep\npub interface Sized {\n  func size(): Int\n}\n")
  val src = "package App\nimport Dep\nfunc consume(x: in Sized): Int { x.width() }\n"
  assertTrue(
    hasDiagCode(checkWithImports(parse(src).file, importedItems), "T0113"),
    "unknown method on imported interface: T0113"
  )
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
    imports = newList(),
    wholeImports = newList()
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
    imports = newList(),
    wholeImports = newList()
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
    imports = newList(),
    wholeImports = newList()
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
  val pkg = ImportedPackage(name = "Lib.Kernel", items = kernelItems, imports = newList(), wholeImports = newList())
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
  val pkg = ImportedPackage(name = "Lib.OnlyExtern", items = kernelItems, imports = newList(), wholeImports = newList())
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
  val pkg = ImportedPackage(name = "Lib.OnlyExtern", items = kernelItems, imports = newList(), wholeImports = newList())
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

// ─────────────────────────────────────────────────────────────────────────────
// #6287 Phase B: bare-name cross-package ambiguity (T0123) and
// reject-unimported-resolution.
// ─────────────────────────────────────────────────────────────────────────────
// A bare (unqualified) `pub val` name declared by TWO imported packages is
// genuinely ambiguous — before this fix `symTableTryFindOne` silently picked
// whichever was registered last, with no diagnostic at all.
test "bare val name ambiguous across two imported packages is T0123" {
  val pkgA = parse("package PkgA\npub val GREETING: String = \"hi from A\"\n")
  val pkgB = parse("package PkgB\npub val GREETING: String = \"hi from B\"\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgA",
      items = pkgA.file.items,
      imports = collectImportNames(pkgA.file.imports),
      wholeImports = collectWholeImportNames(pkgA.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "PkgB",
      items = pkgB.file.items,
      imports = collectImportNames(pkgB.file.imports),
      wholeImports = collectWholeImportNames(pkgB.file.imports)
    )
  )
  val src = "package App\nimport PkgA\nimport PkgB\nfunc f(): String { GREETING }\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, packages), "T0123"),
    1,
    "bare GREETING ambiguous between PkgA and PkgB: T0123 fires exactly once"
  )
}

// Same ambiguity, but through a bare (unqualified) union-case CONSTRUCTOR
// CALL — the shape the issue's own `Ping`/`Signal` example was framed around.
// Reuses the PkgA/PkgB `Signal { case Ping }` collision fixture the qualified-
// reference tests above already establish, but this time calls `Ping(...)`
// with NO qualifier at all.
test "bare union case constructor call ambiguous across two imported packages is T0123" {
  val pkgA = parse("package PkgA\npub union Signal {\n  case Ping(code: Int)\n  case Halt\n}\n")
  val pkgB = parse("package PkgB\npub union Signal {\n  case Ping(label: String)\n  case Halt\n}\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgA",
      items = pkgA.file.items,
      imports = collectImportNames(pkgA.file.imports),
      wholeImports = collectWholeImportNames(pkgA.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "PkgB",
      items = pkgB.file.items,
      imports = collectImportNames(pkgB.file.imports),
      wholeImports = collectWholeImportNames(pkgB.file.imports)
    )
  )
  val src = "package App\nimport PkgA\nimport PkgB\nfunc f(): Int {\n  val s = Ping(code = 1)\n  0\n}\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, packages), "T0123"),
    1,
    "bare Ping(...) ambiguous between PkgA's and PkgB's Signal: T0123 fires exactly once"
  )
}

// Same ambiguity again, but through a bare (unqualified) FUNCTION reference —
// #6652 review: `sigs`'s first-in-wins insertion policy for imported
// functions (typechecker_checker.l, "Sig-map insertion policy") let a bare
// function call resolve above the `checkBareNameAmbiguity` gate, silently
// picking whichever package's `IFunc` was collected first, with no T0123 at
// all — the exact last/first-registered-wins hazard #6287 was filed to
// eliminate, just never closed for plain function names.
test "bare function name ambiguous across two imported packages is T0123" {
  val pkgA = parse("package PkgA\npub func helper(): Int { 1 }\n")
  val pkgB = parse("package PkgB\npub func helper(): Int { 2 }\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgA",
      items = pkgA.file.items,
      imports = collectImportNames(pkgA.file.imports),
      wholeImports = collectWholeImportNames(pkgA.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "PkgB",
      items = pkgB.file.items,
      imports = collectImportNames(pkgB.file.imports),
      wholeImports = collectWholeImportNames(pkgB.file.imports)
    )
  )
  val src = "package App\nimport PkgA\nimport PkgB\nfunc f(): Int { helper() }\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, packages), "T0123"),
    1,
    "bare helper() ambiguous between PkgA and PkgB: T0123 fires exactly once"
  )
}

// Importing a colliding name from only ONE of the two packages is NOT
// ambiguous — this is the ordinary single-import case the fix must leave
// alone (no false positives).
test "bare val name imported from only one package is not ambiguous" {
  val pkgA = parse("package PkgA\npub val GREETING: String = \"hi from A\"\n")
  val pkgB = parse("package PkgB\npub val GREETING: String = \"hi from B\"\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgA",
      items = pkgA.file.items,
      imports = collectImportNames(pkgA.file.imports),
      wholeImports = collectWholeImportNames(pkgA.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "PkgB",
      items = pkgB.file.items,
      imports = collectImportNames(pkgB.file.imports),
      wholeImports = collectWholeImportNames(pkgB.file.imports)
    )
  )
  val src = "package App\nimport PkgA\nfunc f(): String { GREETING }\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(src).file, packages)),
    0,
    "GREETING imported only via PkgA (App does not import PkgB): resolves cleanly, no T0123"
  )
}

// A same-package (same-file) declaration always wins outright over any
// import-level collision — declaring the SAME name locally must not trip
// the ambiguity check even when two OTHER imported packages also collide
// on it (tier 1 always wins, per `symTableAmbiguousImportPackages`'s guard).
test "local declaration shadows an ambiguous import collision, no T0123" {
  val pkgA = parse("package PkgA\npub val GREETING: String = \"hi from A\"\n")
  val pkgB = parse("package PkgB\npub val GREETING: String = \"hi from B\"\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgA",
      items = pkgA.file.items,
      imports = collectImportNames(pkgA.file.imports),
      wholeImports = collectWholeImportNames(pkgA.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "PkgB",
      items = pkgB.file.items,
      imports = collectImportNames(pkgB.file.imports),
      wholeImports = collectWholeImportNames(pkgB.file.imports)
    )
  )
  val src = "package App\nimport PkgA\nimport PkgB\nval GREETING: String = \"local\"\nfunc f(): String { GREETING }\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(src).file, packages)),
    0,
    "App's own GREETING wins outright over the PkgA/PkgB collision: no T0123"
  )
}

// docs/01 §9.2 (#7463, closing #6703): a bare name resolves only through the
// file's own imports.  A whole import (`import P`) makes every name of `P`
// visible, and transitively the names of the packages `P` imports; a
// selective import (`import P.{f}`) only the listed names; an aliased import
// (`import P as Q`) none, since they are reached as `Q.f`.  A name that exists
// but is hidden this way is T0020 with a hint saying how to import it.
func importRulePackages(): List[ImportedPackage] {
  val pkgX = parse("package PkgX\npub func siblingHelper(): Int { 1 }\n")
  val pkgY = parse("package PkgY\npub func fromY(): Int { 2 }\npub func otherY(): Int { 3 }\npub val LIMIT: Int = 4\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgX",
      items = pkgX.file.items,
      imports = collectImportNames(pkgX.file.imports),
      wholeImports = collectWholeImportNames(pkgX.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "PkgY",
      items = pkgY.file.items,
      imports = collectImportNames(pkgY.file.imports),
      wholeImports = collectWholeImportNames(pkgY.file.imports)
    )
  )
  packages
}

test "a bare name from a package the file never imports is T0020 with an import hint (#6703)" {
  val src = "package App\nimport PkgY\nfunc f(): Int { siblingHelper() }\n"
  val cr = checkWithImportedPackages(parse(src).file, importRulePackages())
  assertEqualInt(countDiagCode(cr, "T0020"), 1, "siblingHelper (PkgX, never imported): T0020")
  assertTrue(
    diagMessageFor(cr, "T0020").contains("declared in PkgX; add import PkgX or import PkgX.{siblingHelper}"),
    "the hint names the declaring package: " + diagMessageFor(cr, "T0020")
  )
  val okSrc = "package App\nimport PkgY\nfunc f(): Int { fromY() }\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(okSrc).file, importRulePackages())),
    0,
    "fromY (imported whole) resolves"
  )
}

test "a selective import makes only its listed names visible bare" {
  val src = "package App\nimport PkgY.{fromY}\nfunc f(): Int { fromY() }\nfunc g(): Int { otherY() }\nfunc h(): Int { LIMIT }\n"
  val cr = checkWithImportedPackages(parse(src).file, importRulePackages())
  assertEqualInt(countDiagCode(cr, "T0020"), 2, "otherY and LIMIT are not listed: T0020 twice, fromY resolves")
  assertTrue(
    diagMessageFor(cr, "T0020").contains("import PkgY.{"),
    "the hint suggests listing the name: " + diagMessageFor(cr, "T0020")
  )
}

test "an aliased import makes no name visible bare; the qualified form resolves" {
  val src = "package App\nimport PkgY as Y\nfunc f(): Int { fromY() }\n"
  val cr = checkWithImportedPackages(parse(src).file, importRulePackages())
  assertEqualInt(countDiagCode(cr, "T0020"), 1, "bare fromY through an aliased import: T0020")
  assertTrue(
    diagMessageFor(cr, "T0020").contains("imported as Y; write Y.fromY"),
    "the hint names the alias: " + diagMessageFor(cr, "T0020")
  )
  // The alias rewriter turns `Y.fromY()` into this package-qualified call.
  val qualSrc = "package App\nimport PkgY as Y\nfunc f(): Int { PkgY.fromY() }\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(qualSrc).file, importRulePackages())),
    0,
    "PkgY.fromY resolves"
  )
}

test "a name hidden by an aliased import does not make a whole import's name ambiguous" {
  val pkgA = parse("package PkgA\npub val GREETING: String = \"hi from A\"\n")
  val pkgB = parse("package PkgB\npub val GREETING: String = \"hi from B\"\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgA",
      items = pkgA.file.items,
      imports = collectImportNames(pkgA.file.imports),
      wholeImports = collectWholeImportNames(pkgA.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "PkgB",
      items = pkgB.file.items,
      imports = collectImportNames(pkgB.file.imports),
      wholeImports = collectWholeImportNames(pkgB.file.imports)
    )
  )
  val src = "package App\nimport PkgA as A\nimport PkgB\nfunc f(): String { GREETING }\n"
  assertEqualInt(diagCount(checkWithImportedPackages(parse(src).file, packages)), 0, "GREETING means PkgB's: no T0123")
}

test "a selectively imported union type makes its cases visible in patterns and constructors" {
  val lib = parse(
    "package PkgS\npub union Shape {\n  case Square(side: Int)\n  case Dot\n}\npub func unit(): Shape { Dot }\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgS",
      items = lib.file.items,
      imports = collectImportNames(lib.file.imports),
      wholeImports = collectWholeImportNames(lib.file.imports)
    )
  )
  val src = "package App\nimport PkgS.{Shape}\nfunc side(s: in Shape): Int {\n  match s {\n    case Square(n) -> n\n    case Dot -> 0\n  }\n}\nfunc mk(): Shape { Square(side = 2) }\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(src).file, packages)),
    0,
    "Square and Dot resolve through Shape"
  )
}

test "a bare case pattern resolves through the scrutinee's type behind an aliased import" {
  val lib = parse("package PkgE\npub enum Colour {\n  case Red\n  case Green\n}\npub func pick(): Colour { Red }\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgE",
      items = lib.file.items,
      imports = collectImportNames(lib.file.imports),
      wholeImports = collectWholeImportNames(lib.file.imports)
    )
  )
  val src = "package App\nimport PkgE as E\nfunc code(c: in PkgE.Colour): Int {\n  match c {\n    case Red -> 1\n    case Green -> 2\n  }\n}\n"
  assertEqualInt(diagCount(checkWithImportedPackages(parse(src).file, packages)), 0, "Red and Green are Colour's cases")
  val exprSrc = "package App\nimport PkgE as E\nfunc mk(): PkgE.Colour { Red }\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(exprSrc).file, packages), "T0020"),
    1,
    "a hidden case in an expression is T0020"
  )
}

// The kernel/host re-export idiom used throughout `lyric-stdlib/std/_kernel/`
// (e.g. `Std.Collections` importing `Std.CollectionsHost`, which declares
// `List`/`Map`) depends on TRANSITIVE reachability: a consumer that only
// imports the wrapper package (`PkgWrap`) must still resolve a name declared
// by the wrapper's own import (`PkgHost`), even though the consumer never
// names `PkgHost` in its own `import` list (docs/01 §9.2).
test "bare name reachable only via a transitive import still resolves (kernel/host idiom)" {
  val pkgHost = parse("package PkgHost\npub func hostFn(): Int { 42 }\n")
  val pkgWrap = parse("package PkgWrap\nimport PkgHost\npub func wrapFn(): Int { hostFn() }\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgHost",
      items = pkgHost.file.items,
      imports = collectImportNames(pkgHost.file.imports),
      wholeImports = collectWholeImportNames(pkgHost.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "PkgWrap",
      items = pkgWrap.file.items,
      imports = collectImportNames(pkgWrap.file.imports),
      wholeImports = collectWholeImportNames(pkgWrap.file.imports)
    )
  )
  val src = "package App\nimport PkgWrap\nfunc f(): Int { hostFn() }\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(src).file, packages)),
    0,
    "hostFn (PkgHost) resolves transitively through PkgWrap's own import of PkgHost, even though App never imports PkgHost directly"
  )
}

func rulePkg(name: in String, src: in String): ImportedPackage {
  val f = parse(src).file
  ImportedPackage(
    name = name,
    items = f.items,
    imports = collectImportNames(f.imports),
    wholeImports = collectWholeImportNames(f.imports)
  )
}

// #7555: only a whole import reaches further.  A package's selective or
// aliased imports are its own business; a file that imports it whole does
// not see those packages' names.
test "transitive visibility follows only the intermediate package's whole imports" {
  val packages: List[ImportedPackage] = newList()
  packages.add(rulePkg("PkgH1", "package PkgH1\npub func viaAlias(): Int { 1 }\n"))
  packages.add(rulePkg("PkgH2", "package PkgH2\npub func listed(): Int { 2 }\npub func unlisted(): Int { 3 }\n"))
  packages.add(
    rulePkg(
      "PkgMid",
      "package PkgMid\nimport PkgH1 as H\nimport PkgH2.{listed}\npub func mid(): Int { H.viaAlias() + listed() }\n"
    )
  )
  val aliasSrc = "package App\nimport PkgMid\nfunc f(): Int { viaAlias() }\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(aliasSrc).file, packages), "T0020"),
    1,
    "PkgMid imports PkgH1 only through an alias: viaAlias is not visible"
  )
  val selSrc = "package App\nimport PkgMid\nfunc f(): Int { listed() + unlisted() }\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(selSrc).file, packages), "T0020"),
    2,
    "PkgMid imports PkgH2 selectively: neither name reaches App"
  )
}

// #7556: two packages reached only transitively collide like two direct
// imports; a direct import still shadows every transitive candidate.
test "a bare name declared by two transitively reached packages is T0123" {
  val packages: List[ImportedPackage] = newList()
  packages.add(rulePkg("PkgC", "package PkgC\npub func foo(): Int { 1 }\n"))
  packages.add(rulePkg("PkgD", "package PkgD\npub func foo(): Int { 2 }\n"))
  packages.add(rulePkg("PkgTa", "package PkgTa\nimport PkgC\npub func useA(): Int { foo() }\n"))
  packages.add(rulePkg("PkgTb", "package PkgTb\nimport PkgD\npub func useB(): Int { foo() }\n"))
  val src = "package App\nimport PkgTa\nimport PkgTb\nfunc run(): Int { foo() }\n"
  val cr = checkWithImportedPackages(parse(src).file, packages)
  assertEqualInt(countDiagCode(cr, "T0123"), 1, "foo is reached through PkgTa and PkgTb: T0123")
  assertTrue(
    diagMessageFor(cr, "T0123").contains("reached through this file's imports"),
    "the message says the packages are reached transitively: " + diagMessageFor(cr, "T0123")
  )
  val directSrc = "package App\nimport PkgTa\nimport PkgD\nfunc run(): Int { foo() }\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(directSrc).file, packages)),
    0,
    "a direct import of PkgD shadows PkgC's transitive foo"
  )
}

// #7567: a directly imported function shadows one reached only
// transitively, even when the transitive one registered first.
test "a bare call binds a direct import's function over a transitive one" {
  val packages: List[ImportedPackage] = newList()
  packages.add(rulePkg("PkgFc", "package PkgFc\npub func foo(): String { \"c\" }\n"))
  packages.add(rulePkg("PkgFt", "package PkgFt\nimport PkgFc\npub func useT(): Int { 1 }\n"))
  packages.add(rulePkg("PkgFd", "package PkgFd\npub func foo(): Int { 2 }\n"))
  val src = "package App\nimport PkgFt\nimport PkgFd\nfunc run(): Int { foo() }\nfunc value(): Int {\n  val f = foo\n  f()\n}\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(src).file, packages)),
    0,
    "foo is PkgFd's Int function, not PkgFc's"
  )
}

// #7458: a same-named function declared by a sibling PROJECT package that
// the file neither imports directly nor reaches transitively must never
// win over the directly-imported package's own declaration — regardless of
// registration order in `importedPackages`. This is the exact shape of the
// lyric-i18n regression: `I18n` and `I18n.Kernel` are unrelated sibling
// packages in the same manifest, both declaring `pub func loadFromPath`
// with different return types; a consumer that imports only `I18n.Kernel`
// must resolve the bare call to `I18n.Kernel`'s signature. Before D141 (the
// docs/01 §9.2 import-scoping enforcement, PR #7535) a bare call with no
// import rule installed picked the first-registered candidate whose params
// matched, which on the JVM bridge (unlike MSIL's per-package-first
// ordering at the time) put the never-imported sibling ahead of the
// directly-imported one, so `text` in `case Ok(text) -> …` bound to the
// wrong package's success type and a `val textStr: String = text` binding
// failed with T0060 on `--target jvm` alone.
// `checkWithImportedPackages` has no implicit prelude, so `Result` comes
// from a shared package. Without it both signatures would degrade to the
// error type and the binding below would type-check whichever function won
// (#7655); the control case proves the check can fail.
func resultPkgFor7458(): ImportedPackage {
  rulePkg("PkgRes7458", "package PkgRes7458\npub union Result[T, E] { case Ok(value: T); case Err(error: E) }\n")
}

func loadPathPackagesFor7458(): List[ImportedPackage] {
  val pkgRec = rulePkg(
    "PkgRecSibling",
    "package PkgRecSibling\nimport PkgRes7458\npub record Store { x: Int }\npub func loadPath(path: in String): Result[Store, String] { Ok(value = Store(x = 1)) }\n"
  )
  val pkgStr = rulePkg(
    "PkgStrDirect",
    "package PkgStrDirect\nimport PkgRes7458\npub func loadPath(path: in String): Result[String, String] { Ok(value = path) }\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(resultPkgFor7458())
  // `PkgRecSibling` registers FIRST — the never-imported sibling — so a
  // registration-order-dependent fallback (the pre-D141 bug) would pick it.
  packages.add(pkgRec)
  packages.add(pkgStr)
  packages
}

func loadPathConsumerFor7458(importPkg: in String): String {
  "package App\nimport PkgRes7458\nimport " + importPkg +
    "\nfunc f(path: in String): String {\n  match loadPath(path) {\n    case Ok(text) -> {\n      val textStr: String = text\n      textStr\n    }\n    case Err(_) -> \"\"\n  }\n}\n"
}

test "a same-named function declared only by a never-imported sibling package never wins (#7458)" {
  val cr = checkWithImportedPackages(parse(loadPathConsumerFor7458("PkgStrDirect")).file, loadPathPackagesFor7458())
  assertEqualInt(diagCount(cr), 0, "loadPath means PkgStrDirect's (the only import): no T0060 binding text to String")
}

test "control: importing the Store-returning package makes the same binding T0060 (#7458, #7655)" {
  val cr = checkWithImportedPackages(parse(loadPathConsumerFor7458("PkgRecSibling")).file, loadPathPackagesFor7458())
  assertTrue(hasDiagCode(cr, "T0060"), "text is a Store here, so binding it to String is T0060")
}

// #7579: the lowest tier that declares the name decides; a matching
// function reached only transitively does not answer for a direct import's
// mismatched one.
test "a bare call reports a mismatch against the direct import, not a transitive match" {
  val packages: List[ImportedPackage] = newList()
  packages.add(rulePkg("PkgPt", "package PkgPt\npub func parse(n: in Int): Int { n }\n"))
  packages.add(rulePkg("PkgPr", "package PkgPr\nimport PkgPt\npub func viaR(): Int { 1 }\n"))
  packages.add(rulePkg("PkgPd", "package PkgPd\npub func parse(s: in String): Int { 0 }\n"))
  val src = "package App\nimport PkgPr\nimport PkgPd\nfunc f(): Int { parse(5) }\n"
  assertTrue(
    diagCount(checkWithImportedPackages(parse(src).file, packages)) > 0,
    "parse(5) is checked against PkgPd.parse(String)"
  )
  val okSrc = "package App\nimport PkgPr\nimport PkgPd\nfunc f(): Int { parse(\"5\") }\n"
  assertEqualInt(diagCount(checkWithImportedPackages(parse(okSrc).file, packages)), 0, "parse(\"5\") is PkgPd's")
}

// #7564: `import P.{f as g}` makes `g` a bare name for `P.f`.  The
// pipeline runs `Lyric.AliasRewriter` before checking, which rewrites each
// use of `g` that no local hides to `P.f`; these tests do the same.
func checkRenamed(src: in String): CheckResult {
  checkWithImportedPackages(Lyric.AliasRewriter.rewriteFile(parse(src).file), importRulePackages())
}

test "a renamed selective import is usable under its new name only (#7564)" {
  assertEqualInt(
    diagCount(checkRenamed("package App\nimport PkgY.{fromY as g}\nfunc f(): Int { g() + 1 }\n")),
    0,
    "g() is PkgY.fromY()"
  )
  val cr = checkRenamed("package App\nimport PkgY.{fromY as g}\nfunc f(): Int { fromY() }\n")
  assertEqualInt(countDiagCode(cr, "T0020"), 1, "the original name is not visible bare")
}

test "a parameter or a later local named like the rename hides it only in its scope (#7564)" {
  val param = checkRenamed("package App\nimport PkgY.{fromY as g}\nfunc f(g: in Int): Int { g + 1 }\n")
  assertEqualInt(diagCount(param), 0, "the parameter g is an Int")
  val later = checkRenamed(
    "package App\nimport PkgY.{fromY as g}\nfunc f(): Int {\n  val a = g()\n  val g = 5\n  a + g\n}\n"
  )
  assertEqualInt(diagCount(later), 0, "g() before the local is the import; g after it is the local")
  val lambda = checkRenamed(
    "package App\nimport PkgY.{fromY as g}\nfunc f(): Int {\n  val h = { g: Int -> g * 2 }\n  h(g())\n}\n"
  )
  assertEqualInt(diagCount(lambda), 0, "the lambda's g is its parameter; the argument's g() is the import")
}

test "a renamed import that collides with another name is T0148 (#7564)" {
  val own = checkRenamed("package App\nimport PkgY.{fromY as g}\nfunc g(): Int { 1 }\n")
  assertEqualInt(countDiagCode(own, "T0148"), 1, "this package declares g")
  val twice = checkRenamed("package App\nimport PkgY.{fromY as otherY, otherY}\nfunc f(): Int { 1 }\n")
  assertEqualInt(countDiagCode(twice, "T0148"), 1, "otherY is also imported as itself")
  assertTrue(diagMessageFor(twice, "T0148").contains("choose another name"), diagMessageFor(twice, "T0148"))
}

// #7928: the alias rewriter reads `g.member` as a use of the rename `g`,
// so a rename sharing a package alias or a package path's head must be
// reported, never silently resolved to the renamed item.
test "a rename that is also a package alias or path head is T0148 (#7928)" {
  val alias = checkRenamed("package App\nimport PkgX as g\nimport PkgY.{fromY as g}\nfunc f(): Int { 1 }\n")
  assertEqualInt(countDiagCode(alias, "T0148"), 1, "g is also PkgX's alias")
  assertTrue(diagMessageFor(alias, "T0148").contains("alias of PkgX"), diagMessageFor(alias, "T0148"))
  val head = checkRenamed("package App\nimport PkgX\nimport PkgY.{fromY as PkgX}\nfunc f(): Int { 1 }\n")
  assertEqualInt(countDiagCode(head, "T0148"), 1, "PkgX also begins an imported package's path")
}

test "two renames to one name are both T0148 (#7928)" {
  val cr = checkRenamed("package App\nimport PkgY.{fromY as g, otherY as g}\nfunc f(): Int { 1 }\n")
  assertEqualInt(countDiagCode(cr, "T0148"), 2, "each rename is reported")
}

// #7929: the rewriter would send every bare `Circle` (constructions and
// pattern heads) to the renamed import, so a rename sharing this
// package's own case name is reported.
test "a rename that is a case of this package's union is T0148 (#7929)" {
  val src = "package App\nimport PkgY.{fromY as Circle}\nunion Shape {\n  case Circle(r: Int)\n  case Dot\n}\nfunc f(): Int { 1 }\n"
  val cr = checkRenamed(src)
  assertEqualInt(countDiagCode(cr, "T0148"), 1, "Circle is also Shape's case")
  assertTrue(diagMessageFor(cr, "T0148").contains("declares the case 'Circle'"), diagMessageFor(cr, "T0148"))
}

test "a rename that is a case of a selectively imported union is T0148 (#7967)" {
  val packages = importRulePackages()
  packages.add(rulePkg("PkgU", "package PkgU\npub union Shape {\n  case Dot\n  case Box(w: Int)\n}\n"))
  val src = "package App\nimport PkgU.{Shape}\nimport PkgY.{fromY as Box}\nfunc f(): Int { 1 }\n"
  val cr = checkWithImportedPackages(Lyric.AliasRewriter.rewriteFile(parse(src).file), packages)
  assertEqualInt(countDiagCode(cr, "T0148"), 1, "Box is also a case of the listed PkgU.Shape")
  assertTrue(diagMessageFor(cr, "T0148").contains("a case of PkgU.Shape"), diagMessageFor(cr, "T0148"))
}

test "a rename that is a case of a whole-imported union is T0148 (#7928)" {
  val packages = importRulePackages()
  packages.add(rulePkg("PkgU", "package PkgU\npub union Shape {\n  case Dot\n  case Box(w: Int)\n}\n"))
  val src = "package App\nimport PkgU\nimport PkgY.{fromY as Dot}\nfunc f(): Int { 1 }\n"
  val cr = checkWithImportedPackages(Lyric.AliasRewriter.rewriteFile(parse(src).file), packages)
  assertEqualInt(countDiagCode(cr, "T0148"), 1, "Dot is also PkgU.Shape's case")
}

// #7552: the `sigs` slots keep one function per name, first registered; when
// the import rule hides it, a bare reference takes the visible declaration,
// generic or of another arity, rather than typing against the hidden one.
test "a bare call types against the visible function, not a hidden first-registered one" {
  val packages: List[ImportedPackage] = newList()
  packages.add(
    rulePkg(
      "PkgHid",
      "package PkgHid\npub func pick(x: in Int): String { \"hidden\" }\npub func arity(x: in Int): Int { x }\n"
    )
  )
  packages.add(
    rulePkg(
      "PkgVis",
      "package PkgVis\npub func pick[T](x: in T): T { x }\npub func arity(x: in Int, y: in Int): Int { x + y }\n"
    )
  )
  val okSrc = "package App\nimport PkgHid as H\nimport PkgVis\nfunc f(): Int { pick(5) }\nfunc g(): Int { arity(1, 2) }\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(okSrc).file, packages)),
    0,
    "pick is PkgVis's generic, arity PkgVis's two-argument function"
  )
  val badSrc = "package App\nimport PkgHid as H\nimport PkgVis\nfunc f(): String { pick(5) }\n"
  assertTrue(
    diagCount(checkWithImportedPackages(parse(badSrc).file, packages)) > 0,
    "pick(5) is an Int through PkgVis, not PkgHid's String"
  )
  val aritySrc = "package App\nimport PkgHid as H\nimport PkgVis\nfunc g(): Int { arity(1) }\n"
  assertTrue(
    diagCount(checkWithImportedPackages(parse(aritySrc).file, packages)) > 0,
    "no visible one-argument arity: PkgHid's is hidden"
  )
}

// #7553: an alias target and a type-position name resolve only through what
// the file may name bare, and a qualified alias target in its own package.
test "type resolution fallbacks honour the import rule" {
  val packages: List[ImportedPackage] = newList()
  packages.add(rulePkg("PkgTa1", "package PkgTa1\npub record Thing {\n  a: Int\n}\n"))
  packages.add(rulePkg("PkgTb1", "package PkgTb1\npub record Thing {\n  b: Int\n}\n"))
  val hiddenSrc = "package App\nimport PkgTa1 as PA\nalias X = Thing\nfunc f(t: in X): Int { 1 }\n"
  assertTrue(
    hasDiagCode(checkWithImportedPackages(parse(hiddenSrc).file, packages), "T0010"),
    "alias X = Thing with Thing hidden behind an alias: T0010"
  )
  val qualSrc = "package App\nimport PkgTa1 as PA\nimport PkgTb1\nalias X = PkgTa1.Thing\nfunc f(t: in X): Int { t.a }\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(qualSrc).file, packages)),
    0,
    "alias X = PkgTa1.Thing is PkgTa1's Thing (field a), not the visible PkgTb1.Thing"
  )
  val clash: List[ImportedPackage] = newList()
  clash.add(rulePkg("PkgTok", "package PkgTok\npub union Tok {\n  case Token\n}\n"))
  clash.add(rulePkg("PkgRec", "package PkgRec\npub record Token {\n  n: Int\n}\n"))
  val clashSrc = "package App\nimport PkgTok\nimport PkgRec as R\nfunc f(t: in Token): Int { 1 }\n"
  val clashCr = checkWithImportedPackages(parse(clashSrc).file, clash)
  assertTrue(
    hasDiagCode(clashCr, "T0010") or hasDiagCode(clashCr, "T0013"),
    "Token in type position is PkgTok's case, not the hidden PkgRec.Token"
  )
}

// #7554: a selectively imported val's and record's own types are written in
// the declaring package's scope; the importing file need not list them.
test "a selectively imported val and record resolve their types in the declaring package" {
  val packages: List[ImportedPackage] = newList()
  packages.add(
    rulePkg(
      "PkgIn",
      "package PkgIn\npub record Inner {\n  n: Int\n}\npub record Rec {\n  field: Inner\n}\npub val defaultInner: Inner = Inner(n = 1)\npub func makeInner(): Inner { Inner(n = 2) }\npub val inferred = makeInner()\n"
    )
  )
  val okSrc = "package App\nimport PkgIn.{Rec, defaultInner, inferred}\nfunc f(r: in Rec): Int { r.field.n }\nfunc g(): Int { defaultInner.n + inferred.n }\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(parse(okSrc).file, packages)),
    0,
    "Inner and makeInner are PkgIn's own names"
  )
  val badSrc = "package App\nimport PkgIn.{Rec}\nfunc f(r: in Rec): String { r.field.n }\n"
  assertTrue(
    diagCount(checkWithImportedPackages(parse(badSrc).file, packages)) > 0,
    "r.field is a typed Inner, so returning its Int as a String is an error"
  )
}

// #7345: a dotted type-associated-function call (docs/49) on a type declared
// by a stdlib/ecosystem package the file never imports — `RestClient.create(
// "...")` with no `import Std.Rest` — used to type-check with no diagnostic
// at all and fail only at run time (MSIL: "unsupported method 'create' on
// the receiver type…"; JVM: `NoClassDefFoundError`).  `RestClient` resolves
// permissively (tier 3 of `symTableTryFindOne`, #6287) to the `Widget`-shaped
// symbol below regardless of import, and the checker's existing leniency for
// a bare uppercase call receiver (it is a type name, never a value; codegen
// owns the actual dispatch) discarded any diagnostic from that lookup. This
// pins the fix: the receiver names a real type, but one declared by a
// package that is not reachable from `App`'s own import closure, so it must
// be flagged (T0020) rather than silently deferred to codegen.
test "unimported stdlib-shaped type as call receiver is T0020 (#7345)" {
  val pkgRest = parse(
    "package PkgRest\npub opaque type Widget {\n  name: String\n}\npub func Widget.create(name: in String): Widget {\n  Widget(name = name)\n}\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgRest",
      items = pkgRest.file.items,
      imports = collectImportNames(pkgRest.file.imports),
      wholeImports = collectWholeImportNames(pkgRest.file.imports)
    )
  )
  val src = "package App\nfunc f(): Unit {\n  val w = Widget.create(\"x\")\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, packages)
  assertEqualInt(countDiagCode(cr, "T0020"), 1, "unimported Widget.create(...) is exactly one T0020")
  val msg = diagMessageFor(cr, "T0020")
  assertTrue(msg.contains("Widget"), "T0020 names the unresolved type: " + msg)
  assertTrue(msg.contains("PkgRest"), "T0020 names the declaring package: " + msg)
  assertTrue(msg.contains("import PkgRest"), "T0020 suggests the fix: " + msg)
}

// Control: once `App` imports `PkgRest`, the same call resolves cleanly —
// this fix is purely additive for the out-of-scope case above.
test "imported stdlib-shaped type as call receiver resolves cleanly (#7345)" {
  val pkgRest = parse(
    "package PkgRest\npub opaque type Widget {\n  name: String\n}\npub func Widget.create(name: in String): Widget {\n  Widget(name = name)\n}\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgRest",
      items = pkgRest.file.items,
      imports = collectImportNames(pkgRest.file.imports),
      wholeImports = collectWholeImportNames(pkgRest.file.imports)
    )
  )
  val src = "package App\nimport PkgRest\nfunc f(): Unit {\n  val w = Widget.create(\"x\")\n}\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, packages), "T0020"),
    0,
    "Widget.create(...) with `import PkgRest`: no T0020"
  )
}

// The kernel/host re-export idiom (#6287, mirrored above for a bare
// function name) must keep working for a type-receiver call too: a type
// declared only in a package reached TRANSITIVELY (through the directly
// imported package's own `import`) resolves without a diagnostic.
test "type receiver reachable only via a transitive import resolves cleanly (#7345)" {
  val pkgRest = parse(
    "package PkgRest\npub opaque type Widget {\n  name: String\n}\npub func Widget.create(name: in String): Widget {\n  Widget(name = name)\n}\n"
  )
  val pkgWrap = parse("package PkgWrap\nimport PkgRest\npub func wrapFn(): Int { 1 }\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgRest",
      items = pkgRest.file.items,
      imports = collectImportNames(pkgRest.file.imports),
      wholeImports = collectWholeImportNames(pkgRest.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "PkgWrap",
      items = pkgWrap.file.items,
      imports = collectImportNames(pkgWrap.file.imports),
      wholeImports = collectWholeImportNames(pkgWrap.file.imports)
    )
  )
  val src = "package App\nimport PkgWrap\nfunc f(): Unit {\n  val w = Widget.create(\"x\")\n}\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, packages), "T0020"),
    0,
    "Widget (PkgRest) resolves transitively through PkgWrap's own import of PkgRest"
  )
}

// A type declared in the SAME package as the call site needs no import.
test "same-package type as call receiver resolves cleanly (#7345)" {
  val src = "package App\npub opaque type Widget {\n  name: String\n}\npub func Widget.create(name: in String): Widget {\n  Widget(name = name)\n}\nfunc f(): Unit {\n  val w = Widget.create(\"x\")\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "Widget declared in the same package as its use: no diagnostic")
}

// #7495: the fully package-qualified spelling of the #7345 call —
// `Lib.Rest.Widget.create(...)` (a multi-segment package, like
// `Std.Rest.RestClient.create(...)`) with no `import Lib.Rest` — must be
// rejected the same way the bare-receiver form is (docs/01 §9.2: a package
// outside the file's import closure is not nameable, qualified or not).
// `Lyric.Pipeline` loads every stdlib package's signatures whatever the file
// imports, so the package is "known" to the checker; only reachability can
// tell the two apart.
func libRestPackages(): List[ImportedPackage] {
  val pkgRest = parse(
    "package Lib.Rest\npub opaque type Widget {\n  name: String\n}\npub func Widget.create(name: in String): Widget {\n  Widget(name = name)\n}\npub func ping(): Int { 1 }\n"
  )
  val pkgWrap = parse("package Lib.Wrap\nimport Lib.Rest\npub func wrapFn(): Int { 1 }\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Lib.Rest",
      items = pkgRest.file.items,
      imports = collectImportNames(pkgRest.file.imports),
      wholeImports = collectWholeImportNames(pkgRest.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "Lib.Wrap",
      items = pkgWrap.file.items,
      imports = collectImportNames(pkgWrap.file.imports),
      wholeImports = collectWholeImportNames(pkgWrap.file.imports)
    )
  )
  packages
}

test "unimported package-qualified type receiver is T0020 (#7495)" {
  val src = "package App\nfunc f(): Unit {\n  val w = Lib.Rest.Widget.create(\"x\")\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, libRestPackages())
  assertEqualInt(countDiagCode(cr, "T0020"), 1, "unimported Lib.Rest.Widget.create(...) is exactly one T0020")
  val msg = diagMessageFor(cr, "T0020")
  assertTrue(msg.contains("Lib.Rest.Widget"), "T0020 names the qualified reference: " + msg)
  assertTrue(msg.contains("import Lib.Rest"), "T0020 suggests the fix: " + msg)
}

test "unimported package-qualified function call is T0020 (#7495)" {
  val src = "package App\nfunc f(): Int {\n  Lib.Rest.ping()\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, libRestPackages())
  assertEqualInt(countDiagCode(cr, "T0020"), 1, "unimported Lib.Rest.ping() is exactly one T0020")
  assertTrue(diagMessageFor(cr, "T0020").contains("import Lib.Rest"), "T0020 suggests `import Lib.Rest`")
}

test "imported package-qualified references resolve cleanly (#7495)" {
  val src = "package App\nimport Lib.Rest\nfunc f(): Int {\n  val w = Lib.Rest.Widget.create(\"x\")\n  Lib.Rest.ping()\n}\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, libRestPackages()), "T0020"),
    0,
    "qualified references into an imported package: no T0020"
  )
}

test "package-qualified reference reachable only transitively resolves cleanly (#7495)" {
  val src = "package App\nimport Lib.Wrap\nfunc f(): Int {\n  val w = Lib.Rest.Widget.create(\"x\")\n  Lib.Rest.ping()\n}\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, libRestPackages()), "T0020"),
    0,
    "Lib.Rest is reachable through Lib.Wrap's own import (kernel/host idiom): no T0020"
  )
}

test "package-qualified Std.Core prelude reference needs no import (#7495)" {
  val pkgCore = parse("package Std.Core\npub func preludeFn(): Int { 7 }\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Std.Core",
      items = pkgCore.file.items,
      imports = collectImportNames(pkgCore.file.imports),
      wholeImports = collectWholeImportNames(pkgCore.file.imports)
    )
  )
  val src = "package App\nfunc f(): Int {\n  Std.Core.preludeFn()\n}\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, packages), "T0020"),
    0,
    "Std.Core is the implicit prelude: a qualified reference needs no import"
  )
}

test "local whose field chain spells a package name is not a package reference (#7495)" {
  val pkgRec = parse(
    "package Lib.Shape\npub record Inner {\n  pub Widget: Int\n}\npub record Outer {\n  pub Rest: Inner\n}\n"
  )
  val packages = libRestPackages()
  packages.add(
    ImportedPackage(
      name = "Lib.Shape",
      items = pkgRec.file.items,
      imports = collectImportNames(pkgRec.file.imports),
      wholeImports = collectWholeImportNames(pkgRec.file.imports)
    )
  )
  val src = "package App\nimport Lib.Shape\nfunc f(o: in Outer): Int {\n  val Lib = o\n  Lib.Rest.Widget\n}\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, packages), "T0020"),
    0,
    "a local named `Lib` wins over the unimported package `Lib.Rest`"
  )
}

// The same checks for a three-segment package (`Lib.Net.Rest`): nothing in
// them depends on the package path's length, and these pin that down.
func libNetRestPackages(): List[ImportedPackage] {
  val pkgRest = parse(
    "package Lib.Net.Rest\npub opaque type Widget {\n  name: String\n}\npub func Widget.create(name: in String): Widget {\n  Widget(name = name)\n}\npub func ping(): Int { 1 }\n"
  )
  val pkgPriv = parse(
    "package Lib.Net.Priv\nopaque type Gadget {\n  name: String\n}\npub func Gadget.create(name: in String): Gadget {\n  Gadget(name = name)\n}\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Lib.Net.Rest",
      items = pkgRest.file.items,
      imports = collectImportNames(pkgRest.file.imports),
      wholeImports = collectWholeImportNames(pkgRest.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "Lib.Net.Priv",
      items = pkgPriv.file.items,
      imports = collectImportNames(pkgPriv.file.imports),
      wholeImports = collectWholeImportNames(pkgPriv.file.imports)
    )
  )
  packages
}

test "unimported three-segment package-qualified references are T0020 (#7495)" {
  val src = "package App\nfunc f(): Int {\n  val w = Lib.Net.Rest.Widget.create(\"x\")\n  Lib.Net.Rest.ping()\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, libNetRestPackages())
  assertEqualInt(countDiagCode(cr, "T0020"), 2, "each unimported Lib.Net.Rest reference is one T0020")
  assertTrue(diagMessageFor(cr, "T0020").contains("import Lib.Net.Rest"), "T0020 suggests `import Lib.Net.Rest`")
}

test "imported three-segment package-qualified references resolve cleanly (#7495)" {
  val src = "package App\nimport Lib.Net.Rest\nfunc f(): Int {\n  val w = Lib.Net.Rest.Widget.create(\"x\")\n  Lib.Net.Rest.ping()\n}\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, libNetRestPackages()), "T0020"),
    0,
    "raw AST: no T0020"
  )
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(rewriteFile(parse(src).file), libNetRestPackages()), "T0020"),
    0,
    "alias-rewritten: no T0020"
  )
}

test "three-segment package-qualified private type receiver is T0097 (#7499)" {
  val src = "package App\nimport Lib.Net.Priv\nfunc f(): Unit {\n  val g = Lib.Net.Priv.Gadget.create(\"x\")\n}\n"
  val raw = checkWithImportedPackages(parse(src).file, libNetRestPackages())
  assertEqualInt(countDiagCode(raw, "T0097"), 1, "raw AST: exactly one T0097")
  assertEqualInt(countDiagCode(raw, "T0020"), 0, "raw AST: not T0020")
  val rewritten = checkWithImportedPackages(rewriteFile(parse(src).file), libNetRestPackages())
  assertEqualInt(countDiagCode(rewritten, "T0097"), 1, "alias-rewritten: exactly one T0097")
}

// #7499: a `pub func Widget.create(...)` on a package-private `Widget` is not
// callable from another package: the receiver type is not nameable there, so
// the call is T0097 (adding an import cannot fix it), never T0020.
func privateWidgetPackages(): List[ImportedPackage] {
  val pkgPriv = parse(
    "package PkgPriv\nopaque type Widget {\n  name: String\n}\npub func Widget.create(name: in String): Widget {\n  Widget(name = name)\n}\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgPriv",
      items = pkgPriv.file.items,
      imports = collectImportNames(pkgPriv.file.imports),
      wholeImports = collectWholeImportNames(pkgPriv.file.imports)
    )
  )
  packages
}

test "package-private type receiver from an importing package is T0097 (#7499)" {
  val src = "package App\nimport PkgPriv\nfunc f(): Unit {\n  val w = Widget.create(\"x\")\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, privateWidgetPackages())
  assertEqualInt(countDiagCode(cr, "T0097"), 1, "private Widget.create(...) across packages is exactly one T0097")
  assertEqualInt(countDiagCode(cr, "T0020"), 0, "not T0020: an import cannot fix a private type")
  assertTrue(diagMessageFor(cr, "T0097").contains("Widget"), "T0097 names the private type")
}

test "package-private type receiver without the import is still T0097 (#7499)" {
  val src = "package App\nfunc f(): Unit {\n  val w = Widget.create(\"x\")\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, privateWidgetPackages())
  assertEqualInt(countDiagCode(cr, "T0097"), 1, "private Widget.create(...), unimported: T0097")
  assertEqualInt(countDiagCode(cr, "T0020"), 0, "unimported private type: T0097 wins over T0020")
}

test "package-qualified private type receiver is T0097 (#7499)" {
  val src = "package App\nimport PkgPriv\nfunc f(): Unit {\n  val w = PkgPriv.Widget.create(\"x\")\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, privateWidgetPackages())
  assertEqualInt(countDiagCode(cr, "T0097"), 1, "PkgPriv.Widget.create(...) across packages is exactly one T0097")
}

// The real pipeline runs `Lyric.AliasRewriter` first, which collapses an
// imported package's qualified receiver into a flat `EPath` — the
// `resolveExprPath` route rather than the un-collapsed `EMember` chain.
test "alias-rewritten qualified private type receiver is T0097 (#7499)" {
  val src = "package App\nimport PkgPriv\nfunc f(): Unit {\n  val w = PkgPriv.Widget.create(\"x\")\n}\n"
  val cr = checkWithImportedPackages(rewriteFile(parse(src).file), privateWidgetPackages())
  assertEqualInt(countDiagCode(cr, "T0097"), 1, "rewritten PkgPriv.Widget.create(...) is exactly one T0097")
}

test "alias-rewritten imported qualified reference resolves cleanly (#7495)" {
  val src = "package App\nimport Lib.Rest\nfunc f(): Int {\n  val w = Lib.Rest.Widget.create(\"x\")\n  Lib.Rest.ping()\n}\n"
  val cr = checkWithImportedPackages(rewriteFile(parse(src).file), libRestPackages())
  assertEqualInt(countDiagCode(cr, "T0020"), 0, "rewritten qualified references into an imported package: no T0020")
}

test "same-package private type receiver resolves cleanly (#7499)" {
  val src = "package App\nopaque type Widget {\n  name: String\n}\npub func Widget.create(name: in String): Widget {\n  Widget(name = name)\n}\nfunc f(): Unit {\n  val w = Widget.create(\"x\")\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "a private type used inside its own package: no diagnostic")
}

// #7548: the #7495/#7499 rules (qualified references need a reachable
// import; a package-private type is T0097 regardless) apply to TYPE
// POSITION the same way they already apply to a qualified expression path
// — a parameter/field/return type, not just a call receiver.
test "unimported package-qualified type in param position is T0020 (#7548)" {
  val src = "package App\nfunc f(w: in Lib.Rest.Widget): Unit {}\n"
  val cr = checkWithImportedPackages(parse(src).file, libRestPackages())
  assertEqualInt(countDiagCode(cr, "T0020"), 1, "unimported Lib.Rest.Widget param type is exactly one T0020")
  val msg = diagMessageFor(cr, "T0020")
  assertTrue(msg.contains("Lib.Rest.Widget"), "T0020 names the qualified type: " + msg)
  assertTrue(msg.contains("import Lib.Rest"), "T0020 suggests the fix: " + msg)
}

test "unimported package-qualified type in return position is T0020 (#7548)" {
  val src = "package App\nfunc f(): Lib.Rest.Widget { panic(\"unreachable\") }\n"
  val cr = checkWithImportedPackages(parse(src).file, libRestPackages())
  assertEqualInt(countDiagCode(cr, "T0020"), 1, "unimported Lib.Rest.Widget return type is exactly one T0020")
}

test "unimported package-qualified type as a generic type argument is T0020 (#7548)" {
  val src = "package App\nfunc f(xs: in List[Lib.Rest.Widget]): Unit {}\n"
  val cr = checkWithImportedPackages(parse(src).file, libRestPackages())
  assertEqualInt(countDiagCode(cr, "T0020"), 1, "unimported Lib.Rest.Widget generic arg is exactly one T0020")
}

test "imported package-qualified type position resolves cleanly (#7548)" {
  val src = "package App\nimport Lib.Rest\nfunc f(w: in Lib.Rest.Widget): Lib.Rest.Widget { w }\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, libRestPackages()), "T0020"),
    0,
    "qualified type position into an imported package: no T0020"
  )
}

test "package-qualified type position reachable only transitively resolves cleanly (#7548)" {
  val src = "package App\nimport Lib.Wrap\nfunc f(w: in Lib.Rest.Widget): Unit {}\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, libRestPackages()), "T0020"),
    0,
    "Lib.Rest is reachable through Lib.Wrap's own import (kernel/host idiom): no T0020"
  )
}

test "package-qualified Std.Core type position needs no import (#7548)" {
  val pkgCore = parse("package Std.Core\npub record Thing {\n  x: Int\n}\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Std.Core",
      items = pkgCore.file.items,
      imports = collectImportNames(pkgCore.file.imports),
      wholeImports = collectWholeImportNames(pkgCore.file.imports)
    )
  )
  val src = "package App\nfunc f(t: in Std.Core.Thing): Unit {}\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, packages), "T0020"),
    0,
    "Std.Core is the implicit prelude in type position too: no T0020"
  )
}

test "unimported three-segment package-qualified type position is T0020 (#7548)" {
  val src = "package App\nfunc f(w: in Lib.Net.Rest.Widget): Unit {}\n"
  val cr = checkWithImportedPackages(parse(src).file, libNetRestPackages())
  assertEqualInt(countDiagCode(cr, "T0020"), 1, "unimported Lib.Net.Rest.Widget type position is exactly one T0020")
  assertTrue(diagMessageFor(cr, "T0020").contains("import Lib.Net.Rest"), "T0020 suggests `import Lib.Net.Rest`")
}

test "imported three-segment package-qualified type position resolves cleanly (#7548)" {
  val src = "package App\nimport Lib.Net.Rest\nfunc f(w: in Lib.Net.Rest.Widget): Unit {}\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, libNetRestPackages()), "T0020"),
    0,
    "imported three-segment type position: no T0020"
  )
}

// A package-private type used in type position is T0097 (never T0020),
// whether or not its declaring package is imported — mirroring the
// call-receiver rule (#7499) but for a plain type reference. This also
// pins that the checker does not DOUBLE-report: `symbolToType` already
// calls `checkImportedVisibility` for every type this path resolves to.
test "package-qualified private type in type position is exactly one T0097 (#7548)" {
  val src = "package App\nimport PkgPriv\nfunc f(w: in PkgPriv.Widget): Unit {}\n"
  val cr = checkWithImportedPackages(parse(src).file, privateWidgetPackages())
  assertEqualInt(countDiagCode(cr, "T0097"), 1, "PkgPriv.Widget in type position is exactly one T0097")
  assertEqualInt(countDiagCode(cr, "T0020"), 0, "not T0020: an import cannot fix a private type")
}

test "package-qualified private type in type position without the import is still T0097 (#7548)" {
  val src = "package App\nfunc f(w: in PkgPriv.Widget): Unit {}\n"
  val cr = checkWithImportedPackages(parse(src).file, privateWidgetPackages())
  assertEqualInt(countDiagCode(cr, "T0097"), 1, "unimported PkgPriv.Widget in type position: T0097")
  assertEqualInt(countDiagCode(cr, "T0020"), 0, "unimported private type in type position: T0097 wins over T0020")
}

test "same-package type position resolves cleanly (#7548)" {
  val src = "package App\nopaque type Widget {\n  name: String\n}\nfunc f(w: in Widget): Unit {}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "a private type used in its own package's type position: no diagnostic")
}

// #7548: the same rules for PATTERN HEADS — `unionCaseSymbolForScrutinee`'s
// tier A/B qualifier check (#6287 Phase B) validates a qualified pattern
// head STRUCTURALLY against the scrutinee's own union, but `Lyric.Pipeline`
// preloads every stdlib package's signatures whatever the file imports
// (D-progress-1011), so a structural match alone doesn't mean the union's
// own package is reachable. A realistic program can't get a scrutinee of an
// unreachable type without ALSO naming that package somewhere reachable
// (typing the parameter/return that produces it) — so a qualified,
// unimported pattern head fires T0020 both there and in the pattern itself,
// which this pins down as a combined regression (unlike the type-position
// tests above, which isolate a single T0020).
func libRestKindPackages(): List[ImportedPackage] {
  val pkgRest = parse("package Lib.Rest\npub union Kind {\n  case A(x: Int)\n  case B\n}\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Lib.Rest",
      items = pkgRest.file.items,
      imports = collectImportNames(pkgRest.file.imports),
      wholeImports = collectWholeImportNames(pkgRest.file.imports)
    )
  )
  packages
}

test "unimported package-qualified pattern head is T0020 (#7548)" {
  val src = "package App\nfunc f(k: in Lib.Rest.Kind): Int {\n  match k {\n    case Lib.Rest.Kind.A(x) -> x\n    case _ -> 0\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, libRestKindPackages())
  assertTrue(countDiagCode(cr, "T0020") >= 1, "unimported Lib.Rest.Kind.A pattern head fires T0020")
  val msg = diagMessageFor(cr, "T0020")
  assertTrue(msg.contains("Lib.Rest"), "T0020 names the unreachable package: " + msg)
  assertTrue(msg.contains("import Lib.Rest"), "T0020 suggests the fix: " + msg)
}

test "imported package-qualified pattern head resolves cleanly (#7548)" {
  val src = "package App\nimport Lib.Rest\nfunc f(k: in Lib.Rest.Kind): Int {\n  match k {\n    case Lib.Rest.Kind.A(x) -> x\n    case _ -> 0\n  }\n}\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, libRestKindPackages()), "T0020"),
    0,
    "imported package-qualified pattern head: no T0020"
  )
}

// The isolated pattern-only counterpart: a `pub` wrapper function CAN
// legally return a package-private type with no diagnostic at its own
// declaration OR at a bare (unqualified) call site — visibility is
// enforced at the use site that NAMES the type (docs/01 §3.1) — so
// matching that call's result with an explicitly-qualified pattern head is
// the first point a private union's case gets named, and is where T0097
// must fire.
func privateKindPackages(): List[ImportedPackage] {
  val pkgPriv = parse(
    "package PkgPriv\nunion Kind {\n  case A(x: Int)\n  case B\n}\npub func mkKind(): Kind {\n  Kind.A(x = 1)\n}\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgPriv",
      items = pkgPriv.file.items,
      imports = collectImportNames(pkgPriv.file.imports),
      wholeImports = collectWholeImportNames(pkgPriv.file.imports)
    )
  )
  packages
}

test "package-private union case in a qualified pattern head is T0097 (#7548)" {
  val src = "package App\nimport PkgPriv\nfunc f(): Int {\n  match mkKind() {\n    case PkgPriv.Kind.A(x) -> x\n    case _ -> 0\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, privateKindPackages())
  assertEqualInt(countDiagCode(cr, "T0097"), 1, "PkgPriv.Kind.A(...) pattern head is exactly one T0097")
  assertEqualInt(countDiagCode(cr, "T0020"), 0, "not T0020: an import cannot fix a private type's case")
  assertTrue(
    diagMessageFor(cr, "T0097").contains("'A'"),
    "T0097 names the private union's case: " + diagMessageFor(cr, "T0097")
  )
}

// #6700 regression guard: the unresolvable-scrutinee fallback (an unknown
// scrutinee, so tier A/B above never runs at all) must still not fire a
// spurious diagnostic from this new check — it is entered only from inside
// the tier A/B success branches.
test "qualified pattern head against an unresolvable scrutinee has no T0020 for the pattern (#7548)" {
  // `undefinedScrutinee` is itself an unknown identifier and fires its OWN
  // (unrelated) T0020 — the point of this test is that the PATTERN doesn't
  // ALSO fire one for `Lib.Rest`, since it never reaches the tier A/B
  // branches this new check lives in.
  val src = "package App\nfunc f(): Int {\n  match undefinedScrutinee {\n    case Lib.Rest.Kind.A(x) -> x\n    case _ -> 0\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, libRestKindPackages())
  var sawPkgDiag = false
  var i = 0
  while i < cr.diagnostics.count {
    if cr.diagnostics[i].code == "T0020" and cr.diagnostics[i].message.contains("Lib.Rest") {
      sawPkgDiag = true
    }
    i = i + 1
  }
  assertTrue(not sawPkgDiag, "an unresolvable scrutinee never reaches the tier A/B branches this check lives in")
}

// #6700: `unionCaseSymbolForScrutinee`'s fallback (reached when the scrutinee
// type doesn't resolve — here, an unknown identifier types as `TyError`, so
// the DKUnionCase/DKEnumCase scrutinee-based tiers above never fire) must NOT
// treat an already-QUALIFIED pattern head as bare.  `pat2fnExpr` always wraps
// the pattern head as a flat `EPath` regardless of segment count, so before
// this fix the fallback took ONLY the last segment of `PkgA.Ping` (discarding
// the `PkgA` qualifier) and ran it through `checkBareNameAmbiguity`, firing a
// nonsensical T0123 ("'Ping' is ambiguous … qualify the reference, e.g.
// 'PkgA.Ping'") even though the pattern was already qualified exactly that
// way.  A qualified head must fall through unchecked here.
test "qualified pattern head against an unresolvable scrutinee is not T0123 (#6700)" {
  val pkgA = parse("package PkgA\npub union Signal {\n  case Ping(code: Int)\n  case Halt\n}\n")
  val pkgB = parse("package PkgB\npub union Signal {\n  case Ping(label: String)\n  case Halt\n}\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgA",
      items = pkgA.file.items,
      imports = collectImportNames(pkgA.file.imports),
      wholeImports = collectWholeImportNames(pkgA.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "PkgB",
      items = pkgB.file.items,
      imports = collectImportNames(pkgB.file.imports),
      wholeImports = collectWholeImportNames(pkgB.file.imports)
    )
  )
  val src = "package App\nimport PkgA\nimport PkgB\nfunc f(): Int {\n  match undefinedScrutinee {\n    case PkgA.Ping(n) -> n\n    case _ -> 0\n  }\n}\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, packages), "T0123"),
    0,
    "PkgA.Ping is already qualified — falling through to the unresolvable-scrutinee fallback must not fire T0123 for 'Ping'"
  )
}

// #6838: constructing a union by its TYPE NAME (`DbError(message = "…")`)
// rather than through one of its cases has no constructor. The type checker
// used to accept it silently (the callee `DbError` types as `TyError`, and the
// ECall fallback's `case TyError -> TyError` arm swallowed the call with no
// diagnostic), leaving codegen to either miscompile it to a bogus
// `(DbError)(object)<arg>` conversion (≤0.5.0) or panic with a baffling T0123
// "no function token" at emit time (≥0.6.x, once codegen stopped papering over
// unresolved callees). It is now a clear, early T0125 type error.
test "constructing a union by its type name is a T0125 error (#6838)" {
  val src = "package P\nunion DbError {\n  case OpenFailed(message: String)\n  case ExecFailed(sql: String, message: String)\n}\nfunc f(): DbError { DbError(message = \"x\") }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0125"), "union-by-type-name construction fires T0125")
  assertEqualInt(countDiagCode(cr, "T0123"), 0, "and never the codegen-level T0123")
  val m = diagMessageFor(cr, "T0125")
  assertTrue(Str.contains(m, "OpenFailed"), "T0125 lists the constructible cases: " + m)
  assertTrue(Str.contains(m, "ExecFailed"), "T0125 lists every case: " + m)
}

// The exact #6838 shape: a QUALIFIED, cross-package union-type-name construction
// (`Pkg.DbError(message = "…")`) — the form the cloud-agents project hit at
// scale. Must be the same clear T0125, never the T0123 codegen panic.
test "constructing a qualified cross-package union by its type name is T0125, not T0123 (#6838)" {
  val lib = parse(
    "package Lib\npub union DbError {\n  case OpenFailed(message: String)\n  case ExecFailed(sql: String, message: String)\n}\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Lib",
      items = lib.file.items,
      imports = collectImportNames(lib.file.imports),
      wholeImports = collectWholeImportNames(lib.file.imports)
    )
  )
  val src = "package App\nimport Lib\nfunc f(): Lib.DbError { Lib.DbError(message = \"x\") }\n"
  val cr = checkWithImportedPackages(parse(src).file, packages)
  assertTrue(hasDiagCode(cr, "T0125"), "qualified union-by-type-name construction fires T0125")
  assertEqualInt(countDiagCode(cr, "T0123"), 0, "and never the codegen-level T0123 panic")
}

// Regression guard: constructing an actual union CASE (the correct spelling)
// stays clean — the new T0125 arm runs only after `unionCaseSymbolOf` misses.
test "constructing a real union case is still clean (#6838 guard)" {
  val src = "package P\nunion DbError {\n  case OpenFailed(message: String)\n  case ExecFailed(sql: String, message: String)\n}\nfunc f(): DbError { OpenFailed(message = \"x\") }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "OpenFailed(message = …) is a valid case construction")
}

// The same guard extends to enums: constructing an enum by its type name is
// T0125 too (an enum value is a case, not the type).
test "constructing an enum by its type name is a T0125 error (#6838)" {
  val src = "package P\nenum Color {\n  case Red\n  case Green\n}\nfunc f(): Color { Color(x = 1) }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0125"), "enum-by-type-name construction fires T0125")
}

// ─────────────────────────────────────────────────────────────────────────────
// Record `.copy(field = value)` (docs/01 §2.4): named field arguments only
// (T0127), each a real field (T0101) given at most once (T0127), with a value
// assignable to the field (T0104, as for a constructor argument).  A valid copy has the receiver's type.
// ─────────────────────────────────────────────────────────────────────────────
test "record copy type-checks and has the receiver's type" {
  val src = "package P\nrecord Pt { x: Int; y: Int }\nfunc f(p: in Pt): Pt { p.copy(x = 1) }\n"
  val cr = parseCheck(src)
  assertTrue(cr.diagnostics.count == 0, "valid copy: no diagnostics")
}

test "record copy rejects positional arguments with T0127" {
  val src = "package P\nrecord Pt { x: Int; y: Int }\nfunc f(p: in Pt): Pt { p.copy(1) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0127"), "positional copy argument: T0127")
}

test "record copy rejects an unknown field with T0101" {
  val src = "package P\nrecord Pt { x: Int; y: Int }\nfunc f(p: in Pt): Pt { p.copy(z = 1) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0101"), "unknown copy field: T0101")
}

test "record copy rejects a repeated field with T0127" {
  val src = "package P\nrecord Pt { x: Int; y: Int }\nfunc f(p: in Pt): Pt { p.copy(x = 1, x = 2) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0127"), "repeated copy field: T0127")
}

test "record copy rejects a mistyped value with T0104" {
  val src = "package P\nrecord Pt { x: Int; y: Int }\nfunc f(p: in Pt): Pt { p.copy(x = \"one\") }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0104"), "mistyped copy value: T0104")
}

test "a user-declared copy method takes precedence over record copy" {
  val src = "package P\nrecord Pt {\n  x: Int\n  func copy(self: in Pt, n: in Int): Int { n }\n}\nfunc f(p: in Pt): Int { p.copy(3) }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0127"), "user copy method: no T0127")
}

// ─────────────────────────────────────────────────────────────────────────────
// A generic record constructor whose field initializers leave a type parameter
// unbound takes it from an expected instantiation of the same record (a
// binding annotation), as union-case constructors already did.
// ─────────────────────────────────────────────────────────────────────────────
test "generic record constructor infers a type parameter from the binding annotation" {
  val src = "package P\nrecord Box[A, B] { left: List[A]; right: Option[B] }\nfunc f(xs: in List[Int]): Unit { val _b: Box[Int, String] = Box(left = xs, right = None) }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0110"), "expected type fills B: no T0110")
}

// A qualified function value whose qualifier matches several packages
// (`Lib.Bar`, `Other.Bar`) binds the imported one rather than reporting an
// overload ambiguity (D-progress-963).
test "qualified function value prefers the imported package among same-suffix packages" {
  val libBar = parse("package Lib.Bar\npub func parse(s: in String): Int { 1 }\n")
  val otherBar = parse("package Other.Bar\npub func parse(s: in String): Int { 2 }\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Lib.Bar",
      items = libBar.file.items,
      imports = collectImportNames(libBar.file.imports),
      wholeImports = collectWholeImportNames(libBar.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "Other.Bar",
      items = otherBar.file.items,
      imports = collectImportNames(otherBar.file.imports),
      wholeImports = collectWholeImportNames(otherBar.file.imports)
    )
  )
  val src = "package App\nimport Lib.Bar\nfunc g(): Int {\n  val f: (String) -> Int = Bar.parse\n  f(\"x\")\n}\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(rewriteFile(parse(src).file), packages)),
    0,
    "Bar.parse binds Lib.Bar.parse, the imported package"
  )
  val bad = "package App\nimport Lib.Bar\nfunc g(): Unit {\n  val f: String = Bar.parse\n}\n"
  assertTrue(
    diagCount(checkWithImportedPackages(rewriteFile(parse(bad).file), packages)) > 0,
    "the qualified value is resolved: a mismatched annotation is reported"
  )
}

// A call through a function value carries out each widening with a
// conversion method (D-progress-964): `.toULong()` for a widening to `ULong`
// (#7805), `.toUInt()` to `UInt` (#7812), and `.toDouble()` for a `Float`
// argument to a `Double` parameter (D155; before that, `Float` had no
// conversion methods and the call was T0043).
test "function-value call converts unsigned and Float widenings" {
  val okU = "package P\npub func g(f: (UInt) -> UInt, b: in Byte): UInt {\n  f(b)\n}\n"
  assertEqualInt(diagCount(parseCheck(okU)), 0, "Byte into a (UInt) -> UInt value widens")
  val okL = "package P\npub func g(f: (ULong) -> ULong, b: in Byte, u: in UInt): ULong {\n  f(b) + f(u)\n}\n"
  assertEqualInt(diagCount(parseCheck(okL)), 0, "Byte and UInt into a (ULong) -> ULong value widen")
  val okF = "package P\npub func g(f: (Double) -> Double, x: in Float): Double {\n  f(x)\n}\n"
  assertEqualInt(diagCount(parseCheck(okF)), 0, "Float into a (Double) -> Double value widens")
  val ok = "package P\npub func g(f: (Long) -> Long, i: in Int): Long {\n  f(i)\n}\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "Int into a (Long) -> Long value still widens")
}

// A function value can stand only for another package's non-generic,
// synchronous function whose parameters are all `in`; anything else is T0128
// instead of reaching the backend as a bare path (D-progress-963).
test "a function value naming an unrepresentable cross-package function is T0128" {
  val lib = parse(
    "package Lib\npub func bump(n: inout Int): Unit { n = n + 1 }\npub async func fetch(s: in String): Int { 1 }\npub func ident[T](x: in T): T { x }\npub func plain(s: in String): Int { 2 }\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Lib",
      items = lib.file.items,
      imports = collectImportNames(lib.file.imports),
      wholeImports = collectWholeImportNames(lib.file.imports)
    )
  )
  val inoutSrc = "package App\nimport Lib\nfunc g(): Unit {\n  val f = Lib.bump\n}\n"
  assertTrue(
    hasDiagCode(checkWithImportedPackages(rewriteFile(parse(inoutSrc).file), packages), "T0128"),
    "inout parameter: T0128"
  )
  val asyncSrc = "package App\nimport Lib\nfunc g(): Unit {\n  val f = Lib.fetch\n}\n"
  assertTrue(
    hasDiagCode(checkWithImportedPackages(rewriteFile(parse(asyncSrc).file), packages), "T0128"),
    "async function: T0128"
  )
  val genSrc = "package App\nimport Lib\nfunc g(): Unit {\n  val f = Lib.ident\n}\n"
  assertTrue(
    hasDiagCode(checkWithImportedPackages(rewriteFile(parse(genSrc).file), packages), "T0128"),
    "generic function: T0128"
  )
  val bareSrc = "package App\nimport Lib.{bump}\nfunc g(): Unit {\n  val f = bump\n}\n"
  assertTrue(
    hasDiagCode(checkWithImportedPackages(rewriteFile(parse(bareSrc).file), packages), "T0128"),
    "bare inout reference: T0128"
  )
  val okSrc = "package App\nimport Lib\nfunc g(): Int {\n  val f: (String) -> Int = Lib.plain\n  f(\"x\")\n}\n"
  assertEqualInt(
    diagCount(checkWithImportedPackages(rewriteFile(parse(okSrc).file), packages)),
    0,
    "plain function value: no diagnostic"
  )
  // A call with explicit type arguments is a call, not a function value.
  val tyAppSrc = "package App\nimport Lib\nfunc g(): Int {\n  Lib.ident[Int](3)\n}\n"
  assertTrue(
    not hasDiagCode(checkWithImportedPackages(rewriteFile(parse(tyAppSrc).file), packages), "T0128"),
    "qualified generic call with type arguments: no T0128"
  )
  val bareTyAppSrc = "package App\nimport Lib.{ident}\nfunc g(): Int {\n  ident[Int](3)\n}\n"
  assertTrue(
    not hasDiagCode(checkWithImportedPackages(rewriteFile(parse(bareTyAppSrc).file), packages), "T0128"),
    "bare generic call with type arguments: no T0128"
  )
  // Control: the qualified path is really resolved, so a mismatched
  // annotation is reported and the zero-diagnostic case is not vacuous.
  val badSrc = "package App\nimport Lib\nfunc g(): Unit {\n  val f: String = Lib.plain\n}\n"
  assertTrue(
    diagCount(checkWithImportedPackages(rewriteFile(parse(badSrc).file), packages)) > 0,
    "mismatched annotation on a qualified function value is reported"
  )
}

// A function value naming an overloaded package function cannot pick an
// overload: T0123, bare and qualified (D-progress-963). The declaration order
// puts the two-parameter overload first so a silent pick of either overload
// would not type-check the annotation by accident.
test "overloaded function value is T0123, bare and qualified" {
  val other = parse(
    "package Ovl.Other\npub func pad(s: in String, n: in Int): String { s }\npub func pad(s: in String): String { s }\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Ovl.Other",
      items = other.file.items,
      imports = collectImportNames(other.file.imports),
      wholeImports = collectWholeImportNames(other.file.imports)
    )
  )
  val bareSrc = "package Ovl.App\nimport Ovl.Other.{pad}\nfunc g(): Unit {\n  val f: (String) -> String = pad\n}\n"
  assertTrue(
    hasDiagCode(checkWithImportedPackages(rewriteFile(parse(bareSrc).file), packages), "T0123"),
    "bare overloaded function value: T0123"
  )
  val qualSrc = "package Ovl.App\nimport Ovl.Other\nfunc g(): Unit {\n  val f: (String) -> String = Other.pad\n}\n"
  assertTrue(
    hasDiagCode(checkWithImportedPackages(rewriteFile(parse(qualSrc).file), packages), "T0123"),
    "qualified overloaded function value: T0123"
  )
}

// The forwarding lambda names a parameter type by its bare name only when
// that name denotes the same type at the use site (#7371). An extern type
// (codegen resolves it by bare name) whose name the consumer reuses has no
// faithful spelling: T0128. Without the clash the bare name is used.
test "a function value over an extern type whose name the use site reuses is T0128" {
  val host = parse("package Std.UuidHost\nextern type Uuid = \"System.Guid\"\n")
  val lib = parse("package Lib\nimport Std.UuidHost\npub func show(u: in Uuid): String { \"\" }\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Std.UuidHost",
      items = host.file.items,
      imports = collectImportNames(host.file.imports),
      wholeImports = collectWholeImportNames(host.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "Lib",
      items = lib.file.items,
      imports = collectImportNames(lib.file.imports),
      wholeImports = collectWholeImportNames(lib.file.imports)
    )
  )
  val clash = "package App\nimport Lib\nrecord Uuid {\n  n: Int\n}\nfunc g(): Unit {\n  val f = Lib.show\n}\n"
  assertTrue(
    hasDiagCode(checkWithImportedPackages(rewriteFile(parse(clash).file), packages), "T0128"),
    "extern parameter type shadowed at the use site: T0128"
  )
  val plain = "package App\nimport Lib\nfunc g(): Unit {\n  val f = Lib.show\n}\n"
  assertTrue(
    not hasDiagCode(checkWithImportedPackages(rewriteFile(parse(plain).file), packages), "T0128"),
    "no clash: the bare extern name is used"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// A union- or enum-case pattern must belong to the scrutinee's own type
// (T0129).  `case Some(i)` against an `Int`, or `case Ok(v)` against an
// `Option`, used to type-check and then silently miscompile.
// ─────────────────────────────────────────────────────────────────────────────
test "a union-case pattern against a primitive scrutinee is T0129" {
  val src = "package P\nunion U { case A(n: Int); case B }\nfunc f(n: in Int): Int { match n { case A(k) -> k; case _ -> 0 } }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0129"), "A(k) against Int: T0129")
}

test "a bare nullary case pattern against a primitive scrutinee is T0129" {
  val src = "package P\nunion U { case A(n: Int); case B }\nfunc f(n: in Int): Int { match n { case B -> 1; case _ -> 0 } }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0129"), "B against Int: T0129")
}

test "a case of another union against a union scrutinee is T0129" {
  val src = "package P\nunion U { case A(n: Int); case B }\nunion V { case C(n: Int); case D }\nfunc f(u: in U): Int { match u { case C(k) -> k; case _ -> 0 } }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0129"), "C(k) against U: T0129")
}

test "a case of the scrutinee's own union is not T0129" {
  val src = "package P\nunion U { case A(n: Int); case B }\nfunc f(u: in U): Int { match u { case A(k) -> k; case B -> 0 } }\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0129"), "own cases: no T0129")
}

// #7119: `reportMissingCtorFields` (#6739/#3156) was only wired into
// `inferConstruction`'s record/opaque paths — `inferUnionCaseConstruction`
// never called it, so a union-case construction omitting a required named
// field from an all-named-args call reached codegen silently (the same
// invalid-IL hazard #6739 fixed for records, left open for unions).
test "union case missing required field emits T0105" {
  val src = "package P\nunion DbError {\n  case ExecFailed(sql: String, message: String)\n}\nfunc f(): DbError { ExecFailed(sql = \"select 1\") }\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0105"), "union case missing required field: T0105")
}

test "union case all required fields supplied is clean" {
  val src = "package P\nunion DbError {\n  case ExecFailed(sql: String, message: String)\n}\nfunc f(): DbError { ExecFailed(sql = \"select 1\", message = \"boom\") }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "union case all fields supplied: no errors")
}

// A positional-arg union case construction is exempt (mirrors the record
// precedent's `hasPositional` guard — mixed positional/named under-application
// is out of scope): `ExecFailed("select 1")` under-applies with a positional
// arg, which should surface as the ordinary arity/type mismatch, not T0105.
test "union case positional construction does not fire T0105" {
  val src = "package P\nunion DbError {\n  case ExecFailed(sql: String, message: String)\n}\nfunc f(): DbError { ExecFailed(\"select 1\") }\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0105"), "union case positional under-application: no T0105")
}

// A bare, no-fields union case reference (a genuinely nullary case, not a
// call) must stay clean — this exercises the same `checkMissingFields = false`
// placeholder-inference path the field-having-case regression guard above
// depends on, just for the case that previously already worked (#6838).
test "nullary union case bare reference is still clean" {
  val src = "package P\nunion DbError {\n  case ConnLost\n  case ExecFailed(sql: String, message: String)\n}\nfunc f(): DbError { ConnLost }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "nullary case bare reference: no errors")
}

// ─────────────────────────────────────────────────────────────────────────────
// Loop labels (#7349): `break`/`continue` must sit in a loop and a label must
// name an enclosing one (T0130); a nested loop may not reuse an enclosing
// loop's label (T0131).  Lambdas and `defer` bodies start with no loops.
// ─────────────────────────────────────────────────────────────────────────────
test "labelled loops parse and resolve" {
  val src = "package P\nfunc f(xs: in List[Int]): Int {\n  var n = 0\n  outer: for x in xs {\n    inner: while n < x {\n      n = n + 1\n      if n > 5 { break outer }\n      if n > 3 { continue inner }\n    }\n    do { break }\n  }\n  n\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "P0050"), "label prefix parses")
  assertTrue(not hasDiagCode(cr, "T0130"), "labels resolve: no T0130")
  assertTrue(not hasDiagCode(cr, "T0131"), "distinct labels: no T0131")
}

test "a break naming no enclosing loop is T0130" {
  val src = "package P\nfunc f(xs: in List[Int]): Unit {\n  outer: for x in xs { }\n  for y in xs { break outer }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0130"), "outer is a sibling, not an enclosing loop")
}

test "a continue with an unknown label is T0130" {
  val src = "package P\nfunc f(xs: in List[Int]): Unit {\n  for y in xs { continue nope }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0130"), "unknown label")
}

test "a break outside any loop is T0130" {
  val src = "package P\nfunc f(n: in Int): Unit {\n  if n > 0 { break }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0130"), "break outside a loop")
}

test "a break in a lambda cannot target the enclosing loop" {
  val src = "package P\nfunc f(xs: in List[Int]): Unit {\n  outer: for x in xs {\n    val g = { () -> break outer }\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0130"), "lambda body starts with no loops")
}

test "a break in a defer body cannot target the enclosing loop" {
  val src = "package P\nfunc f(xs: in List[Int]): Unit {\n  for x in xs {\n    defer { break }\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0130"), "defer body starts with no loops")
}

test "a nested loop reusing an enclosing label is T0131" {
  val src = "package P\nfunc f(xs: in List[Int]): Unit {\n  outer: for x in xs {\n    outer: for y in xs { break outer }\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0131"), "shadowed label")
}

test "sibling loops may share a label" {
  val src = "package P\nfunc f(xs: in List[Int]): Unit {\n  scan: for x in xs { break scan }\n  scan: for y in xs { continue scan }\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0131"), "siblings: no T0131")
  assertTrue(not hasDiagCode(cr, "T0130"), "siblings: no T0130")
}

// ─────────────────────────────────────────────────────────────────────────────
// Contract clauses are type-checked (#7228): a requires/ensures/when clause
// and a loop invariant must be Bool (T0132),
// and names inside a clause resolve like the function body's.
// ─────────────────────────────────────────────────────────────────────────────
test "a non-Bool requires clause is T0132" {
  val src = "package P\nfunc f(x: in Int): Int\n  requires: x + 1\n{\n  x\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0132"), "Int-typed requires")
}

test "an ensures clause is checked with result as the return type" {
  val ok = "package P\nfunc f(x: in Int): Int\n  ensures: result >= x\n{\n  x\n}\n"
  assertTrue(not hasDiagCode(parseCheck(ok), "T0132"), "result >= x is Bool")
  val bad = "package P\nfunc f(x: in Int): String\n  ensures: result\n{\n  \"a\"\n}\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0132"), "String-typed ensures")
}

test "an unknown name in a clause is reported by the type checker" {
  val src = "package P\nfunc f(x: in Int): Int\n  requires: x > nope\n{\n  x\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0020"), "nope is unknown")
}

test "a mismatched comparison in a clause is reported" {
  val src = "package P\nfunc f(x: in Int): Int\n  requires: x == \"a\"\n{\n  x\n}\n"
  assertTrue(diagCount(parseCheck(src)) > 0, "Int == String")
}

test "a non-Bool loop invariant is T0132" {
  val src = "package P\nfunc f(n: in Int): Int {\n  var i = 0\n  while i < n\n    invariant: i\n  {\n    i = i + 1\n  }\n  i\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0132"), "Int-typed invariant")
}

test "old() and quantifiers in clauses type-check" {
  val src = "package P\nfunc f(xs: inout List[Int]): Unit\n  ensures: xs.count == old(xs.count) + 1\n  ensures: forall (i: Int) where i >= 0 and i < xs.count { xs[i] >= 0 }\n{\n  xs.add(0)\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0132"), "well-typed old/forall clauses")
}

// `old(...)` is valid only in an `ensures:` clause (T0080, #7731,
// docs/08-contract-semantics.md §3, §4.4).
test "old() in a function ensures clause is accepted" {
  val src = "package P\nfunc bump(x: inout Int): Unit\n  ensures: x == old(x) + 1\n{\n  x = x + 1\n}\n"
  assertEqualInt(parse(src).diagnostics.count, 0, "parses cleanly")
  assertTrue(not hasDiagCode(parseCheck(src), "T0080"), "ensures is old()'s home")
}

test "old() inside a quantifier inside ensures is accepted" {
  val src = "package P\nfunc f(xs: inout List[Int]): Unit\n  ensures: forall (i: Int) where i >= 0 and i < old(xs.count) { xs[i] >= 0 }\n{\n  xs.add(0)\n}\n"
  assertEqualInt(parse(src).diagnostics.count, 0, "parses cleanly")
  assertTrue(not hasDiagCode(parseCheck(src), "T0080"), "a quantifier inside ensures stays in ensures")
}

test "old() inside a lambda inside ensures is accepted" {
  val src = "package P\nfunc apply(g: in (Int) -> Int): Int { g(0) }\nfunc f(x: in Int): Int\n  ensures: result == apply({ y: Int -> y + old(x) })\n{\n  x\n}\n"
  assertEqualInt(parse(src).diagnostics.count, 0, "parses cleanly")
  assertTrue(not hasDiagCode(parseCheck(src), "T0080"), "a lambda inside ensures stays in ensures")
}

test "old() in method, interface, protected and aspect ensures is accepted" {
  val src = "package P\n" +
    "record Ctr {\n  n: Int\n  func next(k: in Int): Int\n    ensures: result == old(k) + 1\n  {\n    k + 1\n  }\n}\n" +
    "pub interface Stepper {\n  func step(x: in Int): Int\n    ensures: result > old(x)\n}\n" +
    "protected type Acc {\n  var total: Int = 0\n  entry add(d: in Int): Int\n    ensures: result == old(d)\n  {\n    total = total + d\n    d\n  }\n}\n" +
    "aspect Keep {\n  matches: name like \"keep*\"\n  ensures: args.v == old(args.v)\n  around(args) -> ret {\n    ret = proceed(args)\n  }\n}\n" +
    "func keepOne(v: in Int): Int { v }\n"
  assertEqualInt(parse(src).diagnostics.count, 0, "parses cleanly")
  assertEqualInt(countDiagCode(parseCheck(src), "T0080"), 0, "every ensures: form admits old()")
}

test "old() in a function body is T0080" {
  val src = "package P\nfunc f(x: in Int): Int {\n  old(x)\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0080"), "body old()")
  assertTrue(diagMessagesContain(cr, "not in a function body"), "the message names the position")
}

test "old() in an expression-bodied function and a lambda is T0080" {
  val src = "package P\nfunc f(x: in Int): Int = old(x)\nfunc g(x: in Int): Int {\n  val h = { y: Int -> y + old(x) }\n  h(1)\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0080"), 2, "expression body and lambda body")
}

test "old() in a requires clause is T0080" {
  val src = "package P\nfunc f(x: in Int): Int\n  requires: old(x) > 0\n{\n  x\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0080"), "requires old()")
  assertTrue(diagMessagesContain(cr, "`requires:` clause"), "names requires:")
}

test "old() inside a quantifier inside requires is T0080" {
  val src = "package P\nfunc f(xs: in List[Int]): Int\n  requires: forall (i: Int) where i >= 0 and i < xs.count { xs[i] >= old(xs[0]) }\n{\n  0\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0080"), "requires quantifier old()")
}

test "old() in a loop invariant is T0080" {
  val src = "package P\nfunc f(n: in Int): Int {\n  var i = 0\n  while i < n\n    invariant: i >= old(n) - n\n  {\n    i = i + 1\n  }\n  i\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0080"), "loop invariant old()")
  assertTrue(diagMessagesContain(cr, "loop `invariant:`"), "names the loop invariant")
}

test "old() in a type invariant is T0080" {
  val src = "package P\nrecord R {\n  x: Int\n  invariant: x >= old(x)\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0080"), "record invariant old()")
  assertTrue(diagMessagesContain(cr, "type `invariant:`"), "names the type invariant")
}

test "old() in a when barrier and an entry body is T0080" {
  val src = "package P\nprotected type Slot {\n  var full: Bool = false\n  entry put(x: in Int): Unit\n    when: not old(full)\n  {\n    full = old(full)\n  }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0080"), 2, "barrier and entry body")
  assertTrue(diagMessagesContain(cr, "`when:` barrier"), "names the barrier")
}

test "old() in an aspect requires clause and around body is T0080" {
  val src = "package P\naspect Guard {\n  matches: name like \"g*\"\n  requires: old(args.v) > 0\n  around(args) -> ret {\n    val o = old(1)\n    ret = proceed(args)\n  }\n}\nfunc gOne(v: in Int): Int { v }\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0080"), 2, "aspect requires and around body")
}

test "old() in a module val, a field default, a parameter default and a test is T0080" {
  val src = "package P\nval k = old(1)\nrecord R {\n  x: Int = old(0)\n}\nfunc f(y: in Int = old(3)): Int { y }\ntest \"t\" {\n  val z = old(2)\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0080"), 4, "val, field default, parameter default and test body")
  assertTrue(diagMessagesContain(cr, "a field default"), "names the field default")
}

test "nested old(old(x)) is T0080" {
  val src = "package P\nfunc bump(x: inout Int): Unit\n  ensures: x == old(old(x)) + 1\n{\n  x = x + 1\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0080"), 1, "one nested old")
  assertTrue(diagMessagesContain(cr, "nested inside another"), "names the nesting")
}

test "result inside old() is T0080" {
  val src = "package P\nfunc f(x: in Int): Int\n  ensures: old(result) == x\n{\n  x\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0080"), "old(result)")
  assertTrue(diagMessagesContain(cr, "`result` cannot appear inside"), "names result")
}

// #7749 review: extern and wire members carry expression positions too.
test "old() in an extern func parameter default is T0080" {
  val src = "package P\nextern func f(x: Int = old(1)): Int = \"f\"\n"
  assertEqualInt(parse(src).diagnostics.count, 0, "parses cleanly")
  assertTrue(hasDiagCode(parseCheck(src), "T0080"), "extern func parameter default")
}

test "old() in an extern package opaque field default and invariant is T0080" {
  val src = "package P\n\nextern package Host.X {\n  pub opaque type Bar {\n    x: Int = old(1)\n    invariant: x > old(0)\n  }\n}\n"
  assertEqualInt(parse(src).diagnostics.count, 0, "parses cleanly")
  assertEqualInt(countDiagCode(parseCheck(src), "T0080"), 2, "opaque field default and invariant")
}

test "old() in an extern package range subtype bound is T0080" {
  val src = "package P\n\nextern package Host.X {\n  pub type Age = Int range 0 ..= old(150)\n}\n"
  assertEqualInt(parse(src).diagnostics.count, 0, "parses cleanly")
  assertTrue(hasDiagCode(parseCheck(src), "T0080"), "extern range bound")
}

test "old() in a wire include adjustment is T0080" {
  val src = "package P\n\nwire W {\n  include Some.Template {\n    someName = old(1)\n  }\n}\n"
  assertEqualInt(parse(src).diagnostics.count, 0, "parses cleanly")
  assertTrue(hasDiagCode(parseCheck(src), "T0080"), "include adjustment")
}

test "old() in a loop invariant inside an ensures lambda is T0080" {
  val src = "package P\nfunc apply(g: in (Int) -> Int): Int { g(0) }\nfunc f(x: in Int): Int\n  ensures: result == apply({ y: Int ->\n    var i = 0\n    while i < y\n      invariant: i >= old(x) - x\n    {\n      i = i + 1\n    }\n    i\n  })\n{\n  x\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0080"), "a loop invariant never admits old(), even inside ensures")
}

// #7749 second review: aspect config blocks, type annotations and patterns.
test "old() in an aspect config default is T0080" {
  val src = "package P\n\naspect Tap {\n  config {\n    timeoutMs: Int = old(5000)\n  }\n  matches: name like \"run*\"\n  around(call) -> ret {\n    ret = call.proceed()\n  }\n}\n"
  assertEqualInt(parse(src).diagnostics.count, 0, "parses cleanly")
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0080"), "aspect config default")
  assertTrue(diagMessagesContain(cr, "config field default"), "names the config default")
}

test "old() in a range refinement of a parameter type is T0080" {
  val src = "package P\nfunc f(a: in Int range 0 ..= old(150)): Int {\n  a\n}\n"
  assertEqualInt(parse(src).diagnostics.count, 0, "parses cleanly")
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0080"), "refinement bound in a parameter type")
  assertTrue(diagMessagesContain(cr, "type annotation"), "names the type annotation")
}

test "old() in a range pattern is T0080" {
  val src = "package P\nfunc f(n: in Int): Int {\n  match n {\n    case 0 ..= old(10) -> 1\n    case _ -> 0\n  }\n}\n"
  assertEqualInt(parse(src).diagnostics.count, 0, "parses cleanly")
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0080"), "range pattern bound")
  assertTrue(diagMessagesContain(cr, "a pattern"), "names the pattern")
}

test "old() in a quantifier binder's refinement inside ensures is T0080" {
  val src = "package P\nfunc f(xs: inout List[Int]): Unit\n  ensures: forall (i: Int range 0 ..= old(3)) { i >= 0 }\n{\n  xs.add(0)\n}\n"
  assertEqualInt(parse(src).diagnostics.count, 0, "parses cleanly")
  assertTrue(hasDiagCode(parseCheck(src), "T0080"), "types never admit old(), even in ensures")
}

// #7756: a module-level `val`'s pattern is an expression position too, like
// a local `val`'s.
test "old() in a module val tuple pattern's range bound is T0080 (#7756)" {
  val src = "package P\nval (a, 0 ..= old(9)) = (1, 2)\n"
  assertEqualInt(parse(src).diagnostics.count, 0, "parses cleanly")
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0080"), 1, "range pattern bound in a module val")
  assertTrue(diagMessagesContain(cr, "a pattern"), "names the pattern")
}

test "old() in a module val type-test pattern's refinement is T0080 (#7756)" {
  val src = "package P\nval n is Int range 0 ..= old(9) = 3\n"
  assertEqualInt(parse(src).diagnostics.count, 0, "parses cleanly")
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0080"), 1, "refinement bound in a module val pattern")
  assertTrue(diagMessagesContain(cr, "type annotation"), "names the type annotation")
}

// #7756: the types of a `raises:` clause are type positions.  The parser
// never produces `CCRaises` (D007 dropped `raises:`; the grammar keeps it
// reserved), so the clause is built directly on a parsed function.
test "old() in a raises: clause type is T0080 (#7756)" {
  val tySrc = "package P\nval v: Int range 0 ..= old(9) = 0\n"
  val raisedTy = match parse(tySrc).file.items[0].kind { case IVal(vd) -> vd.ty; case _ -> None }
  val fnSrc = "package P\nfunc f(): Unit {\n}\n"
  val pf = parse(fnSrc).file
  assertEqualInt(countDiagCode(check(pf), "T0080"), 0, "control: no raises clause")
  val it = pf.items[0]
  match it.kind {
    case IFunc(fn) -> match raisedTy {
      case Some(te) -> {
        val types: List[TypeExpr] = newList()
        types.add(te)
        val cs: List[ContractClause] = newList()
        cs.add(CCRaises(types = types, span = fn.span))
        val withRaises = FunctionDecl(
          docComments = fn.docComments,
          annotations = fn.annotations,
          visibility = fn.visibility,
          isAsync = fn.isAsync,
          name = fn.name,
          generics = fn.generics,
          params = fn.params,
          ret = fn.ret,
          whereClause = fn.whereClause,
          contracts = cs,
          body = fn.body,
          span = fn.span
        )
        val items: List[Item] = newList()
        items.add(
          Item(
            docComments = it.docComments,
            annotations = it.annotations,
            visibility = it.visibility,
            kind = IFunc(decl = withRaises),
            span = it.span
          )
        )
        val file = SourceFile(
          moduleDoc = pf.moduleDoc,
          fileAnnotations = pf.fileAnnotations,
          packageDecl = pf.packageDecl,
          imports = pf.imports,
          items = items,
          span = pf.span
        )
        val cr = check(file)
        assertEqualInt(countDiagCode(cr, "T0080"), 1, "refinement bound in a raises: type")
        assertTrue(diagMessagesContain(cr, "type annotation"), "names the type annotation")
      }
      case None -> assertTrue(false, "the val's type annotation parsed")
    }
    case _ -> assertTrue(false, "the function parsed")
  }
}

// A contract clause or loop invariant may call only @pure functions (T0133,
// #7228, language reference §6.3).
test "a clause calling a non-@pure function is T0133" {
  val src = "package P\nfunc check(x: in Int): Bool { x > 0 }\nfunc f(x: in Int): Int\n  requires: check(x)\n{\n  x\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0133"), "check is not @pure")
}

test "a clause calling a @pure function is accepted" {
  val src = "package P\n@pure\nfunc check(x: in Int): Bool { x > 0 }\nfunc f(x: in Int): Int\n  requires: check(x)\n  ensures: check(result)\n{\n  x\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0133"), "check is @pure")
}

test "a non-@pure call in the body is not T0133" {
  val src = "package P\nfunc check(x: in Int): Bool { x > 0 }\nfunc f(x: in Int): Bool\n  requires: x > 0\n{\n  check(x)\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0133"), "body calls are unrestricted")
}

test "a loop invariant calling a non-@pure function is T0133" {
  val src = "package P\nfunc ok(i: in Int): Bool { i >= 0 }\nfunc f(n: in Int): Int {\n  var i = 0\n  while i < n\n    invariant: ok(i)\n  {\n    i = i + 1\n  }\n  i\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0133"), "invariant calls ok")
}

test "a clause calling a @pure record method is accepted (#7383)" {
  val src = "package P\nrecord Box {\n  v: Int\n  @pure\n  func positive(self: in Box): Bool { self.v > 0 }\n}\nfunc f(b: in Box): Int\n  requires: b.positive()\n{\n  b.v\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0133"), "positive is @pure")
}

test "a clause calling a non-@pure record method is T0133 (#7383)" {
  val src = "package P\nrecord Box {\n  v: Int\n  func positive(self: in Box): Bool { self.v > 0 }\n}\nfunc f(b: in Box): Int\n  requires: b.positive()\n{\n  b.v\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0133"), "positive is not @pure")
}

test "a clause calling a @pure impl method is accepted (#7383)" {
  val src = "package P\nrecord Box {\n  v: Int\n}\ninterface Signed {\n  func positive(): Bool\n}\nimpl Signed for Box {\n  @pure\n  func positive(): Bool { self.v > 0 }\n}\nfunc f(b: in Box): Int\n  requires: b.positive()\n{\n  b.v\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0133"), "the impl method is @pure")
}

test "an async or method-generic protected func is T0135 (#7384)" {
  val asyncSrc = "package P\nprotected type C {\n  var n: Int = 0\n  async func get(): Int {\n    n\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(asyncSrc), "T0135"), "async func")
  val genSrc = "package P\nprotected type C {\n  var n: Int = 0\n  func pick[T](a: in T): T {\n    a\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(genSrc), "T0135"), "method-generic func")
  val okSrc = "package P\nprotected type C {\n  var n: Int = 0\n  func get(): Int {\n    n\n  }\n}\n"
  assertTrue(not hasDiagCode(parseCheck(okSrc), "T0135"), "a plain func is accepted")
}

// #7457: an impl method on a protected type becomes one of the type's locked
// members, so it sees the fields like an entry does and inherits the
// protected-func shape rules; shapes the move cannot represent are T0136.
test "an impl method on a protected type sees the type's fields (#7457)" {
  val src = "package P\ninterface Counter {\n  func bump(by: in Int): Int\n  func current(): Int\n}\nprotected type C {\n  var n: Int = 0\n}\nimpl Counter for C {\n  func bump(by: in Int): Int {\n    n = n + by\n    n\n  }\n  func current(): Int {\n    self.n\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0020"), "bare and self. field references resolve")
  assertTrue(not hasDiagCode(cr, "T0136"), "a non-clashing impl is accepted")
}

test "an impl method that clashes with a protected member is T0136 (#7457)" {
  val src = "package P\ninterface Store {\n  func get(): Int\n}\nprotected type C {\n  var n: Int = 0\n  func get(): Int {\n    n\n  }\n}\nimpl Store for C {\n  func get(): Int {\n    self.get()\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0136"), "impl get clashes with the member get")
}

test "two impls for a protected type with a shared method name are T0136 (#7547)" {
  val src = "package P\ninterface Reader {\n  func get(): Int\n}\ninterface Source {\n  func get(): Int\n}\nprotected type C {\n  var n: Int = 0\n}\nimpl Reader for C {\n  func get(): Int {\n    n\n  }\n}\nimpl Source for C {\n  func get(): Int {\n    n + 1\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0136"), "Source.get clashes with Reader.get")
  val okSrc = "package P\ninterface Reader {\n  func get(): Int\n}\ninterface Source {\n  func next(): Int\n}\nprotected type C {\n  var n: Int = 0\n}\nimpl Reader for C {\n  func get(): Int {\n    n\n  }\n}\nimpl Source for C {\n  func next(): Int {\n    n + 1\n  }\n}\n"
  assertTrue(not hasDiagCode(parseCheck(okSrc), "T0136"), "disjoint method names are accepted")
}

// #7550: `Self` in an impl method signature on a protected type is accepted
// — the contract elaborator keeps `Self` in the moved entry's signature
// unsubstituted, so MSIL/JVM erase it to `object`/`Object` exactly as they
// erase the interface slot; no T0136 rejection is needed.  (Previously
// rejected; see the removed test this replaces.)
test "Self in an impl method signature on a protected type is accepted (#7550)" {
  val topSrc = "package P\ninterface M {\n  func merge(other: in Self): Int\n}\nprotected type C {\n  var n: Int = 0\n}\nimpl M for C {\n  func merge(other: in Self): Int {\n    n\n  }\n}\n"
  assertTrue(not hasDiagCode(parseCheck(topSrc), "T0136"), "Self parameter")
  val retSrc = "package P\ninterface M2 {\n  func fresh(): Self\n}\nprotected type C2 {\n  var n: Int = 0\n}\nimpl M2 for C2 {\n  func fresh(): Self {\n    self\n  }\n}\n"
  assertTrue(not hasDiagCode(parseCheck(retSrc), "T0136"), "Self return")
  val nestedSrc = "package P\nimport Std.Collections\ninterface M3 {\n  func pool(): List[Self]\n}\nprotected type C3 {\n  var n: Int = 0\n}\nimpl M3 for C3 {\n  func pool(): List[Self] {\n    newList()\n  }\n}\n"
  assertTrue(not hasDiagCode(parseCheck(nestedSrc), "T0136"), "Self nested in a return type")
}

test "an impl for an alias of a protected type is T0136 (#7547)" {
  val src = "package P\ninterface Store {\n  func size(): Int\n}\nprotected type C {\n  var n: Int = 0\n}\nalias D = C\nimpl Store for D {\n  func size(): Int {\n    n\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0136"), "the target must name C directly")
}

test "an impl for a generic protected type is T0136 (#7457)" {
  val src = "package P\ninterface Store {\n  func size(): Int\n}\nprotected type C[T] {\n  var n: Int = 0\n}\nimpl[T] Store for C[T] {\n  func size(): Int {\n    n\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0136"), "generic protected target")
}

test "an impl for a generic record has its type parameters in scope (#7704)" {
  val src = "package P\ninterface Counted {\n  func countWith(extra: in Int): Int\n}\ninterface Pick {\n  func pick(other: in Self): Self\n  func twice(other: in Self): Self\n}\nrecord Box[T] {\n  value: T\n}\nimpl[T] Counted for Box[T] {\n  func countWith(extra: in Int): Int {\n    val y: T = self.value\n    var z: T = y\n    z = value\n    extra\n  }\n}\nimpl[T] Pick for Box[T] {\n  func pick(other: in Self): Self {\n    val v: T = other.value\n    Box(value = v)\n  }\n  func twice(other: in Self): Self {\n    pick(other)\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0010"), "T resolves in the impl target and bodies")
  assertTrue(not hasDiagCode(cr, "T0145"), "impl[T] ... for Box[T] is well-formed")
  assertTrue(not hasDiagCode(cr, "T0106"), "Self parameter conforms")
  assertTrue(not hasDiagCode(cr, "T0107"), "Self return conforms")
}

test "an impl whose target arguments are not its own type parameters is T0145 (#7704)" {
  val iface = "package P\ninterface Counted {\n  func size(): Int\n}\nrecord Box[T] {\n  value: T\n}\nrecord Two[A, B] {\n  a: A\n  b: B\n}\n"
  val concrete = iface + "impl Counted for Box[Int] {\n  func size(): Int = 1\n}\n"
  assertTrue(hasDiagCode(parseCheck(concrete), "T0145"), "a concrete instantiation")
  val repeated = iface + "impl[T] Counted for Two[T, T] {\n  func size(): Int = 2\n}\n"
  assertTrue(hasDiagCode(parseCheck(repeated), "T0145"), "a parameter named twice")
  val unused = iface + "impl[T, U] Counted for Box[T] {\n  func size(): Int = 1\n}\n"
  assertTrue(hasDiagCode(parseCheck(unused), "T0145"), "an impl parameter the target never names")
  val swapped = iface + "impl[A, B] Counted for Two[B, A] {\n  func size(): Int = 2\n}\n"
  assertTrue(not hasDiagCode(parseCheck(swapped), "T0145"), "parameters in any order")
}

test "an async impl method on a protected type is T0135 (#7457)" {
  val src = "package P\ninterface Store {\n  async func size(): Int\n}\nprotected type C {\n  var n: Int = 0\n}\nimpl Store for C {\n  async func size(): Int {\n    n\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0135"), "async impl method runs under the lock")
}

test "an impl for a record is not subject to the protected rules (#7457)" {
  val src = "package P\ninterface Store {\n  func get(): Int\n}\nrecord R {\n  n: Int\n}\nimpl Store for R {\n  func get(): Int {\n    n\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(not hasDiagCode(cr, "T0136"), "record target")
  assertTrue(not hasDiagCode(cr, "T0135"), "record target")
}

// #7626/#7627: no backend can compile a non-protected impl target that
// declares the same method name reachable twice directly on it — MSIL/JVM
// both fail codegen with a duplicate-member error, and native (#7600) has
// no ambiguity diagnostic to fall back on. This generalizes the T0136
// "duplicate method name on a shared target" detection (protected types)
// to every other impl target under a new code, T0139.
test "a record's own-body method and a same-named impl method are T0139 (#7626)" {
  val src = "package P\ninterface Shape {\n  func area(): Int\n}\nrecord Square {\n  side: Int\n  func area(): Int {\n    self.side + 1\n  }\n}\nimpl Shape for Square {\n  func area(): Int {\n    100\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0139"), "impl area() clashes with the record's own area()")
}

test "two impls for a record with a shared method name are T0139 (#7627)" {
  val src = "package P\ninterface Shape {\n  func area(): Int\n}\ninterface Other {\n  func area(): Int\n}\nrecord Square {\n  side: Int\n}\nimpl Shape for Square {\n  func area(): Int {\n    self.side * self.side\n  }\n}\nimpl Other for Square {\n  func area(): Int {\n    100\n  }\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0139"), "Other.area clashes with Shape.area")
}

test "an impl method with a distinct name from the record's own methods and other impls is accepted" {
  val src = "package P\ninterface Shape {\n  func area(): Int\n}\ninterface Other {\n  func perimeter(): Int\n}\nrecord Square {\n  side: Int\n  func label(): String {\n    \"square\"\n  }\n}\nimpl Shape for Square {\n  func area(): Int {\n    self.side * self.side\n  }\n}\nimpl Other for Square {\n  func perimeter(): Int {\n    self.side * 4\n  }\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0139"), "distinct names never clash")
}

// #7508: a non-`Std.*` package cannot redeclare one of the true
// language-builtin names (`println`, `toString`, `panic`, `assert`,
// `default`, `expect`, `format1`-`format4`, `hashCode`,
// `__lyric_protected_wait`/`__lyric_protected_notify`) — every backend's
// `lowerBuiltinOrStaticCall{Msil,}`/`lowerCallEx` dispatcher intercepts
// these names unconditionally, so a same-named user declaration would be
// silently uncallable rather than genuinely shadowing the builtin.
test "a non-Std package declaring 'println' is T0140" {
  val src = "package P\nfunc println(n: in Int): Unit {\n  ()\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0140"), "println is a reserved built-in name")
}

test "a non-Std package declaring 'toString' is T0140" {
  val src = "package P\nfunc toString(n: in Int): String {\n  \"n\"\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0140"), "toString is a reserved built-in name")
}

test "a non-Std package declaring 'hashCode' is T0140" {
  val src = "package P\nfunc hashCode(n: in Int): Int {\n  n\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0140"), "hashCode is a reserved built-in name")
}

test "a Std.* package may declare a reserved name" {
  val src = "package Std.Foo\npub func println(s: in String): Unit {\n  ()\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0140"), "Std.* keeps the isCodegenBuiltinName-style exemption")
}

test "a non-Std package declaring a stdlib-kernel name like 'newList' is accepted (not reserved)" {
  val src = "package P\nfunc newList(n: in Int): Int {\n  n\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0140"), "newList is not a reserved language builtin")
}

test "protected types still report the clash as T0136, not T0139 (#7626/#7627)" {
  val ownSrc = "package P\ninterface Store {\n  func get(): Int\n}\nprotected type C {\n  var n: Int = 0\n  func get(): Int {\n    n\n  }\n}\nimpl Store for C {\n  func get(): Int {\n    self.get()\n  }\n}\n"
  val ownCr = parseCheck(ownSrc)
  assertTrue(hasDiagCode(ownCr, "T0136"), "protected own-member clash is still T0136")
  assertTrue(not hasDiagCode(ownCr, "T0139"), "not double-reported as T0139")
  val twoImplSrc = "package P\ninterface Reader {\n  func get(): Int\n}\ninterface Source {\n  func get(): Int\n}\nprotected type C {\n  var n: Int = 0\n}\nimpl Reader for C {\n  func get(): Int {\n    n\n  }\n}\nimpl Source for C {\n  func get(): Int {\n    n + 1\n  }\n}\n"
  val twoImplCr = parseCheck(twoImplSrc)
  assertTrue(hasDiagCode(twoImplCr, "T0136"), "protected two-impl clash is still T0136")
  assertTrue(not hasDiagCode(twoImplCr, "T0139"), "not double-reported as T0139")
}

test "a free function sharing an impl method's name is accepted (T0139 targets impl/own-body clashes only)" {
  val src = "package P\ninterface Shape {\n  func area(): Int\n}\nrecord Square {\n  side: Int\n}\nimpl Shape for Square {\n  func area(): Int {\n    self.side * self.side\n  }\n}\nfunc area(x: in Int): Int {\n  x + 3\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0139"), "a free function is not a member of Square")
}

test "built-in members in a clause are not calls to check" {
  val src = "package P\nfunc f(xs: in List[Int], s: in String): Int\n  requires: xs.count > 0 and s.length > 0\n{\n  xs[0]\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0133"), "count/length")
}

// ─────────────────────────────────────────────────────────────────────────────
// #7335: the documented `String` host-method surface (docs/01 §12.1) types
// as a real `TyFunction`, not the `TyError` every one of these fell through
// to before. `TyError` unifies with everything, so a call through one of
// these methods used to hide every downstream type error (the repro below).
// ─────────────────────────────────────────────────────────────────────────────
test "#7335 repro: substring result feeds indexOf, whose Int/Option mismatch is now caught" {
  // No `import Std.String`, so `.indexOf` keeps the raw `Int` (-1 sentinel)
  // binding — matching it against `Some`/`None` is a real scrutinee/pattern
  // type mismatch. Before this fix `.substring` typed `TyError`, which
  // unified with the `match` scrutinee leniently and let this compile clean.
  // `Option` is defined inline (`parseCheck` checks one isolated file, same
  // as the other T0129 tests above) rather than via `import Std.Core`.
  val src = "package Idx\nunion Option[T] { case Some(value: T); case None }\nfunc main(): Unit {\n  val s = \"ab:c\"\n  val t = s.substring(0, 2)\n  match t.indexOf(\":\") {\n    case Some(i) -> ()\n    case None -> ()\n  }\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0129"), "Some/None patterns can never match an Int scrutinee (#7335's exact repro)")
}

test "s.substring(start) types as (String) with a String result" {
  val src = "package P\nfunc f(s: in String): String { s.substring(1) }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "1-arg substring: no diagnostics")
}

test "s.substring(start, count) types as (Int, Int) -> String" {
  val src = "package P\nfunc f(s: in String): String { s.substring(1, 2) }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "2-arg substring: no diagnostics")
}

test "s.substring(start, count) with a wrong argument type is T0043" {
  val src = "package P\nfunc f(s: in String): String { s.substring(\"x\", 2) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0043"), "substring's start must be Int")
}

test "a user member named substring keeps its full arity" {
  val src = "package P\nrecord R { substring: (Int, Int, Int) -> String }\nfunc f(r: in R): String {\n  r.substring(1, 2)\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0042"), "the optional-count rule applies only to String receivers")
}

test "s.substring(start) result used as Int is T0043 (return type known)" {
  val src = "package P\nfunc wantInt(x: in Int): Int { x }\nfunc f(s: in String): Int { wantInt(s.substring(0)) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0043"), "substring returns String, not Int")
}

test "s.toLower() types as () -> String" {
  val src = "package P\nfunc f(s: in String): String { s.toLower() }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "toLower: no diagnostics")
}

test "s.toLower() called with an argument is T0042 (wrong arity)" {
  val src = "package P\nfunc f(s: in String): String { s.toLower(\"x\") }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0042"), "toLower takes no arguments")
}

test "s.toUpper() result used as Int is T0043" {
  val src = "package P\nfunc wantInt(x: in Int): Int { x }\nfunc f(s: in String): Int { wantInt(s.toUpper()) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0043"), "toUpper returns String, not Int")
}

test "s.trim()/trimStart()/trimEnd() type as () -> String" {
  val src = "package P\nfunc f(s: in String): String { s.trim() }\nfunc g(s: in String): String { s.trimStart() }\nfunc h(s: in String): String { s.trimEnd() }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "trim family: no diagnostics")
}

test "s.replace(old, new) types as (String, String) -> String" {
  val src = "package P\nfunc f(s: in String): String { s.replace(\"a\", \"b\") }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "replace: no diagnostics")
}

test "s.replace with a non-String argument is T0043" {
  val src = "package P\nfunc f(s: in String): String { s.replace(\"a\", 1) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0043"), "replace's new value must be String")
}

test "s.split(sep) types as (String) -> slice[String]" {
  val src = "package P\nfunc f(s: in String): Int { s.split(\",\").length }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "split result has slice methods (.length)")
}

test "s.split with a non-String separator is T0043" {
  val src = "package P\nfunc f(s: in String): slice[String] { s.split(1) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0043"), "split's separator must be String")
}

test "s.startsWith(prefix)/endsWith(suffix)/contains(sub) type as (String) -> Bool" {
  val src = "package P\nfunc f(s: in String): Bool { s.startsWith(\"a\") }\nfunc g(s: in String): Bool { s.endsWith(\"a\") }\nfunc h(s: in String): Bool { s.contains(\"a\") }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "startsWith/endsWith/contains: no diagnostics")
}

test "s.startsWith with a non-String argument is T0043" {
  val src = "package P\nfunc f(s: in String): Bool { s.startsWith(1) }\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0043"), "startsWith's prefix must be String")
}

test "s.isNormalized() types as () -> Bool; s.normalize() as () -> String" {
  val src = "package P\nfunc f(s: in String): Bool { s.isNormalized() }\nfunc g(s: in String): String { s.normalize() }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "isNormalized/normalize: no diagnostics")
}

test "chained String host methods still type-check end to end" {
  val src = "package P\nfunc f(s: in String): Bool { s.trim().toLower().startsWith(\"a\") }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "chained calls resolve real types at each step")
}

// ─────────────────────────────────────────────────────────────────────────────
// #7584: record-pattern head validation.  `PRecord`'s own `head: ModulePath`
// used to be discarded entirely by both `bindPatternTyped` and
// `checkConstRefPattern` — fields were resolved purely from the scrutinee's
// own type, so a head naming a different record, a union case, an
// unimported package, or a package-private type type-checked silently.
// Mirrors the #7548 tests just above for `PConstructor` pattern heads
// (`unionCaseSymbolForScrutinee`), but for `checkRecordPatternHead`.
// ─────────────────────────────────────────────────────────────────────────────
test "a bare record-pattern head matching the scrutinee resolves cleanly (#7584)" {
  val src = "package P\nrecord Point {\n  x: Int\n  y: Int\n}\nfunc f(p: in Point): Int {\n  match p {\n    case Point { x = a, y = b } -> a + b\n  }\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0137"), 0, "bare Point head against a Point scrutinee: no T0137")
}

test "a record-pattern head naming a different record than the scrutinee is T0137 (#7584)" {
  val src = "package P\nrecord Point {\n  x: Int\n  y: Int\n}\nrecord Blob {\n  z: Int\n}\nfunc f(p: in Point): Int {\n  match p {\n    case Blob { z = a } -> a\n    case _ -> 0\n  }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0137"), 1, "Blob head against a Point scrutinee: exactly one T0137")
  assertTrue(
    diagMessageFor(cr, "T0137").contains("Blob"),
    "T0137 names the mismatched head: " + diagMessageFor(cr, "T0137")
  )
}

test "a record-pattern head naming a union case (not a record) is T0137 (#7584)" {
  val src = "package P\nrecord Point {\n  x: Int\n  y: Int\n}\nunion Kind {\n  case A(x: Int)\n}\nfunc f(p: in Point): Int {\n  match p {\n    case A { x = a } -> a\n    case _ -> 0\n  }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0137"), 1, "a union-case head against a record scrutinee: exactly one T0137")
}

test "a bare record-pattern head against a generic record instantiation resolves cleanly (#7584)" {
  val src = "package P\nrecord Box[T] {\n  value: T\n}\nfunc f(b: in Box[Int]): Int {\n  match b {\n    case Box { value } -> value\n  }\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0137"), 0, "bare Box head against a Box[Int] scrutinee: no T0137")
}

test "record-pattern head against an unresolvable scrutinee has no T0137 (#7584)" {
  // `undefinedScrutinee` is itself an unknown identifier and fires its OWN
  // (unrelated) diagnostic — the point of this test is that the pattern
  // head check never ALSO fires T0137, since an unresolved (`TyError`)
  // scrutinee never reaches the `TyUser` branch `checkRecordPatternHead`
  // lives in.
  val src = "package P\nrecord Point {\n  x: Int\n  y: Int\n}\nfunc f(): Int {\n  match undefinedScrutinee {\n    case Point { x = a, y = b } -> a + b\n    case _ -> 0\n  }\n}\n"
  assertEqualInt(
    countDiagCode(parseCheck(src), "T0137"),
    0,
    "an unresolvable scrutinee never reaches the record-pattern head check"
  )
}

func libGeoPointPackages(): List[ImportedPackage] {
  val pkgGeo = parse("package Lib.Geo\npub record Point {\n  x: Int\n  y: Int\n}\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Lib.Geo",
      items = pkgGeo.file.items,
      imports = collectImportNames(pkgGeo.file.imports),
      wholeImports = collectWholeImportNames(pkgGeo.file.imports)
    )
  )
  packages
}

// #7591: like `libGeoPointPackages`, but `Point`'s call-site accessor is a
// `pub` wrapper function (`mkGeoPoint`), so a consumer never has to write
// `Lib.Geo.Point` anywhere at all — the type is genuinely never named,
// mirroring the exact shape from the issue's repro (a `pub` function
// returning a package-private OR (as here) public type from another
// package, with no import needed to see it via a bare pattern head).
func libGeoPointWrapperPackages(): List[ImportedPackage] {
  val pkgGeo = parse(
    "package Lib.Geo\npub record Point {\n  x: Int\n  y: Int\n}\npub func mkGeoPoint(): Point {\n  Point(x = 1, y = 2)\n}\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Lib.Geo",
      items = pkgGeo.file.items,
      imports = collectImportNames(pkgGeo.file.imports),
      wholeImports = collectWholeImportNames(pkgGeo.file.imports)
    )
  )
  packages
}

test "unimported package-qualified record-pattern head is T0020 (#7584)" {
  val src = "package App\nfunc f(p: in Lib.Geo.Point): Int {\n  match p {\n    case Lib.Geo.Point { x = a, y = b } -> a + b\n    case _ -> 0\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, libGeoPointPackages())
  assertTrue(countDiagCode(cr, "T0020") >= 1, "unimported Lib.Geo.Point record-pattern head fires T0020")
  val msg = diagMessageFor(cr, "T0020")
  assertTrue(msg.contains("Lib.Geo"), "T0020 names the unreachable package: " + msg)
  assertTrue(msg.contains("import Lib.Geo"), "T0020 suggests the fix: " + msg)
}

test "imported package-qualified record-pattern head resolves cleanly (#7584)" {
  val src = "package App\nimport Lib.Geo\nfunc f(p: in Lib.Geo.Point): Int {\n  match p {\n    case Lib.Geo.Point { x = a, y = b } -> a + b\n    case _ -> 0\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, libGeoPointPackages())
  assertEqualInt(countDiagCode(cr, "T0020"), 0, "imported package-qualified record-pattern head: no T0020")
  assertEqualInt(countDiagCode(cr, "T0137"), 0, "imported package-qualified record-pattern head: no T0137")
}

func privatePointPackages(): List[ImportedPackage] {
  val pkgPriv = parse(
    "package PkgPriv\nrecord Point {\n  x: Int\n  y: Int\n}\npub func mkPoint(): Point {\n  Point(x = 1, y = 2)\n}\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgPriv",
      items = pkgPriv.file.items,
      imports = collectImportNames(pkgPriv.file.imports),
      wholeImports = collectWholeImportNames(pkgPriv.file.imports)
    )
  )
  packages
}

test "package-private record in a qualified pattern head is T0097 (#7584)" {
  val src = "package App\nimport PkgPriv\nfunc f(): Int {\n  match mkPoint() {\n    case PkgPriv.Point { x = a, y = b } -> a + b\n    case _ -> 0\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, privatePointPackages())
  assertEqualInt(countDiagCode(cr, "T0097"), 1, "PkgPriv.Point {...} pattern head is exactly one T0097")
  assertEqualInt(countDiagCode(cr, "T0020"), 0, "not T0020: an import cannot fix a private type")
  assertTrue(
    diagMessageFor(cr, "T0097").contains("'Point'"),
    "T0097 names the private record: " + diagMessageFor(cr, "T0097")
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// #7591: a BARE pattern head (no package qualifier at all) that names
// another package's package-private record/union/enum case must be T0097,
// exactly like the qualified form above. Before this fix, the privacy check
// in `checkRecordPatternHead` and `unionCaseSymbolForScrutinee` lived only
// inside the `segs.count >= 2` / `flatSegs.count >= 2` branch, so a `pub`
// wrapper function returning a package-private type — the caller never
// names the type at all — let a bare pattern head silently name it with no
// diagnostic. A same-package private type, and a public type from another
// package, are unaffected: the fix adds only the privacy check, not a
// reachability (T0020) check, for the bare form — D141 already resolves a
// bare pattern head through the scrutinee's own type whatever the file's
// imports, so a bare head's package is reachable by construction once it is
// not private.
// ─────────────────────────────────────────────────────────────────────────────
test "bare pattern head naming another package's private record is T0097 (#7591)" {
  val src = "package App\nimport PkgPriv\nfunc f(): Int {\n  match mkPoint() {\n    case Point { x = a, y = _ } -> a\n    case _ -> 0\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, privatePointPackages())
  assertEqualInt(countDiagCode(cr, "T0097"), 1, "bare Point {...} pattern head is exactly one T0097")
  assertEqualInt(countDiagCode(cr, "T0020"), 0, "not T0020: an import cannot fix a private type")
  assertTrue(
    diagMessageFor(cr, "T0097").contains("'Point'"),
    "T0097 names the private record: " + diagMessageFor(cr, "T0097")
  )
}

test "bare pattern head naming another package's private union case is T0097 (#7591)" {
  val src = "package App\nimport PkgPriv\nfunc f(): Int {\n  match mkKind() {\n    case A(x) -> x\n    case _ -> 0\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, privateKindPackages())
  assertEqualInt(countDiagCode(cr, "T0097"), 1, "bare A(...) pattern head is exactly one T0097")
  assertEqualInt(countDiagCode(cr, "T0020"), 0, "not T0020: an import cannot fix a private type's case")
  assertTrue(
    diagMessageFor(cr, "T0097").contains("'A'"),
    "T0097 names the private union's case: " + diagMessageFor(cr, "T0097")
  )
}

// #7591: a bare NULLARY case pattern (`case B ->`, no parens) parses as a
// `PBinding` and is disambiguated to a case constructor by
// `checkBareCasePatternScrutinee` — an entirely different code path from
// `unionCaseSymbolForScrutinee`'s `PConstructor` handling that the
// `case A(x) ->` test just above exercises. Needs its own privacy check.
func privateKindBPackages(): List[ImportedPackage] {
  val pkgPriv = parse(
    "package PkgPriv\nunion Kind {\n  case A(x: Int)\n  case B\n}\npub func mkKindB(): Kind {\n  Kind.B\n}\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgPriv",
      items = pkgPriv.file.items,
      imports = collectImportNames(pkgPriv.file.imports),
      wholeImports = collectWholeImportNames(pkgPriv.file.imports)
    )
  )
  packages
}

test "bare NULLARY pattern head naming another package's private union case is T0097 (#7591)" {
  val src = "package App\nimport PkgPriv\nfunc f(): Int {\n  match mkKindB() {\n    case B -> 1\n    case _ -> 0\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, privateKindBPackages())
  assertEqualInt(countDiagCode(cr, "T0097"), 1, "bare nullary B pattern head is exactly one T0097")
  assertEqualInt(countDiagCode(cr, "T0020"), 0, "not T0020: an import cannot fix a private type's case")
  assertTrue(
    diagMessageFor(cr, "T0097").contains("'B'"),
    "T0097 names the private union's case: " + diagMessageFor(cr, "T0097")
  )
}

func privateStatusPackages(): List[ImportedPackage] {
  val pkgPriv = parse(
    "package PkgPriv\nenum Status { case Active; case Done }\npub func mkStatus(): Status {\n  Active\n}\n"
  )
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "PkgPriv",
      items = pkgPriv.file.items,
      imports = collectImportNames(pkgPriv.file.imports),
      wholeImports = collectWholeImportNames(pkgPriv.file.imports)
    )
  )
  packages
}

test "bare pattern head naming another package's private enum case is T0097 (#7591)" {
  val src = "package App\nimport PkgPriv\nfunc f(): Int {\n  match mkStatus() {\n    case Active -> 1\n    case _ -> 0\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, privateStatusPackages())
  assertEqualInt(countDiagCode(cr, "T0097"), 1, "bare Active pattern head is exactly one T0097")
  assertEqualInt(countDiagCode(cr, "T0020"), 0, "not T0020: an import cannot fix a private type's case")
  assertTrue(
    diagMessageFor(cr, "T0097").contains("'Active'"),
    "T0097 names the private enum's case: " + diagMessageFor(cr, "T0097")
  )
}

// #7608: an enum scrutinee's bare nullary case must be resolved against the
// scrutinee's OWN enum before the privacy check runs. Another loaded package
// declaring a public case with the same bare name (`Active` here) must not
// stand in for the private one, whichever package the symbol table lists
// first.
func publicActivePackage(name: in String): ImportedPackage {
  val pkg = parse("package " + name + "\npub enum Mode { case Active; case Idle }\n")
  ImportedPackage(
    name = name,
    items = pkg.file.items,
    imports = collectImportNames(pkg.file.imports),
    wholeImports = collectWholeImportNames(pkg.file.imports)
  )
}

func privateStatusWithPublicCollision(publicFirst: in Bool): List[ImportedPackage] {
  val packages: List[ImportedPackage] = newList()
  if publicFirst {
    packages.add(publicActivePackage("PubModes"))
  }
  val priv = privateStatusPackages()
  packages.add(priv[0])
  if not publicFirst {
    packages.add(publicActivePackage("PubModes"))
  }
  packages
}

test "bare private enum case is T0097 even when a public enum elsewhere has a same-named case (#7608)" {
  val src = "package App\nimport PkgPriv\nimport PubModes\nfunc f(): Int {\n  match mkStatus() {\n    case Active -> 1\n    case _ -> 0\n  }\n}\n"
  val before = checkWithImportedPackages(parse(src).file, privateStatusWithPublicCollision(true))
  assertEqualInt(countDiagCode(before, "T0097"), 1, "public same-named case listed first: still one T0097")
  val after = checkWithImportedPackages(parse(src).file, privateStatusWithPublicCollision(false))
  assertEqualInt(countDiagCode(after, "T0097"), 1, "public same-named case listed last: still one T0097")
  assertTrue(
    diagMessageFor(before, "T0097").contains("'Active'"),
    "T0097 names the private enum's case: " + diagMessageFor(before, "T0097")
  )
}

test "bare case of a public enum is clean when a private enum elsewhere has a same-named case (#7608)" {
  val src = "package App\nimport PkgPriv\nimport PubModes\nfunc g(m: in PubModes.Mode): Int {\n  match m {\n    case Active -> 1\n    case _ -> 0\n  }\n}\n"
  val first = checkWithImportedPackages(parse(src).file, privateStatusWithPublicCollision(false))
  assertEqualInt(countDiagCode(first, "T0097"), 0, "private same-named case listed first: no T0097")
  val last = checkWithImportedPackages(parse(src).file, privateStatusWithPublicCollision(true))
  assertEqualInt(countDiagCode(last, "T0097"), 0, "private same-named case listed last: no T0097")
}

test "bare pattern head naming a SAME-package private record has no T0097 (#7591)" {
  val src = "package P\nrecord Point {\n  x: Int\n  y: Int\n}\nfunc mkPoint(): Point {\n  Point(x = 1, y = 2)\n}\nfunc f(): Int {\n  match mkPoint() {\n    case Point { x = a, y = _ } -> a\n  }\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0097"), 0, "same-package private record: no T0097")
}

test "bare pattern head naming a SAME-package private union case has no T0097 (#7591)" {
  val src = "package P\nunion Kind {\n  case A(x: Int)\n  case B\n}\nfunc mkKind(): Kind {\n  Kind.A(x = 1)\n}\nfunc f(): Int {\n  match mkKind() {\n    case A(x) -> x\n    case B -> 0\n  }\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0097"), 0, "same-package private union case: no T0097")
}

test "bare pattern head naming a SAME-package private enum case has no T0097 (#7591)" {
  val src = "package P\nenum Status { case Active; case Done }\nfunc mkStatus(): Status {\n  Active\n}\nfunc f(): Int {\n  match mkStatus() {\n    case Active -> 1\n    case Done -> 0\n  }\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0097"), 0, "same-package private enum case: no T0097")
}

test "bare pattern head naming a public record from another package has no diagnostics (#7591)" {
  // `App` never writes `Lib.Geo.Point` anywhere — `mkGeoPoint()` is called
  // bare (through the whole `import Lib.Geo`) and the pattern head is bare
  // too, mirroring the issue's exact shape but for a PUBLIC record: a bare
  // head naming a public type from another package must stay clean, with
  // no T0097 (it isn't private) and no T0020 (D141: a bare pattern head
  // resolves through the scrutinee's own type regardless of import).
  val src = "package App\nimport Lib.Geo\nfunc f(): Int {\n  match mkGeoPoint() {\n    case Point { x = a, y = b } -> a + b\n    case _ -> 0\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, libGeoPointWrapperPackages())
  assertEqualInt(countDiagCode(cr, "T0097"), 0, "public record, bare head: no T0097")
  assertEqualInt(countDiagCode(cr, "T0020"), 0, "public record, bare head: no T0020")
  assertEqualInt(countDiagCode(cr, "T0137"), 0, "public record, bare head: no T0137")
}

// The "right record name, wrong qualifier" branch of `checkRecordPatternHead`
// (T0137, the qualifier text does not equal the record's own `originPackage`)
// had no self-test (#7591, raised in review of #7590/#7584).
test "record-pattern head with the right record name but the wrong qualifier is T0137 (#7591)" {
  val src = "package App\nimport Lib.Geo\nfunc f(p: in Lib.Geo.Point): Int {\n  match p {\n    case Wrong.Point { x = a, y = b } -> a + b\n    case _ -> 0\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, libGeoPointPackages())
  assertEqualInt(
    countDiagCode(cr, "T0137"),
    1,
    "Wrong.Point head against a reachable Lib.Geo.Point scrutinee: exactly one T0137"
  )
  assertTrue(
    diagMessageFor(cr, "T0137").contains("Wrong"),
    "T0137 names the wrong qualifier: " + diagMessageFor(cr, "T0137")
  )
}

test "slice.toList() resolves the genuine stdlib List even with a local shadow (#7665)" {
  // `App`'s own `record List` shadows the stdlib's `List` for an ordinary
  // bare-name type reference (the DECLARED type of `lst` below resolves to
  // this local record) — but `xs.toList()`'s inferred type must still be
  // the genuine stdlib `List[Int]`, so the mismatch is now a compile-time
  // T0060, not a silent accept.
  val src = "package App\nimport Std.CollectionsHost\nrecord List {\n  tag: Int\n}\nfunc f(): Unit {\n  val xs: slice[Int] = [1, 2, 3]\n  val lst: List = xs.toList()\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(
    countDiagCode(cr, "T0060"),
    1,
    "a local record List shadowing the stdlib List must not let .toList() silently satisfy it"
  )
}

test "slice.toList() type-checks cleanly with no shadowing type in scope (#7665)" {
  val src = "package App\nimport Std.CollectionsHost\nfunc f(): Unit {\n  val xs: slice[Int] = [1, 2, 3]\n  val lst: List[Int] = xs.toList()\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(diagCount(cr), 0, "no shadow, matching declared type: toList() must type-check clean")
  assertEqual(
    recordedCallType(cr, src, "xs.toList()"),
    "List[Int]",
    "the .toList() initialiser resolves to List[Int], not TyError (#7702)"
  )
  assertEqual(bareTypeOrigin(cr, "List"), "Std.CollectionsHost", "the recorded List is the stdlib one (#7702)")
}

// `&` (cloud-agents docs/lyric/gotchas.md "& is NOT bitwise-and"): neither
// backend implements it (MSIL silently passed the operand through
// unchanged, native panics with "function references (&f) are not yet
// supported"), and it has no infix form — it's `PrefixExpr`-only
// (`docs/grammar.ebnf`). Before this diagnostic, `x & y` parsed as `x`
// (a complete expression, since `&` never continues a binary chain)
// followed by a silently re-entered, silently accepted `&y` statement,
// discarding `y` with no diagnostic anywhere. `&<expr>` is now rejected
// unconditionally with T0141, turning that silent data loss into a
// compile-time error at the `&` site itself.
test "'&' prefix expression is T0141" {
  val src = "package P\nfunc f(x: in Int, y: in Int): Unit {\n  val z = &y\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0141"), "bare '&y' is rejected")
}

test "'x & y' (the bitwise-and landmine) is now a compile error, not a silent no-op" {
  // Before the fix this compiled clean: `val z = x` (a complete
  // statement, since `&` isn't a recognized infix operator) followed by
  // a silently re-entered `&y` expression statement that discarded `y`.
  val src = "package P\nfunc f(x: in Int, y: in Int): Int {\n  val z = x & y\n  z\n}\n"
  assertTrue(hasDiagCode(parseCheck(src), "T0141"), "'x & y' now fails to compile instead of silently discarding y")
}

test "real bitwise methods are unaffected by the '&' rejection" {
  val src = "package P\nfunc f(x: in Int, y: in Int): Int {\n  x.and(y)\n}\n"
  assertTrue(not hasDiagCode(parseCheck(src), "T0141"), ".and()/.or()/.xor()/.shl()/.shr() remain unaffected")
}

// ─────────────────────────────────────────────────────────────────────────────
// #7729: T0142 — a generator cannot suspend inside a `catch`, `finally` or
// `defer` body (§7.2); a `yield` in the protected `try` body itself is fine.
// ─────────────────────────────────────────────────────────────────────────────
test "yield inside a catch block is T0142 (#7729)" {
  val src = "package P\nasync func g(): Int {\n  try {\n    yield 1\n  } catch Bug as e {\n    yield 2\n  }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0142"), 1, "one T0142 for the catch block")
  assertTrue(
    diagMessageFor(cr, "T0142").contains("catch"),
    "T0142 names the catch block: " + diagMessageFor(cr, "T0142")
  )
}

test "yield inside a finally block is T0142 (#7729)" {
  val src = "package P\nasync func g(): Int {\n  try {\n    yield 1\n  } finally {\n    if true {\n      yield 2\n    }\n  }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0142"), 1, "one T0142 for the finally block")
  assertTrue(
    diagMessageFor(cr, "T0142").contains("finally"),
    "T0142 names the finally block: " + diagMessageFor(cr, "T0142")
  )
}

test "yield inside a defer block is T0142 (#7729)" {
  val src = "package P\nasync func g(): Int {\n  defer {\n    yield 0\n  }\n  yield 1\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0142"), 1, "one T0142 for the defer block")
}

test "yield inside a try body with catch and finally is accepted (#7729)" {
  val src = "package P\nasync func g(): Int {\n  try {\n    yield 1\n    try {\n      yield 2\n    } finally {\n      println(\"x\")\n    }\n  } catch Bug as e {\n    println(\"caught\")\n  } finally {\n    println(\"done\")\n  }\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0142"), 0, "no T0142 for yields in try bodies")
}

// #7737: every semantic "is this the stdlib collection / monad?" check keys on
// the stdlib type's identity, never its bare name. A package's own `record
// List[T]` used to be iterated, indexed and given `.count`/`.toArray()` as if
// it were the stdlib `List` (compiling, then failing at runtime on both
// backends), and a package's own `union Result`/`Option` typed
// `Age.tryFrom(...)`/`s.indexOf(...)`, whose values are always the stdlib
// unions. Each case below pairs the shadowed form with the genuine stdlib form
// (`stdCollectionsHostPackages`/`stdCorePackages`), and the genuine form
// proves its element/result type is real (a mismatching binding is rejected),
// so neither side can pass vacuously through `TyError`.
// ─────────────────────────────────────────────────────────────────────────────
func stdCorePackages(): List[ImportedPackage] {
  val core = parse(
    "package Std.Core\npub union Option[T] {\n  case Some(value: T)\n  case None\n}\n" +
      "pub union Result[T, E] {\n  case Ok(value: T)\n  case Err(error: E)\n}\n"
  )
  val str = parse("package Std.String\npub func strLen(s: in String): Int { 0 }\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Std.Core",
      items = core.file.items,
      imports = collectImportNames(core.file.imports),
      wholeImports = collectWholeImportNames(core.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "Std.String",
      items = str.file.items,
      imports = collectImportNames(str.file.imports),
      wholeImports = collectWholeImportNames(str.file.imports)
    )
  )
  packages
}

test "for over a user record named List is T0126, not stdlib iteration (#7737)" {
  val src = "package P\nrecord List[T] {\n  items: slice[T]\n}\nfunc f(l: in List[Int]): Unit {\n  for x in l {\n  }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0126"), 1, "a user record List is not iterable")
  assertTrue(
    Str.contains(diagMessageFor(cr, "T0126"), "only shares its name with the stdlib List"),
    "T0126 says the List is not the stdlib one: " + diagMessageFor(cr, "T0126")
  )
}

test "for over the stdlib List still binds its element type (#7737)" {
  val src = "package P\nimport Std.CollectionsHost\nfunc f(xs: in List[Int]): Unit {\n  for x in xs {\n    val s: String = x\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(countDiagCode(cr, "T0126"), 0, "the stdlib List is iterable")
  assertEqualInt(countDiagCode(cr, "T0060"), 1, "the loop element is Int (a String binding of it is rejected)")
  assertEqual(bareTypeOrigin(cr, "List"), "Std.CollectionsHost", "the iterated List is the stdlib one")
}

test "for over the stdlib MapKeyCollection binds the key type; a same-named record does not (#7737)" {
  val ok = "package P\nimport Std.CollectionsHost\nfunc f(ks: in MapKeyCollection[String, Int]): Unit {\n  for k in ks {\n    val n: Int = k\n  }\n}\n"
  val crOk = checkWithImportedPackages(parse(ok).file, stdCollectionsHostPackages())
  assertEqualInt(countDiagCode(crOk, "T0060"), 1, "the key element is String (an Int binding of it is rejected)")
  val shadow = "package P\nrecord MapKeyCollection[K, V] {\n  k: K\n}\nfunc f(ks: in MapKeyCollection[String, Int]): Unit {\n  for k in ks {\n    val n: Int = k\n  }\n}\n"
  assertEqualInt(
    countDiagCode(parseCheck(shadow), "T0060"),
    0,
    "a same-named user record gets no key element type (it is not the stdlib collection)"
  )
  assertEqualInt(countDiagCode(parseCheck(shadow), "T0126"), 1, "a same-named user record is not iterable (#7781)")
}

test "indexing a user record named List is T0143 (#7737)" {
  val src = "package P\nrecord List[T] {\n  items: slice[T]\n}\nfunc f(l: in List[Int]): Int {\n  l[0]\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0143"), 1, "a user record List is not indexable")
  assertTrue(
    Str.contains(diagMessageFor(cr, "T0143"), "a record is not indexable"),
    "T0143 names the receiver kind: " + diagMessageFor(cr, "T0143")
  )
  assertTrue(
    Str.contains(diagMessageFor(cr, "T0143"), "only shares its name with the stdlib List"),
    "T0143 says the List is not the stdlib one"
  )
}

test "indexing a Lyric-native union or enum is T0143 (#7737)" {
  val src = "package P\nunion U {\n  case A\n  case B\n}\nenum E {\n  case X\n}\nfunc f(u: in U, e: in E): Unit {\n  val a = u[0]\n  val b = e[0]\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0143"), 2, "a union and an enum are not indexable")
}

test "indexing the stdlib List and Map types the element and value (#7737)" {
  val src = "package P\nimport Std.CollectionsHost\nfunc f(xs: in List[Int], m: in Map[String, Int]): Unit {\n  val a: String = xs[0]\n  val b: String = m[\"k\"]\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(countDiagCode(cr, "T0143"), 0, "the stdlib List and Map are indexable")
  assertEqualInt(countDiagCode(cr, "T0060"), 2, "xs[0] and m[k] are Int (String bindings of them are rejected)")
}

// #7765: the stdlib collection checks resolve `Std.CollectionsHost` ids
// through a per-table memo.  Each pair below puts a user type of the same
// name in the SAME table as the stdlib one (the user type shadows the bare
// name; the stdlib one is spelled qualified), so a memo that confused the two
// -- or cached a lookup made before the stdlib package was registered --
// would classify both the same way.
test "for over the stdlib MapValueCollection binds the value type; a same-named record in the same table does not (#7765)" {
  val src = "package P\nimport Std.CollectionsHost\nrecord MapValueCollection[K, V] {\n  v: V\n}\n" +
    "func f(hosted: in Std.CollectionsHost.MapValueCollection[String, Int], mine: in MapValueCollection[String, Int]): Unit {\n" +
    "  for a in hosted {\n    val s: String = a\n  }\n  for b in mine {\n    val t: String = b\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(
    countDiagCode(cr, "T0060"),
    1,
    "only the stdlib collection's loop binds its Int value (a String binding of it is rejected)"
  )
}

test "indexing a same-named MapValueCollection record is T0143; the stdlib one keeps its lenient indexing (#7765)" {
  val src = "package P\nimport Std.CollectionsHost\nrecord MapValueCollection[K, V] {\n  v: V\n}\n" +
    "func f(hosted: in Std.CollectionsHost.MapValueCollection[String, Int], mine: in MapValueCollection[String, Int]): Unit {\n" +
    "  val a = hosted[0]\n  val b = mine[0]\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(countDiagCode(cr, "T0143"), 1, "only the user record is rejected as not indexable")
  assertTrue(
    Str.contains(diagMessageFor(cr, "T0143"), "only shares its name with the stdlib MapValueCollection"),
    "T0143 says the MapValueCollection is not the stdlib one: " + diagMessageFor(cr, "T0143")
  )
}

test "indexing a same-named Map record is T0143; the stdlib Map types its value (#7765)" {
  val src = "package P\nimport Std.CollectionsHost\nrecord Map[K, V] {\n  k: K\n}\n" +
    "func f(hosted: in Std.CollectionsHost.Map[String, Int], mine: in Map[String, Int]): Unit {\n" +
    "  val a: String = hosted[\"k\"]\n  val b = mine[\"k\"]\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(countDiagCode(cr, "T0060"), 1, "hosted[k] is the stdlib Map's Int value")
  assertEqualInt(countDiagCode(cr, "T0143"), 1, "only the user record Map is rejected as not indexable")
  assertTrue(
    Str.contains(diagMessageFor(cr, "T0143"), "only shares its name with the stdlib Map"),
    "T0143 says the Map is not the stdlib one: " + diagMessageFor(cr, "T0143")
  )
}

test "indexing a slice, a String, and an extern type is not T0143 (#7737)" {
  val src = "package P\nextern type Bag[T] = \"System.Collections.Generic.List`1\"\nfunc f(s: in slice[Int], t: in String, b: in Bag[Int]): Unit {\n  val a: Int = s[0]\n  val c: Char = t[0]\n  val d = b[0]\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0143"), 0, "slices, strings and extern receivers keep their indexing")
  assertEqualInt(diagCount(cr), 0, "no other diagnostics")
}

test "count and toArray on a user record named List are unknown members (#7737)" {
  val src = "package P\nrecord List[T] {\n  items: slice[T]\n}\nfunc f(l: in List[Int]): Unit {\n  val n: Int = l.count\n  val a: slice[Int] = l.toArray()\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0113"), 2, "neither count nor toArray exists on a user record List")
  assertTrue(
    diagMessagesContain(cr, "only shares its name with the stdlib List"),
    "T0113 says the List is not the stdlib one"
  )
}

test "count and toArray on the stdlib List are typed (#7737)" {
  val src = "package P\nimport Std.CollectionsHost\nfunc f(xs: in List[Int]): Unit {\n  val n: String = xs.count\n  val a: slice[String] = xs.toArray()\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(countDiagCode(cr, "T0113"), 0, "count and toArray exist on the stdlib List")
  assertEqualInt(
    countDiagCode(cr, "T0060"),
    2,
    "count is Int and toArray() is slice[Int] (mismatching bindings rejected)"
  )
}

test "a slice passed to a user record named List gets no .toList() hint (#7737)" {
  val src = "package P\nrecord List[T] { }\nfunc g(xs: in List[Int]): Int { 0 }\nfunc f(xs: in slice[Int]): Int { g(xs) }\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0043"), 1, "a slice does not satisfy a user record List")
  assertTrue(not diagMessagesContain(cr, "use .toList()"), ".toList() builds the stdlib List, so it is not suggested")
  assertTrue(
    diagMessagesContain(cr, "only shares its name with the stdlib List"),
    "the message says this List is not the stdlib one: " + diagMessageFor(cr, "T0043")
  )
}

test "a user record named List passed to a slice gets no .toArray() hint (#7737)" {
  val src = "package P\nrecord List[T] { }\nfunc g(xs: in slice[Int]): Int { 0 }\nfunc f(xs: in List[Int]): Int { g(xs) }\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0043"), 1, "a user record List does not satisfy a slice")
  assertTrue(not diagMessagesContain(cr, ".toArray()"), "a user record List has no .toArray()")
}

test "the stdlib List passed to a slice still suggests .toArray() (#7737)" {
  val src = "package P\nimport Std.CollectionsHost\nfunc g(xs: in slice[Int]): Int { 0 }\nfunc f(xs: in List[Int]): Int { g(xs) }\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(countDiagCode(cr, "T0043"), 1, "a List[Int] value does not satisfy slice[Int]")
  assertTrue(diagMessagesContain(cr, "use .toArray()"), "the T0043 message suggests .toArray()")
}

test "a slice with the wrong element type gets no .toList() hint against the stdlib List (#7737)" {
  val src = "package P\nimport Std.CollectionsHost\nfunc g(xs: in List[Int]): Int { 0 }\nfunc f(xs: in slice[String]): Int { g(xs) }\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
  assertEqualInt(countDiagCode(cr, "T0043"), 1, "slice[String] does not satisfy List[Int]")
  assertTrue(not diagMessagesContain(cr, "use .toList()"), ".toList() would give List[String], so it is not suggested")
}

test "a non-empty list literal for a user record named List has an accurate message (#7737)" {
  val src = "package P\nrecord List[T] { }\nrecord R { items: List[Int] }\nfunc f(): R { R(items = [1, 2]) }\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0104"), 1, "the literal does not construct a user record List")
  val msg = diagMessageFor(cr, "T0104")
  assertTrue(Str.contains(msg, "has type slice[Int]"), "the literal's own type is named: " + msg)
  assertTrue(not Str.contains(msg, "use .toList()"), "no .toList() advice for a literal: " + msg)
  assertTrue(
    Str.contains(msg, "a list literal or .toList() only builds the stdlib List"),
    "the message explains the name clash: " + msg
  )
}

test "an empty list literal for a user record named List reads as an empty literal (#7737)" {
  val src = "package P\nrecord List[T] { }\nrecord R { items: List[Int] }\nfunc f(): R { R(items = []) }\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0104"), 1, "[] does not construct a user record List")
  val msg = diagMessageFor(cr, "T0104")
  assertTrue(
    Str.startsWith(msg, "argument for field 'items' is an empty list literal but field expects List[Int]"),
    "the empty literal is described as such: " + msg
  )
  assertTrue(not Str.contains(msg, "<error>"), "no <error> element type in the message: " + msg)
  assertTrue(not Str.contains(msg, "use .toList()"), "no .toList() advice for a literal: " + msg)
}

test "an empty list literal for a non-List field, binding, argument and return reads as an empty literal (#7737)" {
  val src = "package P\nrecord R { n: Int }\nfunc g(x: in Int): Int { x }\nfunc h(): Int {\n  return []\n}\nfunc f(): Unit {\n  val r = R(n = [])\n  val p = R([])\n  val v: Int = []\n  val c = g([])\n}\n"
  val cr = parseCheck(src)
  assertEqual(
    diagMessageFor(cr, "T0104"),
    "argument for field 'n' is an empty list literal but field expects Int",
    "named ctor field"
  )
  assertTrue(
    diagMessagesContain(cr, "positional argument 1 is an empty list literal but field 'n' expects Int"),
    "positional ctor field"
  )
  assertEqual(
    diagMessageFor(cr, "T0060"),
    "val binding declared as Int but initialiser is an empty list literal",
    "val initialiser"
  )
  assertEqual(
    diagMessageFor(cr, "T0043"),
    "argument (an empty list literal) does not match parameter type Int",
    "call argument"
  )
  assertEqual(
    diagMessageFor(cr, "T0065"),
    "returned value (an empty list literal) does not match declared return type Int",
    "return value"
  )
  assertTrue(not diagMessagesContain(cr, "<error>"), "no message renders the literal as slice[<error>]")
}

test "a non-empty list literal for a non-List field keeps its element type in the message (#7737)" {
  val src = "package P\nrecord R { n: Int }\nfunc f(): R { R(n = [1, 2]) }\n"
  assertEqual(
    diagMessageFor(parseCheck(src), "T0104"),
    "argument for field 'n' has type slice[Int] but field expects Int",
    "a non-empty literal is described by its inferred slice type, with no conversion hint"
  )
}

test "tryFrom on a range subtype returns the stdlib Result even with a local union Result (#7737)" {
  val shadow = "package App\nunion Result[T, E] {\n  case Ok(value: T)\n  case Err(error: E)\n}\ntype Age = Int range 0 ..= 150\nfunc f(): Unit {\n  val r: Result[Age, String] = Age.tryFrom(5)\n}\n"
  val crShadow = checkWithImportedPackages(parse(shadow).file, stdCorePackages())
  assertEqualInt(countDiagCode(crShadow, "T0060"), 1, "the stdlib Result tryFrom returns is not the local union Result")
  assertTrue(
    Str.contains(
      diagMessageFor(crShadow, "T0060"),
      "these are two different types named 'Result': the value is Std.Core.Result, the target is App.Result"
    ),
    "the identically-rendered types are told apart by package: " + diagMessageFor(crShadow, "T0060")
  )
  val ok = "package App\ntype Age = Int range 0 ..= 150\nfunc f(): Unit {\n  val r: Result[Age, String] = Age.tryFrom(5)\n  val bad: Result[Int, String] = Age.tryFrom(5)\n}\n"
  val cr = checkWithImportedPackages(parse(ok).file, stdCorePackages())
  assertEqualInt(
    countDiagCode(cr, "T0060"),
    1,
    "tryFrom is Result[Age, String]: only the Result[Int, String] binding fails"
  )
  assertEqual(bareTypeOrigin(cr, "Result"), "Std.Core", "the Result is Std.Core's")
}

test "String indexOf returns the stdlib Option even with a local union Option (#7737)" {
  val shadow = "package App\nimport Std.String\nunion Option[T] {\n  case Some(value: T)\n  case None\n}\nfunc f(): Unit {\n  val r: Option[Int] = \"abc\".indexOf(\"b\")\n}\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(shadow).file, stdCorePackages()), "T0060"),
    1,
    "the stdlib Option indexOf returns is not the local union Option"
  )
  val ok = "package App\nimport Std.String\nfunc f(): Unit {\n  val r: Option[Int] = \"abc\".indexOf(\"b\")\n  val bad: Option[String] = \"abc\".indexOf(\"b\")\n}\n"
  val cr = checkWithImportedPackages(parse(ok).file, stdCorePackages())
  assertEqualInt(countDiagCode(cr, "T0060"), 1, "indexOf is Option[Int]: only the Option[String] binding fails")
  assertEqual(bareTypeOrigin(cr, "Option"), "Std.Core", "the Option is Std.Core's")
}

// ─── Module-level destructuring `val` (#7763) ─────────────────────────────────
// The grammar's `ValDecl` takes a pattern; each name an irrefutable module
// `val` pattern binds is a module value, and a refutable one is T0144.
test "a module-level tuple val binds each name (#7763)" {
  val src = "package P\nval (a, b) = (1, \"x\")\nfunc f(): Int { a }\nfunc g(): String { b }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "a and b resolve with their element types")
  val bad = "package P\nval (a, b) = (1, \"x\")\nfunc f(): String { a }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0070"), "a is Int, not String")
}

test "a module-level tuple val over a call binds each name (#7763)" {
  val src = "package P\nfunc pair(): (Int, String) { (1, \"x\") }\nval (n, s) = pair()\n" +
    "func f(): Int { n }\nfunc g(): String { s }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "names projected out of the call's tuple")
  val bad = "package P\nfunc pair(): (Int, String) { (1, \"x\") }\nval (n, s) = pair()\nfunc f(): Int { s }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0070"), "s is String, not Int")
}

test "nested, wildcard, @-binding and annotated module vals bind their names (#7763)" {
  val src = "package P\nfunc pair(): (Int, Bool) { (1, true) }\n" + "val (a, (b, _)) = (1, (true, \"z\"))\n" +
    "val whole @ (x, y) = pair()\n" +
    "val (lo, hi): (Int, Long) = (1, 2)\n" +
    "val (_, only) = pair()\n" +
    "func f(): Int { a + x + lo }\nfunc g(): Bool { b and y and only }\nfunc h(): Long { hi }\n" +
    "func k(): (Int, Bool) { whole }\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "every bound name resolves with its type")
}

test "a refutable module val pattern is T0144 naming the form (#7763)" {
  val ctor = parseCheck("package P\nval Some(x) = Some(1)\n")
  assertTrue(hasDiagCode(ctor, "T0144"), "constructor pattern")
  assertTrue(diagMessagesContain(ctor, "a constructor pattern"), "names the constructor form")
  val tyTest = parseCheck("package P\nval n is Int = 3\n")
  assertTrue(hasDiagCode(tyTest, "T0144"), "type-test pattern")
  assertTrue(diagMessagesContain(tyTest, "a type-test pattern"), "names the type-test form")
  assertTrue(diagMessagesContain(tyTest, "val <name>: <Type> = ..."), "suggests an annotation")
  val nested = parseCheck("package P\nval (a, 0) = (1, 0)\n")
  assertTrue(diagMessagesContain(nested, "a literal pattern"), "a refutable element inside a tuple")
  assertEqualInt(countDiagCode(parseCheck("package P\nval (a, _) = (1, 0)\n"), "T0144"), 0, "irrefutable: no T0144")
}

test "a pub destructuring val is visible to an importing package (#7763)" {
  val packages: List[ImportedPackage] = newList()
  packages.add(
    rulePkg(
      "Lib",
      "package Lib\npub val (lo, hi): (Int, Int) = (1, 9)\npub val (name, _) = (\"n\", 0)\n" +
        "pub func pair(): (Int, String) { (2, \"p\") }\npub val (pn, ps) = pair()\n"
    )
  )
  val src = "package App\nimport Lib\nfunc f(): Int { lo + hi + pn }\nfunc g(): String { name + ps }\n"
  assertEqualInt(diagCount(checkWithImportedPackages(parse(src).file, packages)), 0, "lo, hi, name, pn and ps resolve")
  val bad = "package App\nimport Lib\nfunc f(): Int { ps }\n"
  assertTrue(hasDiagCode(checkWithImportedPackages(parse(bad).file, packages), "T0070"), "ps is a String")
}

func itemValName(it: in Item): String {
  match it.kind {
    case IVal(vd) -> match vd.pattern.kind { case PBinding(n, None) -> n; case _ -> "<pattern>" }
    case _ -> "<item>"
  }
}

func itemIsPub(it: in Item): Bool {
  match it.visibility {
    case Some(VisPub(_)) -> true
    case _ -> false
  }
}

test "desugaring splits a tuple literal and projects anything else through one private temp (#7763)" {
  val lit = desugarModuleValPatterns(parse("package P\npub val (a, b) = (1, 2)\n").file)
  assertEqualInt(lit.file.items.count, 2, "tuple literal: one val per element, no temp")
  assertEqual(itemValName(lit.file.items[0]), "a", "first element")
  assertEqual(itemValName(lit.file.items[1]), "b", "second element")
  assertTrue(itemIsPub(lit.file.items[1]), "keeps pub")
  val call = desugarModuleValPatterns(
    parse("package P\nfunc pair(): (Int, Int) { (1, 2) }\npub val (a, b) = pair()\n").file
  )
  assertEqualInt(call.file.items.count, 4, "call: the function, one temp, then a and b")
  assertEqual(itemValName(call.file.items[1]), "__lyric_modval_0", "temp holds the value once")
  assertTrue(itemIsPub(call.file.items[1]), "temp has the declaration's visibility")
  assertEqual(itemValName(call.file.items[2]), "a", "a after the temp")
  assertTrue(itemIsPub(call.file.items[3]), "b keeps pub")
  val again = desugarModuleValPatterns(call.file)
  assertEqualInt(again.file.items.count, 4, "idempotent")
}

test "a module val tuple pattern its initializer's type cannot match is T0144 (#7763)" {
  val notTuple = parseCheck("package P\nfunc five(): Int { 5 }\nval (a, b) = five()\n")
  assertEqualInt(countDiagCode(notTuple, "T0144"), 1, "tuple pattern over an Int, reported once")
  assertTrue(
    diagMessagesContain(notTuple, "2-element tuple pattern is bound to a value of type Int"),
    "names the shapes"
  )
  val arity = parseCheck("package P\nval (a, b) = (1, 2, 3)\n")
  assertEqualInt(countDiagCode(arity, "T0144"), 1, "arity mismatch")
  val nested = parseCheck("package P\nval (a, (b, c)) = (1, 2)\n")
  assertEqualInt(countDiagCode(nested, "T0144"), 1, "nested shape mismatch")
}

test "each projected module val is recorded with its checked type (#7763)" {
  val cr = parseCheck("package P\nfunc pair(): (Int, String) { (1, \"x\") }\nval (n, s) = pair()\n")
  assertEqualInt(diagCount(cr), 0, "checks cleanly")
  assertTrue(cr.symbols.moduleValTypes.containsKey("n"), "n typed")
  assertTrue(cr.symbols.moduleValTypes.containsKey("s"), "s typed")
  assertTrue(cr.symbols.moduleValTypes.containsKey("__lyric_modval_0"), "temp typed")
  match mapGet(cr.symbols.moduleValTypes, "s") {
    case Some(te) -> assertEqual(typeExprText(te), "String", "s is a String")
    case None -> assertTrue(false, "s has no recorded type")
  }
}

// #7801: an unannotated binding is open (#7788) only when its initializer
// resolved to one of the stdlib's evidence-free constructors -- a
// `Std.CollectionsHost` `newList`/`newListWithCapacity`/`newMap`, or the
// stdlib `Option`'s `None` -- never because the callee or case is spelled
// that way.
func openSiteCount(cr: in CheckResult): Int {
  cr.symbols.openBindingSites.count
}

func stdCtorPackages(): List[ImportedPackage] {
  val host = parse(
    "package Std.CollectionsHost\nextern type List[T] = \"System.Collections.Generic.List`1\"\n" +
      "extern type Map[K, V] = \"System.Collections.Generic.Dictionary`2\"\n" +
      "pub func newList[T](): List[T] = ()\npub func newListWithCapacity[T](capacity: in Int): List[T] = ()\n" +
      "pub func newMap[K, V](): Map[K, V] = ()\n"
  )
  val core = parse("package Std.Core\npub union Option[T] {\n  case Some(value: T)\n  case None\n}\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Std.CollectionsHost",
      items = host.file.items,
      imports = collectImportNames(host.file.imports),
      wholeImports = collectWholeImportNames(host.file.imports)
    )
  )
  packages.add(
    ImportedPackage(
      name = "Std.Core",
      items = core.file.items,
      imports = collectImportNames(core.file.imports),
      wholeImports = collectWholeImportNames(core.file.imports)
    )
  )
  packages
}

test "a package's own newList is not an open binding (#7801)" {
  val src = "package P\nrecord MyBag[T] {\n  items: slice[T]\n}\nfunc newList[T](): MyBag[T] {\n  MyBag(items = [])\n}\n" +
    "func f(): Unit {\n  val b = newList()\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "the user newList checks cleanly")
  assertEqualInt(openSiteCount(cr), 0, "a user newList builds no open binding")
}

test "a local union's None case is not an open binding (#7801)" {
  val src = "package P\nunion Maybe[T] {\n  case Just(value: T)\n  case None\n}\nfunc f(): Unit {\n  val m = None\n}\n"
  assertEqualInt(openSiteCount(parseCheck(src)), 0, "a local None builds no open binding")
}

test "the stdlib newList, newListWithCapacity, newMap and None are open bindings (#7801)" {
  val src = "package P\nimport Std.CollectionsHost\nimport Std.Core\nfunc f(): Unit {\n  val xs = newList()\n" +
    "  val ys = newListWithCapacity(4)\n  val m = newMap()\n  val o = None\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCtorPackages())
  assertEqualInt(openSiteCount(cr), 4, "each stdlib evidence-free initializer is open")
}

// #7863: the open-tuple inference (#7855) reaches a name bound to a nested
// sub-tuple, a type parameter fixed through a pattern-bound name, and a
// tuple literal matched directly.
func localBindingTypesText(cr: in CheckResult): String {
  val keys = mapKeys(cr.symbols.localBindingTypeSites)
  var acc = ""
  var i = 0
  while i < keys.count {
    match mapGet(cr.symbols.localBindingTypeSites, keys[i]) {
      case Some(te) -> {
        acc = acc + typeExprText(te) + "; "
      }
      case None -> ()
    }
    i = i + 1
  }
  acc
}

func localBindingTypeRecorded(cr: in CheckResult, text: in String): Bool {
  val keys = mapKeys(cr.symbols.localBindingTypeSites)
  var i = 0
  while i < keys.count {
    match mapGet(cr.symbols.localBindingTypeSites, keys[i]) {
      case Some(te) -> if typeExprText(te) == text { return true }
      case None -> ()
    }
    i = i + 1
  }
  false
}

func tuplePatternBindingRecorded(cr: in CheckResult, text: in String): Bool {
  val keys = mapKeys(cr.symbols.tuplePatternBindingSites)
  var i = 0
  while i < keys.count {
    match mapGet(cr.symbols.tuplePatternBindingSites, keys[i]) {
      case Some(site) -> if typeExprText(site.bindingType) == text { return true }
      case None -> ()
    }
    i = i + 1
  }
  false
}

test "a name bound to a nested sub-tuple fixes its open elements (#7863)" {
  val src = "package P\nimport Std.CollectionsHost\nimport Std.Core\n" +
    "func take(p: in (Option[Int], Int)): Int {\n  0\n}\n" +
    "func f(): Int {\n  val t = ((None, 1), 2)\n  val (inner, n) = t\n  take(inner)\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCtorPackages())
  assertEqualInt(diagCount(cr), 0, "checks cleanly")
  assertTrue(
    localBindingTypeRecorded(cr, "((Option[Int], Int), Int)"),
    "the tuple is typed from the use of inner: " + localBindingTypesText(cr)
  )
  assertTrue(tuplePatternBindingRecorded(cr, "(Option[Int], Int)"), "inner is recorded at its element type")
}

test "a type parameter fixed through a pattern-bound name is spelled (#7863)" {
  val src = "package P\nimport Std.CollectionsHost\nimport Std.Core\n" +
    "func f[T](x: in T): Unit {\n  val t = (newList(), 1)\n  val (xs, n) = t\n  xs.add(x)\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCtorPackages())
  assertEqualInt(diagCount(cr), 0, "checks cleanly")
  assertTrue(localBindingTypeRecorded(cr, "(List[T], Int)"), "the tuple is typed over T")
  assertTrue(tuplePatternBindingRecorded(cr, "List[T]"), "xs is recorded as a List[T]")
}

test "a tuple literal matched directly is typed from its arms (#7863)" {
  val src = "package P\nimport Std.CollectionsHost\nimport Std.Core\n" +
    "func take(o: in Option[Int], n: in Int): Int {\n  n\n}\n" +
    "func f(): Int {\n  match (None, 5) {\n    case (o, n) -> take(o, n)\n  }\n}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCtorPackages())
  assertEqualInt(diagCount(cr), 0, "checks cleanly")
  assertTrue(
    localBindingTypeRecorded(cr, "(Option[Int], Int)"),
    "the scrutinee is typed from o's use: " + localBindingTypesText(cr)
  )
  assertTrue(tuplePatternBindingRecorded(cr, "Option[Int]"), "o is recorded at its element type")
}

// #7778: a local `val` destructures its initializer with no failure path, so
// a pattern that cannot match every value of the initializer's type is T0146
// (the local counterpart of the module-level T0144, #7763).
test "val (a, b) = 5 is T0146 (#7778)" {
  val src = "package P\nfunc f(): Unit {\n  val (a, b) = 5\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0146"), 1, "a tuple pattern over an Int")
  assertTrue(
    Str.contains(diagMessageFor(cr, "T0146"), "2-element tuple pattern is bound to a value of type Int"),
    "T0146 names the arity and the type: " + diagMessageFor(cr, "T0146")
  )
}

test "a tuple pattern of the wrong arity is T0146 (#7778)" {
  val src = "package P\nfunc f(): Unit {\n  val (a, b) = (1, 2, 3)\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0146"), 1, "a 2-element pattern over a 3-tuple")
}

test "a nested tuple pattern of the wrong arity is T0146 (#7778)" {
  val src = "package P\nfunc f(): Unit {\n  val (a, (b, c)) = (1, (2, 3, 4))\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0146"), 1, "the inner pattern is a 2-element one over a 3-tuple")
}

test "an annotated tuple pattern checks against the annotation (#7778)" {
  val src = "package P\nfunc f(): Unit {\n  val (a, b): Int = 5\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0146"), 1, "a tuple pattern declared Int")
}

test "a rejected local pattern does not cascade (#7778)" {
  val src = "package P\nfunc f(): Unit {\n  val (a, b) = 5\n  val s: String = a\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0146"), 1, "the pattern is reported")
  assertEqualInt(countDiagCode(cr, "T0060"), 0, "its names are not typed against a shape they do not have")
}

test "a correct nested tuple pattern types its names (#7778)" {
  val src = "package P\nfunc f(): Unit {\n  val (a, (b, _)) = (1, (\"x\", 2.5))\n  val n: Int = b\n  val m: Int = a\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0146"), 0, "the shapes agree")
  assertEqualInt(countDiagCode(cr, "T0060"), 1, "b is a String, so an Int binding of it is rejected; a is an Int")
}

test "a constructor pattern over a two-case union is T0146 (#7778)" {
  val src = "package P\nunion Maybe {\n  case Just(value: Int)\n  case Nothing\n}\nfunc f(m: in Maybe): Unit {\n  val Just(v) = m\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0146"), 1, "Just matches only one case")
  assertTrue(
    Str.contains(diagMessageFor(cr, "T0146"), "`match`"),
    "T0146 suggests a match: " + diagMessageFor(cr, "T0146")
  )
}

test "a literal inside a local tuple pattern is T0146 (#7778)" {
  val src = "package P\nfunc f(): Unit {\n  val (1, b) = (1, 2)\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0146"), 1, "a literal pattern can fail")
}

// #7808: codegen casts a local record pattern's initializer to the head's
// record and reads every field, shorthand ones included, unconditionally.
test "a record pattern over a non-record is T0146 (#7808)" {
  val src = "package P\nrecord Pt {\n  x: Int\n  y: Int\n}\nfunc f(n: in Int): Unit {\n  val Pt { x, y } = n\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0146"), 1, "a shorthand-only record pattern over an Int")
  assertTrue(
    Str.contains(diagMessageFor(cr, "T0146"), "record pattern (`Pt { ... }`) is bound to a value of type Int"),
    "T0146 names the head and the type: " + diagMessageFor(cr, "T0146")
  )
}

test "a record pattern naming another record is T0146 (#7808)" {
  val src = "package P\nrecord Pt {\n  x: Int\n}\nrecord Qt {\n  x: Int\n}\n" +
    "func f(q: in Qt): Unit {\n  val Pt { x } = q\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0146"), 1, "Pt is not the initializer's record")
}

test "a record pattern naming a missing field is T0146 (#7808)" {
  val src = "package P\nrecord Pt {\n  x: Int\n}\nfunc f(p: in Pt): Unit {\n  val Pt { x, z } = p\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0146"), 1, "Pt has no field z")
  assertTrue(
    Str.contains(diagMessageFor(cr, "T0146"), "field `z`"),
    "T0146 names the field: " + diagMessageFor(cr, "T0146")
  )
}

test "a nested record pattern over the wrong type is T0146 (#7808)" {
  val src = "package P\nrecord Pt {\n  x: Int\n}\nfunc f(p: in Pt): Unit {\n  val (Pt { x }, b) = (1, p)\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0146"), 1, "the first element is an Int")
}

test "a constructor pattern over a non-union is T0146 (#7808)" {
  val src = "package P\nunion Boxed {\n  case Box(value: Int)\n}\nfunc f(n: in Int): Unit {\n  val Box(v) = n\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0146"), 1, "an Int has no cases")
}

test "a record pattern with a named field pattern is irrefutable locally (#7808)" {
  val src = "package P\nrecord Pt {\n  x: Int\n  y: Int\n}\nfunc f(p: in Pt): Unit {\n  val Pt { x = a, y } = p\n" +
    "  val n: Int = a + y\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0146"), 0, "the head names the record and both fields exist")
  assertEqualInt(countDiagCode(cr, "T0060"), 0, "a and y are Ints")
}

test "a sole-case constructor, a record pattern and @ are irrefutable locally (#7778)" {
  val src = "package P\nunion Boxed {\n  case Box(value: Int)\n}\nrecord Pt {\n  x: Int\n  y: Int\n}\n" +
    "func f(b: in Boxed, p: in Pt): Unit {\n  val Box(v) = b\n  val Pt { x, y } = p\n  val whole @ (l, r) = (1, 2)\n" +
    "  val (_, q) = (p, b)\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0146"), 0, "every pattern matches every value of its type")
}

// #7811: a module-level `val`'s initialiser, a field's default and a
// parameter's default are checked against the declared type like a local
// binding's initialiser, in the declaring package, once each.
test "a module val initialiser that mismatches its declared type is T0060 (#7811)" {
  val cr = parseCheck("package P\nval g: Long = \"str\"\nfunc f(): Long { g + g }\n")
  assertEqualInt(countDiagCode(cr, "T0060"), 1, "reported once, not again at each read")
  assertTrue(diagMessagesContain(cr, "val binding declared as Long but initialiser has type String"), "message")
  val oor = parseCheck("package P\nval g: Int = 3000000000\n")
  assertEqualInt(countDiagCode(oor, "T0015"), 1, "an out-of-range literal is T0015")
  assertEqualInt(countDiagCode(oor, "T0060"), 0, "and not T0060 as well")
  val unknown = parseCheck("package P\nval g: Int = nope\n")
  assertTrue(hasDiagCode(unknown, "T0020"), "an unknown name in the initialiser is reported")
}

test "a field default that mismatches its field type is T0060 (#7811)" {
  val rec = parseCheck("package P\nrecord R {\n  v: Long = \"str\"\n}\n")
  assertEqualInt(countDiagCode(rec, "T0060"), 1, "record field")
  assertTrue(diagMessagesContain(rec, "field 'R.v' declared as Long but its default has type String"), "message")
  val exposedRec = parseCheck("package P\nexposed record E {\n  w: Int = \"s\"\n}\n")
  assertEqualInt(countDiagCode(exposedRec, "T0060"), 1, "exposed record field")
  val opaqueTy = parseCheck("package P\nopaque type O {\n  w: Int = true\n}\n")
  assertEqualInt(countDiagCode(opaqueTy, "T0060"), 1, "opaque field")
  val prot = parseCheck("package P\nprotected type C {\n  var n: Long = \"s\"\n  func get(): Long { n }\n}\n")
  assertEqualInt(countDiagCode(prot, "T0060"), 1, "protected field")
}

test "a parameter default that mismatches its parameter type is T0060 (#7811)" {
  val fn = parseCheck("package P\nfunc d(x: in Long = \"s\"): Long { x }\n")
  assertEqualInt(countDiagCode(fn, "T0060"), 1, "function parameter")
  assertTrue(
    diagMessagesContain(fn, "parameter 'x' of 'd' declared as Long but its default has type String"),
    "message"
  )
  val method = parseCheck("package P\nrecord R {\n  n: Int\n  func m(self: in R, x: in Int = \"s\"): Int { x }\n}\n")
  assertEqualInt(countDiagCode(method, "T0060"), 1, "record method parameter")
  val iface = parseCheck("package P\ninterface I {\n  func m(x: in Long = \"s\"): Unit\n}\n")
  assertEqualInt(countDiagCode(iface, "T0060"), 1, "interface member parameter")
  val implM = parseCheck(
    "package P\ninterface I {\n  func m(x: in Long): Long\n}\nrecord R {\n  n: Int\n}\nimpl I for R {\n  func m(self: in R, x: in Long = false): Long { x }\n}\n"
  )
  assertEqualInt(countDiagCode(implM, "T0060"), 1, "impl method parameter")
}

test "a declared initialiser that widens records its conversion (#7811)" {
  val ok = parseCheck(
    "package P\nval u: UInt = 4000000000u32\nval g: ULong = u\nval i: Int = 1\nval l: Long = i\nrecord R {\n  v: ULong = u\n}\nfunc d(x: in ULong = u): ULong { x }\n"
  )
  assertEqualInt(diagCount(ok), 0, "lossless widenings are accepted")
  assertEqualInt(ok.symbols.argConversionSites.count, 3, "each UInt to ULong widening is a conversion site")
}

// #7777: a module value's initialiser is checked once, at its declaration,
// whether the value is used or not; a read never re-reports its errors.
test "a module val initialiser's errors are reported once, at the declaration (#7777)" {
  val unused = parseCheck("package P\nval x: Int = \"s\"\n")
  assertEqualInt(countDiagCode(unused, "T0060"), 1, "unused annotated val")
  val used = parseCheck("package P\nval x: Int = \"s\"\nfunc f(): Int { x }\nfunc g(): Int { x + x }\n")
  assertEqualInt(countDiagCode(used, "T0060"), 1, "used annotated val, still once")
  val unusedBare = parseCheck("package P\nval y = nope\n")
  assertEqualInt(countDiagCode(unusedBare, "T0020"), 1, "unused unannotated val")
  val usedBare = parseCheck("package P\nval y = nope\nfunc f(): Unit {\n  val a = y\n  val b = y\n}\n")
  assertEqualInt(countDiagCode(usedBare, "T0020"), 1, "used unannotated val, still once")
  val destructured = parseCheck("package P\nfunc pair(): (Int, String) { (1, \"x\") }\nval (n, s) = pair()\n")
  assertEqualInt(diagCount(destructured), 0, "a destructuring val checks its initialiser once, cleanly")
}

// #7820: arguments pair with parameters by name, then in order; a named
// argument naming no parameter, or a parameter with no default left without
// an argument, is T0042 for a function and a method alike.
test "an unpaired call argument or unsupplied required parameter is T0042 (#7820)" {
  val fnSrc = "package P\nfunc f(a: in Int, b: in Int = 0): Int { a + b }\n"
  val missing = parseCheck(fnSrc + "func g(): Int { f(b = 2) }\n")
  assertEqualInt(countDiagCode(missing, "T0042"), 1, "f(b = 2) leaves `a` without an argument")
  assertTrue(diagMessagesContain(missing, "missing argument for parameter 'a', which has no default"), "message")
  val unknown = parseCheck(fnSrc + "func g(): Int { f(1, q = 2) }\n")
  assertEqualInt(countDiagCode(unknown, "T0042"), 1, "f(1, q = 2) names no parameter")
  assertTrue(diagMessagesContain(unknown, "no parameter named 'q'"), "message")
  val fine = parseCheck(fnSrc + "func g(): Int { f(1) + f(b = 2, a = 1) + f(1, b = 2) }\n")
  assertEqualInt(countDiagCode(fine, "T0042"), 0, "defaulted and named forms are accepted")
  val recSrc = "package P\nrecord A {\n  n: Int\n  func m(self: in A, a: in Int, b: in Int = 1): Int { a + b }\n}\n"
  val mMissing = parseCheck(recSrc + "func g(x: in A): Int { x.m(b = 2) }\n")
  assertEqualInt(countDiagCode(mMissing, "T0042"), 1, "a method call leaving `a` without an argument")
  val mFine = parseCheck(recSrc + "func g(x: in A): Int { x.m(1) + x.m(b = 2, a = 1) }\n")
  assertEqualInt(countDiagCode(mFine, "T0042"), 0, "a method's defaulted and named forms are accepted")
}

// #7846: a parameter given twice, by name or by name after a leading
// positional argument already took it, is T0042 at the repeated argument;
// the same for a constructor's or union case's field is T0104.
test "a function or method parameter given more than once is T0042 (#7846)" {
  val fnSrc = "package P\nfunc f(a: in Int, b: in Int = 0): Int { a + b }\n"
  val twice = parseCheck(fnSrc + "func g(): Int { f(a = 1, a = 2) }\n")
  assertEqualInt(countDiagCode(twice, "T0042"), 1, "f(a = 1, a = 2): " + diagCodesOf(twice))
  assertTrue(diagMessagesContain(twice, "parameter 'a' is given more than once"), "message")
  val posThenNamed = parseCheck(fnSrc + "func g(): Int { f(1, a = 2) }\n")
  assertEqualInt(countDiagCode(posThenNamed, "T0042"), 1, "f(1, a = 2): " + diagCodesOf(posThenNamed))
  assertTrue(
    diagMessagesContain(
      posThenNamed,
      "parameter 'a' is given more than once (positional argument 1 already supplies it)"
    ),
    "message"
  )
  val fine = parseCheck(fnSrc + "func g(): Int { f(b = 2, 1) + f(1, b = 2) + f(a = 1, b = 2) }\n")
  assertEqualInt(diagCount(fine), 0, "each parameter given once: " + diagCodesOf(fine))
  val recSrc = "package P\nrecord A {\n  n: Int\n  func m(self: in A, a: in Int, b: in Int = 1): Int { a + b }\n}\n"
  val mTwice = parseCheck(recSrc + "func g(x: in A): Int { x.m(a = 1, a = 2) }\n")
  assertEqualInt(countDiagCode(mTwice, "T0042"), 1, "x.m(a = 1, a = 2): " + diagCodesOf(mTwice))
  val mPos = parseCheck(recSrc + "func g(x: in A): Int { x.m(1, a = 2) }\n")
  assertEqualInt(countDiagCode(mPos, "T0042"), 1, "x.m(1, a = 2): " + diagCodesOf(mPos))
  val implSrc = "package P\ninterface S {\n  func area(self: in Self, k: in Int, j: in Int = 0): Int\n}\n" +
    "record Q {\n  s: Int\n}\nimpl S for Q {\n  func area(self: in Q, k: in Int, j: in Int = 0): Int { self.s * k + j }\n}\n"
  val viaImpl = parseCheck(implSrc + "func g(q: in Q): Int { q.area(k = 1, k = 2) }\n")
  assertEqualInt(countDiagCode(viaImpl, "T0042"), 1, "impl method: " + diagCodesOf(viaImpl))
  val viaIface = parseCheck(implSrc + "func g(s: in S): Int { s.area(1, k = 2) }\n")
  assertEqualInt(countDiagCode(viaIface, "T0042"), 1, "interface member: " + diagCodesOf(viaIface))
  val ext = parseCheck(externAbsSrc("  cAbs(x = 1, x = 2)\n"))
  assertTrue(diagMessagesContain(ext, "parameter 'x' is given more than once"), "extern func: " + diagCodesOf(ext))
}

// A repeated argument is one mistake: it is reported once, not again as an
// arity mismatch or once per extra repetition (PR #8011 review).
test "a parameter repeated past the arity is one T0042" {
  val fnSrc = "package P\nfunc f(a: in Int, b: in Int): Int { a + b }\n"
  val thrice = parseCheck(fnSrc + "func g(): Int { f(a = 1, a = 2, a = 3) }\n")
  assertEqualInt(countDiagCode(thrice, "T0042"), 1, "f(a = 1, a = 2, a = 3): " + diagCodesOf(thrice))
  assertTrue(diagMessagesContain(thrice, "parameter 'a' is given more than once"), "message")
  val recSrc = "package P\nrecord A {\n  n: Int\n  func m(self: in A, a: in Int): Int { a }\n}\n"
  val mThrice = parseCheck(recSrc + "func g(x: in A): Int { x.m(a = 1, a = 2, a = 3) }\n")
  assertEqualInt(countDiagCode(mThrice, "T0042"), 1, "x.m(a = 1, a = 2, a = 3): " + diagCodesOf(mThrice))
  // Checks that do not depend on pairing the repeated name still run: a name
  // that names no parameter, and an argument named exactly once.
  val unknown = parseCheck(fnSrc + "func g(): Int { f(a = 1, a = 2, zzz = 3) }\n")
  assertEqualInt(countDiagCode(unknown, "T0042"), 2, "f(a = 1, a = 2, zzz = 3): " + diagCodesOf(unknown))
  assertTrue(diagMessagesContain(unknown, "parameter 'a' is given more than once"), "the repeat")
  assertTrue(diagMessagesContain(unknown, "no parameter named 'zzz'"), "the unknown name")
  assertFalse(diagMessagesContain(unknown, "expected 2 argument(s)"), "no arity mismatch")
  val badType = parseCheck(fnSrc + "func g(): Int { f(a = 1, a = 2, b = \"s\") }\n")
  assertEqualInt(countDiagCode(badType, "T0042"), 1, "f(a = 1, a = 2, b = \"s\"): " + diagCodesOf(badType))
  assertEqualInt(countDiagCode(badType, "T0043"), 1, "the argument named once is still type-checked")
  // A positional argument before the first named one pairs with the
  // parameter at its position whatever the call repeats (PR #8023 review).
  val leading = parseCheck(fnSrc + "func g(): Int { f(\"s\", b = 1, b = 2) }\n")
  assertEqualInt(countDiagCode(leading, "T0042"), 1, "f(\"s\", b = 1, b = 2): " + diagCodesOf(leading))
  assertEqualInt(countDiagCode(leading, "T0043"), 1, "the leading positional argument is still type-checked")
}

test "a constructor or union-case field given more than once is T0104 (#7846)" {
  val recSrc = "package P\nrecord Pt {\n  x: Int\n  y: Int\n}\n"
  val twice = parseCheck(recSrc + "func g(): Pt { Pt(x = 1, x = 2, y = 3) }\n")
  assertEqualInt(countDiagCode(twice, "T0104"), 1, "Pt(x = 1, x = 2, y = 3): " + diagCodesOf(twice))
  assertTrue(diagMessagesContain(twice, "field 'x' is given more than once"), "message")
  val posThenNamed = parseCheck(recSrc + "func g(): Pt { Pt(1, x = 2) }\n")
  assertEqualInt(countDiagCode(posThenNamed, "T0104"), 1, "Pt(1, x = 2): " + diagCodesOf(posThenNamed))
  assertTrue(
    diagMessagesContain(posThenNamed, "field 'x' is given more than once (positional argument 1 already supplies it)"),
    "message"
  )
  val fine = parseCheck(recSrc + "func g(): Pt { Pt(y = 2, 1) }\nfunc h(): Pt { Pt(1, y = 2) }\n")
  assertEqualInt(diagCount(fine), 0, "each field given once: " + diagCodesOf(fine))
  val genSrc = "package P\nrecord Box[T] {\n  v: T\n  w: Int\n}\n"
  val gen = parseCheck(genSrc + "func g(): Box[Int] { Box(v = 1, v = 2, w = 3) }\n")
  assertEqualInt(countDiagCode(gen, "T0104"), 1, "generic record: " + diagCodesOf(gen))
  val unSrc = "package P\nunion U {\n  case C(a: Int, b: Int)\n  case D\n}\n"
  val caseTwice = parseCheck(unSrc + "func g(): U { C(a = 1, a = 2, b = 3) }\n")
  assertEqualInt(countDiagCode(caseTwice, "T0104"), 1, "C(a = 1, a = 2, b = 3): " + diagCodesOf(caseTwice))
  val casePos = parseCheck(unSrc + "func g(): U { C(1, a = 2) }\n")
  assertEqualInt(countDiagCode(casePos, "T0104"), 1, "C(1, a = 2): " + diagCodesOf(casePos))
  val caseFine = parseCheck(unSrc + "func g(): U { C(1, b = 2) }\n")
  assertEqualInt(diagCount(caseFine), 0, "each case field given once: " + diagCodesOf(caseFine))
}

test "a concrete-typed call resolves through the impl method's own parameters (#7820)" {
  val src = "package P\ninterface S {\n  func area(self: in Self, k: in Int = 2): Int\n}\nrecord Q {\n  s: Int\n}\n" +
    "impl S for Q {\n  func area(self: in Q, k: in Int): Int { self.s * k }\n}\n"
  val concrete = parseCheck(src + "func g(q: in Q): Int { q.area() }\n")
  assertEqualInt(countDiagCode(concrete, "T0042"), 1, "the impl method declares no default for `k`")
  val viaIface = parseCheck(src + "func g(s: in S): Int { s.area() }\n")
  assertEqualInt(countDiagCode(viaIface, "T0042"), 0, "the interface member's default applies through the interface")
}

// #7829 review: a list literal's element type is the join of its elements'
// types for fixed-size arrays too.  An `array[2, Opt[T]]` element whose `T`
// nothing fixes takes `Int` from a sibling `array[2, Opt[Int]]` (#7818's join
// had no `TyArray` arm, so the literal kept the first element's open type).
test "list literal joins array element types" {
  val src = "package P\nunion Opt[T] {\n  case Yes(v: T)\n  case No\n}\nfunc holes[T](): array[2, Opt[T]] {\n  [No, No]\n}\nfunc f(a: in array[2, Opt[Int]]): Int {\n  [holes(), a]\n}\n"
  val cr = parseCheck(src)
  assertTrue(hasDiagCode(cr, "T0070"), "the literal is not an Int")
  assertTrue(diagMessagesContain(cr, "slice[array[2, Opt[Int]]]"), "joined element type Opt[Int]")
}

// #7865: a lambda checked where a function type is expected takes its return
// type: the body's value, each branch and each `return` widen to it along the
// lossless chains, recorded as conversion sites, exactly as a function body's
// value does.  Narrowing stays rejected (`val b: Byte = 300` is T0015).
test "a lambda body widens to the expected return type (#7865)" {
  val lit = parseCheck("package P\nfunc f(): Long {\n  val g: () -> Long = { -> 5 }\n  g()\n}\n")
  assertEqualInt(diagCount(lit), 0, "{ -> 5 } is a () -> Long")
  assertEqualInt(lit.symbols.argConversionSites.count, 1, "the literal is widened explicitly")
  val arg = parseCheck("package P\nfunc call(f: in () -> Long): Long { f() }\nfunc g(): Long { call({ -> 5 }) }\n")
  assertEqualInt(diagCount(arg), 0, "a zero-parameter lambda argument takes the parameter's return type")
  val branches = parseCheck(
    "package P\nfunc f(): Long {\n  val g: (Bool) -> Long = { c -> if c { 1 } else { 2 } }\n  g(true)\n}\n"
  )
  assertEqualInt(diagCount(branches), 0, "if branches widen")
  assertEqualInt(branches.symbols.argConversionSites.count, 2, "each branch is widened explicitly")
  val ret = parseCheck(
    "package P\nfunc f(): Long {\n  val g: (Bool) -> Long = { c ->\n    if c {\n      return 1\n    }\n    2\n  }\n  g(true)\n}\n"
  )
  assertEqualInt(diagCount(ret), 0, "a nested return widens")
  assertEqualInt(ret.symbols.argConversionSites.count, 2, "the return and the trailing value are widened")
  val unsigned = parseCheck("package P\nfunc f(): ULong {\n  val g: () -> ULong = { -> 7u32 }\n  g()\n}\n")
  assertEqualInt(diagCount(unsigned), 0, "UInt to ULong")
  val narrow = parseCheck("package P\nfunc f(): Byte {\n  val g: () -> Byte = { -> 300 }\n  g()\n}\n")
  assertEqualInt(countDiagCode(narrow, "T0060"), 1, "an Int literal a Byte cannot hold is not a Byte, as at a binding")
  val wrong = parseCheck("package P\nfunc f(): Long {\n  val g: () -> Long = { -> \"s\" }\n  g()\n}\n")
  assertEqualInt(countDiagCode(wrong, "T0060"), 1, "a String body is still rejected")
  val wrongRet = parseCheck(
    "package P\nfunc f(): Long {\n  val g: (Bool) -> Long = { c ->\n    if c {\n      return \"s\"\n    }\n    2\n  }\n  g(true)\n}\n"
  )
  assertEqualInt(countDiagCode(wrongRet, "T0065"), 1, "a mismatched return is checked against the lambda")
}

// #7865: a `return` nested in a branch of a lambda body is checked against the
// lambda's return type, never the enclosing function's.
test "a nested return in a lambda is not checked against the enclosing function (#7865)" {
  val cr = parseCheck(
    "package P\nfunc f(): Int {\n  val g: (Int) -> String = { n ->\n    if n > 0 {\n      return \"pos\"\n    }\n    \"neg\"\n  }\n  g(1).length\n}\n"
  )
  assertEqualInt(diagCount(cr), 0, "return \"pos\" belongs to the String lambda")
  val bare = parseCheck(
    "package P\nfunc f(): Int {\n  val g = { n: Int ->\n    if n > 0 {\n      return \"pos\"\n    }\n    \"neg\"\n  }\n  g(1).length\n}\n"
  )
  assertEqualInt(countDiagCode(bare, "T0065"), 0, "an unannotated lambda's return is not the function's either")
}

// #7865: the type checker records each generic call's resolved type
// arguments, keyed by the callee's span, for `Lyric.Mono` to fall back to.
test "a generic call's resolved type arguments are recorded (#7865)" {
  val src = "package P\nval B = 9u8\nfunc applyT[T](f: in () -> T): T { f() }\nfunc g(): Byte { applyT({ -> B }) }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "clean")
  val keys = mapKeys(cr.symbols.genericCallTypeArgSites)
  assertEqualInt(keys.count, 1, "one generic call")
  match mapGet(cr.symbols.genericCallTypeArgSites, keys[0]) {
    case Some(site) -> {
      assertFalse(site.conflicting, "not conflicting")
      assertEqualInt(site.typeArgs.count, 1, "one type argument")
      assertEqual(site.typeParams[0], "T", "for T")
      assertEqual(typeExprText(site.typeArgs[0]), "Byte", "bound to Byte")
    }
    case None -> assertTrue(false, "site present")
  }
  val openCall = parseCheck(
    "package P\nfunc applyT[T](f: in () -> T): T { f() }\nfunc g[U](u: in U): U { applyT({ -> u }) }\n"
  )
  assertEqualInt(
    openCall.symbols.genericCallTypeArgSites.count,
    0,
    "a type argument naming a type parameter is not recorded"
  )
}

// #7865: the types a lambda's unannotated parameters take from the expected
// function type are recorded for `Lyric.Mono` to write onto the parameters.
test "a lambda's unannotated parameter types are recorded (#7865)" {
  val cr = parseCheck(
    "package P\nfunc f(): Long {\n  val g: (Int, String) -> Long = { i, s: String -> i.toLong() }\n  g(1, \"x\")\n}\n"
  )
  assertEqualInt(diagCount(cr), 0, "clean")
  val keys = mapKeys(cr.symbols.lambdaParamTypeSites)
  assertEqualInt(keys.count, 1, "one lambda")
  match mapGet(cr.symbols.lambdaParamTypeSites, keys[0]) {
    case Some(site) -> {
      assertFalse(site.conflicting, "not conflicting")
      assertTrue(site.known[0], "the unannotated parameter is known")
      assertEqual(typeExprText(site.paramTypes[0]), "Int", "typed Int")
      assertFalse(site.known[1], "the annotated parameter is left as written")
    }
    case None -> assertTrue(false, "site present")
  }
  val genericLambda = parseCheck(
    "package P\nfunc h[T](x: in T, f: in (T) -> T): T { f(x) }\nfunc g[U](u: in U): U { h(u, { v -> v }) }\n"
  )
  assertEqualInt(
    genericLambda.symbols.lambdaParamTypeSites.count,
    0,
    "a parameter typed by a type parameter is not recorded"
  )
}

// #7854: unary minus on an unsigned operand (`Byte`, `UInt`, `ULong`) is
// T0147.  It used to type as the unsigned type and wrap at runtime
// (`-(5u8)` was the Byte 251).
func negSrc(body: in String): String {
  "package P\n" + body
}

func assertNegRejected(src: in String, label: in String): Unit {
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0147"), 1, label + ": T0147 (" + diagCodesOf(cr) + ")")
  assertEqualInt(diagCount(cr), 1, label + ": no other diagnostic (" + diagCodesOf(cr) + ")")
}

test "unary minus on a Byte is T0147 (#7854)" {
  assertNegRejected(negSrc("func f(b: in Byte): Byte {\n  -b\n}\n"), "-b")
  assertNegRejected(negSrc("func f(): Byte {\n  -(5u8)\n}\n"), "-(5u8)")
  assertNegRejected(negSrc("func f(): Byte {\n  -5u8\n}\n"), "-5u8")
  assertNegRejected(negSrc("func f(b: in Byte): Byte {\n  -((b))\n}\n"), "-((b))")
  val cr = parseCheck(negSrc("func f(b: in Byte): Byte {\n  -b\n}\n"))
  val msg = diagMessageFor(cr, "T0147")
  assertTrue(Str.contains(msg, "Byte"), "the message names the operand type: " + msg)
  assertTrue(Str.contains(msg, "-(x.toInt())"), "the message suggests a signed conversion: " + msg)
}

test "unary minus on a UInt is T0147 (#7854)" {
  assertNegRejected(negSrc("func f(u: in UInt): UInt {\n  -u\n}\n"), "-u")
  assertNegRejected(negSrc("func f(): UInt {\n  -(7u32)\n}\n"), "-(7u32)")
  assertNegRejected(negSrc("func f(): UInt {\n  -(7u16)\n}\n"), "-(7u16)")
  assertNegRejected(negSrc("func f(u: in UInt): UInt {\n  -(u + 1u32)\n}\n"), "-(u + 1u32)")
}

test "unary minus on a ULong is T0147 (#7854)" {
  assertNegRejected(negSrc("func f(u: in ULong): ULong {\n  -u\n}\n"), "-u")
  assertNegRejected(negSrc("func f(): ULong {\n  -(18446744073709551615u64)\n}\n"), "-(2^64-1 u64)")
  val cr = parseCheck(negSrc("func f(u: in ULong): ULong {\n  -u\n}\n"))
  assertTrue(Str.contains(diagMessageFor(cr, "T0147"), "ULong"), "the message names ULong")
}

test "unary minus on an unsigned range or distinct type is rejected (#7854)" {
  assertNegRejected(negSrc("func f(u: in UInt range 0 ..= 10): UInt range 0 ..= 10 {\n  -u\n}\n"), "inline UInt range")
  assertNegRejected(negSrc("func f(b: in Byte range 1 ..= 9): Int {\n  val n = -b\n  0\n}\n"), "inline Byte range")
  val byteRange = parseCheck(negSrc("func f(b: in Byte range 1 ..= 9): Int {\n  val n = -b\n  0\n}\n"))
  assertTrue(Str.contains(diagMessageFor(byteRange, "T0147"), "-(x.toInt())"), "a Byte range keeps the Byte hint")
  val uintRange = parseCheck(negSrc("func f(u: in UInt range 0 ..= 10): UInt range 0 ..= 10 {\n  -u\n}\n"))
  assertTrue(not Str.contains(diagMessageFor(uintRange, "T0147"), "-(x.toInt())"), "a UInt range has no Byte hint")
  // A distinct type has no unary minus whatever its base (docs/01 §2.3).
  val cr = parseCheck(negSrc("type Port = UInt range 0 ..= 65535\nfunc f(p: in Port): Port {\n  -p\n}\n"))
  assertEqualInt(countDiagCode(cr, "T0036"), 1, "distinct Port: T0036 (" + diagCodesOf(cr) + ")")
  assertEqualInt(diagCount(cr), 1, "distinct Port: one diagnostic (" + diagCodesOf(cr) + ")")
}

test "a negated unsigned constant is not folded (#7854)" {
  assertNegRejected(negSrc("val K = -(5u8)\n"), "module val -(5u8)")
  assertNegRejected(negSrc("val B: Byte = 5u8\nval K = -B\n"), "module val -B")
  assertNegRejected(negSrc("type Small = Int range -(1u8) ..= 5\n"), "range bound -(1u8)")
  assertNegRejected(negSrc("val B: Byte = 5u8\ntype Small = Int range -B ..= 5\n"), "range bound -B")
  assertNegRejected(negSrc("val B = 5u32\ntype Small = Long range -(B * 2u32) ..= 5\n"), "range bound -(B * 2u32)")
  assertNegRejected(negSrc("func f(): Unit {\n  val n: Int range -(2u8) ..= 5 = 3\n}\n"), "inline local range bound")
  assertNegRejected(negSrc("func f(x: in Int range 0 ..= -(2u16)): Unit {\n}\n"), "inline parameter range bound")
  val byteConst = diagMessageFor(parseCheck(negSrc("val K = -(5u8)\n")), "T0147")
  assertTrue(Str.contains(byteConst, "(got Byte)"), "a Byte constant names Byte: " + byteConst)
  assertTrue(Str.contains(byteConst, "-(x.toInt())"), "a Byte constant gets the Byte hint: " + byteConst)
  val uintBound = diagMessageFor(parseCheck(negSrc("type Small = Int range -(1u32) ..= 5\n")), "T0147")
  assertTrue(Str.contains(uintBound, "(got UInt)"), "a UInt bound names UInt: " + uintBound)
  assertTrue(not Str.contains(uintBound, "-(x.toInt())"), "a UInt bound has no Byte hint: " + uintBound)
  // Through a constant, the negation is reported once, at the constant.
  val viaConst = parseCheck(negSrc("val K = -(5u8)\ntype Small = Int range K ..= 5\n"))
  assertEqualInt(countDiagCode(viaConst, "T0147"), 1, "via a constant: one T0147 (" + diagCodesOf(viaConst) + ")")
}

test "unary minus on a signed operand stays clean (#7854)" {
  val src = negSrc(
    "val M = -(5i8)\ntype Small = Int range -(5) ..= 5\nfunc f(b: in Byte, i: in Int, l: in Long, d: in Double): Long {\n  val x = -(b.toInt())\n  val y = -(b.toLong()) + -l\n  val z = -d\n  val w = -i + x + -2147483648\n  y + w.toLong()\n}\n"
  )
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "signed negation: clean (" + diagCodesOf(cr) + ")")
}

// ─────────────────────────────────────────────────────────────────────────────
// Native FFI intrinsics (#7910): typed only by a `--target native` check.
// ─────────────────────────────────────────────────────────────────────────────
func stdCoreOptionPackages(): List[ImportedPackage] {
  val pkg = parse("package Std.Core\npub union Option[T] {\n  case Some(value: T)\n  case None\n}\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "Std.Core",
      items = pkg.file.items,
      imports = collectImportNames(pkg.file.imports),
      wholeImports = collectWholeImportNames(pkg.file.imports)
    )
  )
  packages
}

val nativeIntrinsicsSrc: String = "package T\n" + "record Node {\n  n: Int\n}\n" + "@unsafe_ffi\n" + "func addr(): Int {\n" + "  var x: Long = 0\n" + "  val p: NativePtr[Long] = nativeAddrOf(x)\n" + "  var q: NativePtr[Byte] = nativeNullPtr()\n" + "  val pq: NativePtr[NativePtr[Byte]] = nativeAddrOf(q)\n" + "  0\n" + "}\n" + "func weakN(node: in Node): Int {\n" + "  val w: NativeWeak[Node] = NativeWeak(node)\n" + "  match w.upgrade() {\n" + "    case Some(strong) -> strong.n\n" + "    case None -> 0\n" + "  }\n" + "}\n"

test "the native FFI intrinsics type in a native check (#7910)" {
  val cr = checkWithImportedPackagesForNative(parse(nativeIntrinsicsSrc).file, stdCoreOptionPackages())
  assertEqualInt(diagCount(cr), 0, "native check: clean (" + diagCodesOf(cr) + ")")
  assertEqual(
    recordedCallType(cr, nativeIntrinsicsSrc, "w.upgrade()"),
    "Option[Node]",
    "upgrade() on a NativeWeak[Node] is an Option[Node]"
  )
}

test "the native-only intrinsics are unknown to a managed-target check (#7910)" {
  val cr = checkWithImportedPackages(parse(nativeIntrinsicsSrc).file, stdCoreOptionPackages())
  assertTrue(hasDiagCode(cr, "T0010"), "NativeWeak: T0010 (" + diagCodesOf(cr) + ")")
  assertTrue(hasDiagCode(cr, "T0020"), "nativeAddrOf: T0020 (" + diagCodesOf(cr) + ")")
}

// D158: C bindings run on every target, so NativePtr and nativeNullPtr
// type everywhere; an extern func needs @library off native.
val cBindingSrc: String = "package T\n@library(\"c\")\nextern func cMalloc(n: Long): NativePtr[Byte] = \"malloc\"\n" + "@library(\"c\")\nextern func cFree(p: NativePtr[Byte]): Unit = \"free\"\n" + "@unsafe_ffi\nfunc f(): Int {\n  val p: NativePtr[Byte] = cMalloc(8)\n  cFree(p)\n  cFree(nativeNullPtr())\n  0\n}\n"

test "a C binding with NativePtr checks clean on a managed target (D158)" {
  val cr = checkWithImportedPackages(parse(cBindingSrc).file, stdCoreOptionPackages())
  assertEqualInt(diagCount(cr), 0, "managed check: clean (" + diagCodesOf(cr) + ")")
}

test "an extern func without @library is T0149 off native only (D158)" {
  val src = "package T\nextern func f(x: Int): Int = \"f\"\n"
  assertEqualInt(
    countDiagCode(checkWithImportedPackages(parse(src).file, stdCoreOptionPackages()), "T0149"),
    1,
    "managed: T0149"
  )
  assertEqualInt(
    countDiagCode(checkWithImportedPackagesForNative(parse(src).file, stdCoreOptionPackages()), "T0149"),
    0,
    "native links the symbol itself"
  )
}

test "a malformed or repeated @library is T0150 (D158)" {
  val empty = "package T\n@library(\"\")\nextern func f(x: Int): Int = \"f\"\n"
  assertEqualInt(countDiagCode(parseCheck(empty), "T0150"), 1, "empty library name")
  val twice = "package T\n@library(\"a\")\n@library(\"b\")\nextern func f(x: Int): Int = \"f\"\n"
  assertEqualInt(countDiagCode(parseCheck(twice), "T0150"), 1, "two libraries")
}

test "a type that cannot cross a C binding is T0151 (D158)" {
  val src = "package T\n@library(\"c\")\nextern func f(s: String, b: Bool): Unit = \"f\"\n" +
    "@library(\"c\")\nextern func g(x: Int): Unit = \"g\"\n" +
    "@library(\"c\")\nextern func h(x: Int): Double = \"h\"\n" +
    "@library(\"c\")\nextern func k(x: Float): Float = \"k\"\n"
  assertEqualInt(
    countDiagCode(parseCheck(src), "T0151"),
    2,
    "String and Bool parameters; Unit, Double and Float results and a Float parameter are fine (#7966)"
  )
}

test "a native intrinsic's type is checked like any other (#7910)" {
  val src = "package T\n" + "@unsafe_ffi\n" + "func f(): Int {\n" + "  var x: Long = 0\n" +
    "  val p: NativePtr[Byte] = nativeAddrOf(x)\n" +
    "  val q: NativePtr[Byte] = nativeNullPtr(x)\n" +
    "  0\n" +
    "}\n"
  val cr = checkWithImportedPackagesForNative(parse(src).file, stdCoreOptionPackages())
  assertEqualInt(
    countDiagCode(cr, "T0060"),
    1,
    "NativePtr[Long] bound as NativePtr[Byte]: T0060 (" + diagCodesOf(cr) + ")"
  )
  assertEqualInt(countDiagCode(cr, "T0042"), 1, "nativeNullPtr takes no argument: T0042 (" + diagCodesOf(cr) + ")")
}

test "the byte intrinsics check clean on every target (D161)" {
  val src = "package T\n@unsafe_ffi\nfunc f(p: NativePtr[Byte]): Byte {\n" + "  nativeStoreByte(p, 0, 7u8)\n" +
    "  nativeStoreByte(p, 1i64, nativeLoadByte(p, 0))\n" +
    "  nativeLoadByte(p, 1)\n" +
    "}\n"
  val managed = checkWithImportedPackages(parse(src).file, stdCoreOptionPackages())
  assertEqualInt(diagCount(managed), 0, "managed: clean (" + diagCodesOf(managed) + ")")
  val native = checkWithImportedPackagesForNative(parse(src).file, stdCoreOptionPackages())
  assertEqualInt(diagCount(native), 0, "native: clean (" + diagCodesOf(native) + ")")
}

test "the byte intrinsics check their arguments (D161)" {
  val src = "package T\n@unsafe_ffi\nfunc f(p: NativePtr[Byte], q: NativePtr[Long]): Unit {\n" +
    "  val a = nativeLoadByte(p)\n" +
    "  nativeStoreByte(p, 0)\n" +
    "  val b = nativeLoadByte(q, 0)\n" +
    "  val c = nativeLoadByte(p, \"x\")\n" +
    "  nativeStoreByte(p, 0, 300)\n" +
    "}\n"
  val cr = checkWithImportedPackages(parse(src).file, stdCoreOptionPackages())
  assertEqualInt(countDiagCode(cr, "T0042"), 2, "load and store arity: T0042 (" + diagCodesOf(cr) + ")")
  assertEqualInt(
    countDiagCode(cr, "T0043"),
    3,
    "a NativePtr[Long], a String offset and an Int value: T0043 (" + diagCodesOf(cr) + ")"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Calls to an `extern func` (#7921) are checked against its declared
// signature, exactly like a call to a Lyric function.  `@library` makes the
// binding valid on the managed target these tests check for (D158, T0149).
// ─────────────────────────────────────────────────────────────────────────────
func externAbsSrc(body: in String): String {
  "package T\n" + "@library(\"c\")\nextern func cAbs(x: Int): Int = \"abs\"\n" + "func f(): Int {\n" + body + "}\n"
}

test "a correct extern func call is clean and its result type flows on (#7921)" {
  val src = externAbsSrc("  val y = cAbs(-3)\n  val z: Int = cAbs(x = y)\n  y + z + 1\n")
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "correct extern call: clean (" + diagCodesOf(cr) + ")")
  val typed = parseCheck(externAbsSrc("  val b: Bool = cAbs(-3)\n  0\n"))
  assertTrue(
    Str.contains(diagMessageFor(typed, "T0060"), "initialiser has type Int"),
    "cAbs(-3) types as the declared Int (" + diagMessageFor(typed, "T0060") + ")"
  )
}

test "an extern func argument of the wrong type is T0043 (#7921)" {
  val cr = parseCheck(externAbsSrc("  cAbs(\"hi\")\n"))
  assertEqualInt(countDiagCode(cr, "T0043"), 1, "String passed for Int: T0043 (" + diagCodesOf(cr) + ")")
}

test "an extern func call with the wrong number of arguments is T0042 (#7921)" {
  val cr = parseCheck(externAbsSrc("  cAbs(1, 2)\n"))
  assertEqualInt(countDiagCode(cr, "T0042"), 1, "two arguments for one parameter: T0042 (" + diagCodesOf(cr) + ")")
  val none = parseCheck(externAbsSrc("  cAbs()\n"))
  assertEqualInt(countDiagCode(none, "T0042"), 1, "no arguments for one parameter: T0042 (" + diagCodesOf(none) + ")")
}

test "an extern func call with an unknown named argument is rejected (#7921)" {
  val cr = parseCheck(externAbsSrc("  cAbs(y = 1)\n"))
  assertTrue(diagCount(cr) > 0, "unknown named argument: rejected")
}

test "an extern func result flows into a binding and a later expression (#7921)" {
  val bound = parseCheck(externAbsSrc("  val s: String = cAbs(3)\n  0\n"))
  assertEqualInt(countDiagCode(bound, "T0060"), 1, "Int bound as String: T0060 (" + diagCodesOf(bound) + ")")
  val later = parseCheck(externAbsSrc("  val y = cAbs(3)\n  val s: String = y\n  0\n"))
  assertEqualInt(
    countDiagCode(later, "T0060"),
    1,
    "inferred Int later bound as String: T0060 (" + diagCodesOf(later) + ")"
  )
  val returned = parseCheck(
    "package T\n" + "extern func cAbs(x: Int): Int = \"abs\"\n" + "func f(): String {\n" + "  cAbs(3)\n" +
      "}\n"
  )
  assertTrue(diagCount(returned) > 0, "Int returned as String: rejected")
}

test "an extern func parameter default is checked against its type (#7921)" {
  val cr = parseCheck("package P\nextern func f(x: Int = \"s\"): Int = \"f\"\n")
  assertEqualInt(countDiagCode(cr, "T0060"), 1, "String default for an Int parameter: T0060 (" + diagCodesOf(cr) + ")")
}

val externPtrSrc: String = "package T\n" + "extern func strlen(s: NativePtr[Byte]): Long = \"strlen\"\n" + "@unsafe_ffi\n" + "func ok(): Long {\n" + "  strlen(nativeNullPtr())\n" + "}\n" + "@unsafe_ffi\n" + "func bad(): Long {\n" + "  var x: Long = 0\n" + "  strlen(nativeAddrOf(x))\n" + "}\n"

test "an extern func with a NativePtr parameter is checked in a native check (#7921)" {
  val cr = checkWithImportedPackagesForNative(parse(externPtrSrc).file, stdCoreOptionPackages())
  assertEqualInt(diagCount(cr), 1, "one mismatch only (" + diagCodesOf(cr) + ")")
  assertEqualInt(
    countDiagCode(cr, "T0043"),
    1,
    "NativePtr[Long] passed for NativePtr[Byte]: T0043 (" + diagCodesOf(cr) + ")"
  )
  val typedSrc = "package T\n" + "extern func strlen(s: NativePtr[Byte]): Long = \"strlen\"\n" + "@unsafe_ffi\n" +
    "func f(): Int {\n" +
    "  val b: Bool = strlen(nativeNullPtr())\n" +
    "  0\n" +
    "}\n"
  val typed = checkWithImportedPackagesForNative(parse(typedSrc).file, stdCoreOptionPackages())
  assertTrue(
    Str.contains(diagMessageFor(typed, "T0060"), "initialiser has type Long"),
    "strlen types as the declared Long (" + diagMessageFor(typed, "T0060") + ")"
  )
}

func externKernelPackages(): List[ImportedPackage] {
  val kernel = parse("package K\npub extern func cAbs(x: Int): Int = \"abs\"\n")
  val packages: List[ImportedPackage] = newList()
  packages.add(
    ImportedPackage(
      name = "K",
      items = kernel.file.items,
      imports = collectImportNames(kernel.file.imports),
      wholeImports = collectWholeImportNames(kernel.file.imports)
    )
  )
  packages
}

// Qualified calls go through `rewriteFile` first, as in the real pipeline.
test "a call to an imported package's extern func is checked (#7921)" {
  val good = "package T\nimport K\nfunc f(): Int {\n  val y = K.cAbs(-3)\n  y + 1\n}\n"
  val goodCr = checkWithImportedPackages(rewriteFile(parse(good).file), externKernelPackages())
  assertEqualInt(diagCount(goodCr), 0, "imported extern call: clean (" + diagCodesOf(goodCr) + ")")
  val typed = "package T\nimport K\nfunc f(): Int {\n  val b: Bool = K.cAbs(-3)\n  0\n}\n"
  val typedCr = checkWithImportedPackages(rewriteFile(parse(typed).file), externKernelPackages())
  assertTrue(
    Str.contains(diagMessageFor(typedCr, "T0060"), "initialiser has type Int"),
    "K.cAbs(-3) types as the declared Int (" + diagMessageFor(typedCr, "T0060") + ")"
  )
  val bad = "package T\nimport K\nfunc f(): Int {\n  K.cAbs(\"hi\")\n}\n"
  val badCr = checkWithImportedPackages(rewriteFile(parse(bad).file), externKernelPackages())
  assertEqualInt(
    countDiagCode(badCr, "T0043"),
    1,
    "imported extern, String for Int: T0043 (" + diagCodesOf(badCr) + ")"
  )
  val arity = "package T\nimport K\nfunc f(): Int {\n  K.cAbs(1, 2)\n}\n"
  val arityCr = checkWithImportedPackages(rewriteFile(parse(arity).file), externKernelPackages())
  assertEqualInt(
    countDiagCode(arityCr, "T0042"),
    1,
    "imported extern, wrong arity: T0042 (" + diagCodesOf(arityCr) + ")"
  )
}

func externTargetSrc(body: in String): String {
  "package T\n" + "@externTarget(\"System.Math.Abs\")\n" + "func mAbs(x: in Int): Int\n" + "func f(): Int {\n" + body +
    "}\n"
}

test "an @externTarget function call is checked against its declared signature (#7921)" {
  val good = externTargetSrc("  val y = mAbs(-3)\n  y + 1\n")
  val goodCr = parseCheck(good)
  assertEqualInt(diagCount(goodCr), 0, "correct @externTarget call: clean (" + diagCodesOf(goodCr) + ")")
  val ty = parseCheck(externTargetSrc("  mAbs(\"hi\")\n"))
  assertEqualInt(countDiagCode(ty, "T0043"), 1, "String passed for Int: T0043 (" + diagCodesOf(ty) + ")")
  val arity = parseCheck(externTargetSrc("  mAbs(1, 2)\n"))
  assertEqualInt(countDiagCode(arity, "T0042"), 1, "wrong arity: T0042 (" + diagCodesOf(arity) + ")")
  val bound = parseCheck(externTargetSrc("  val s: String = mAbs(3)\n  0\n"))
  assertEqualInt(countDiagCode(bound, "T0060"), 1, "Int bound as String: T0060 (" + diagCodesOf(bound) + ")")
}

// The native extern-call adaptation (docs/01 §11.6, N4.5): a callback
// parameter takes the closure of its signature without the trailing
// userdata slot, and that closure also passes as the `NativePtr[Byte]`
// userdata itself.
func externCallbackSrc(body: in String): String {
  "package T\n" +
    "extern func startThread(start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = \"start_thread\"\n" +
    "@unsafe_ffi\n" +
    "func f(): Int {\n" +
    body +
    "}\n"
}

func checkExternCallback(body: in String): CheckResult {
  checkWithImportedPackagesForNative(parse(externCallbackSrc(body)).file, stdCoreOptionPackages())
}

test "an extern callback parameter takes the closure without its userdata slot (#7921)" {
  val bound = checkExternCallback("  val w: () -> NativePtr[Byte] = { -> nativeNullPtr() }\n  startThread(w, w)\n")
  assertEqualInt(diagCount(bound), 0, "bound closure as callback and userdata: clean (" + diagCodesOf(bound) + ")")
  val literal = checkExternCallback("  startThread({ -> nativeNullPtr() }, nativeNullPtr())\n")
  assertEqualInt(diagCount(literal), 0, "closure literal as callback: clean (" + diagCodesOf(literal) + ")")
}

test "an extern callback parameter rejects a closure of the full C signature (#7921)" {
  val cr = checkExternCallback(
    "  val w: (NativePtr[Byte]) -> NativePtr[Byte] = { p: NativePtr[Byte] -> p }\n  startThread(w, nativeNullPtr())\n"
  )
  assertEqualInt(countDiagCode(cr, "T0043"), 1, "full-arity closure as callback: T0043 (" + diagCodesOf(cr) + ")")
  assertTrue(
    Str.contains(diagMessageFor(cr, "T0043"), "takes a closure of type () -> NativePtr[Byte]"),
    "the T0043 names the closure type: " + diagMessageFor(cr, "T0043")
  )
}

test "an extern NativePtr[Byte] parameter rejects a non-pointer, non-closure value (#7921)" {
  val w = "  val w: () -> NativePtr[Byte] = { -> nativeNullPtr() }\n"
  val intArg = checkExternCallback(w + "  startThread(w, 7)\n")
  assertEqualInt(countDiagCode(intArg, "T0043"), 1, "Int as NativePtr[Byte]: T0043 (" + diagCodesOf(intArg) + ")")
  val strArg = checkExternCallback(w + "  startThread(w, \"s\")\n")
  assertEqualInt(countDiagCode(strArg, "T0043"), 1, "String as NativePtr[Byte]: T0043 (" + diagCodesOf(strArg) + ")")
}

// #7969: an element-taking member of the stdlib `List`, `Map` or `Set` checks
// its argument against the receiver's element, key or value type, under the
// rules of an ordinary call argument.
func checkCollectionCall(params: in String, body: in String): CheckResult {
  val src = "package P\nimport Std.CollectionsHost\n" + "record Item { n: Int }\n" + "record Box[T] { v: T }\n" +
    "interface Shape { func area(): Int }\n" +
    "record Square { side: Int }\n" +
    "impl Shape for Square { func area(): Int = self.side }\n" +
    "func f(" +
    params +
    "): Unit {\n  " +
    body +
    "\n}\n"
  checkWithImportedPackages(parse(src).file, stdCollectionsHostPackages())
}

func assertCollectionCallClean(params: in String, body: in String, what: in String): Unit {
  val cr = checkCollectionCall(params, body)
  assertEqualInt(diagCount(cr), 0, what + ": clean (" + diagCodesOf(cr) + ")")
}

func assertCollectionCallMismatch(params: in String, body: in String, needle: in String, what: in String): Unit {
  val cr = checkCollectionCall(params, body)
  assertEqualInt(countDiagCode(cr, "T0043"), 1, what + ": one T0043 (" + diagCodesOf(cr) + ")")
  assertTrue(
    Str.contains(diagMessageFor(cr, "T0043"), needle),
    what + ": names '" + needle + "': " + diagMessageFor(cr, "T0043")
  )
}

test "List.add checks its argument against the element type (#7969)" {
  assertCollectionCallClean("xs: in List[Item], it: in Item", "xs.add(it)", "List[Item].add(Item)")
  assertCollectionCallMismatch(
    "xs: in List[Item], s: in String",
    "xs.add(s)",
    "does not match List[Item]'s element type Item",
    "List[Item].add(String)"
  )
  assertCollectionCallClean("xs: in List[Long], i: in Int", "xs.add(i)", "List[Long].add(Int) widens")
  assertCollectionCallMismatch(
    "xs: in List[Int], l: in Long",
    "xs.add(l)",
    "element type Int",
    "List[Int].add(Long) narrows"
  )
  assertCollectionCallMismatch(
    "xs: in List[Double], i: in Int",
    "xs.add(i)",
    "element type Double",
    "List[Double].add(Int) crosses the widening chains"
  )
  assertCollectionCallClean("xs: in List[Byte]", "xs.add(0)", "List[Byte].add(an Int literal a Byte holds) (#7841)")
  assertCollectionCallMismatch(
    "xs: in List[Byte]",
    "xs.add(256)",
    "element type Byte",
    "List[Byte].add(an Int literal no Byte holds)"
  )
  assertCollectionCallClean("xs: in List[Byte]", "xs.add(0u8)", "List[Byte].add(a Byte literal)")
  assertCollectionCallClean("xs: in List[Shape], sq: in Square", "xs.add(sq)", "List[Shape].add(an implementor)")
  assertCollectionCallClean("xs: in List[List[Int]]", "xs.add([1, 2])", "List[List[Int]].add(a bracket literal)")
}

test "two-argument List.add checks the index and the element (#7969)" {
  assertCollectionCallClean("xs: in List[Item], it: in Item", "xs.add(0, it)", "List[Item].add(Int, Item)")
  assertCollectionCallClean("xs: in List[Long]", "xs.add(0, 5)", "List[Long].add(0, 5) widens the element")
  assertCollectionCallMismatch(
    "xs: in List[Item], s: in String",
    "xs.add(0, s)",
    "element type Item",
    "List[Item].add(Int, String)"
  )
  assertCollectionCallMismatch(
    "xs: in List[Item], it: in Item",
    "xs.add(\"0\", it)",
    "the index type Int",
    "List[Item].add(String, Item)"
  )
}

test "List element lookups check their argument against the element type (#7969)" {
  val members = ["contains", "indexOf", "lastIndexOf", "remove"]
  for m in members {
    assertCollectionCallClean("xs: in List[Item], it: in Item", "val _ = xs." + m + "(it)", "List[Item]." + m + "(Item)")
    assertCollectionCallClean(
      "xs: in List[Long], i: in Int",
      "val _ = xs." + m + "(i)",
      "List[Long]." + m + "(Int) widens"
    )
    assertCollectionCallMismatch(
      "xs: in List[Item], s: in String",
      "val _ = xs." + m + "(s)",
      "'." + m + "' does not match List[Item]'s element type Item",
      "List[Item]." + m + "(String)"
    )
  }
  assertCollectionCallClean("xs: in List[Item], i: in Int", "xs.removeAt(i)", "List.removeAt(Int)")
  assertCollectionCallMismatch(
    "xs: in List[Item], it: in Item",
    "xs.removeAt(it)",
    "the index type Int",
    "List.removeAt(Item)"
  )
}

test "Map members check keys and values against the receiver's type arguments (#7969)" {
  assertCollectionCallClean(
    "m: in Map[String, Item], it: in Item",
    "m.add(\"k\", it)",
    "Map[String, Item].add(String, Item)"
  )
  assertCollectionCallClean("m: in Map[Long, Long], i: in Int", "m.add(i, i)", "Map[Long, Long].add(Int, Int) widens")
  assertCollectionCallMismatch(
    "m: in Map[String, Item]",
    "m.add(\"k\", \"v\")",
    "does not match Map[String, Item]'s value type Item",
    "Map[String, Item].add(String, String)"
  )
  assertCollectionCallMismatch(
    "m: in Map[String, Item], it: in Item",
    "m.add(1, it)",
    "does not match Map[String, Item]'s key type String",
    "Map[String, Item].add(Int, Item)"
  )
  for m in ["containsKey", "remove"] {
    assertCollectionCallClean("m: in Map[String, Item]", "val _ = m." + m + "(\"k\")", "Map." + m + "(String)")
    assertCollectionCallMismatch(
      "m: in Map[String, Item], it: in Item",
      "val _ = m." + m + "(it)",
      "key type String",
      "Map." + m + "(Item)"
    )
  }
}

test "Set members check their argument against the element type (#7969)" {
  for m in ["add", "contains", "remove"] {
    assertCollectionCallClean("s: in Set[Item], it: in Item", "val _ = s." + m + "(it)", "Set[Item]." + m + "(Item)")
    assertCollectionCallMismatch(
      "s: in Set[Item], x: in String",
      "val _ = s." + m + "(x)",
      "does not match Set[Item]'s element type Item",
      "Set[Item]." + m + "(String)"
    )
  }
}

test "a collection member call in a generic body checks against the type parameter (#7969)" {
  val ok = "package P\nimport Std.CollectionsHost\nrecord Box[T] { v: T }\n" +
    "func f[T](xs: in List[T], x: in T, bs: in List[Box[T]]): Unit {\n  xs.add(x)\n  bs.add(Box(v = x))\n  val _ = xs.contains(x)\n}\n"
  val okCr = checkWithImportedPackages(parse(ok).file, stdCollectionsHostPackages())
  assertEqualInt(diagCount(okCr), 0, "List[T] and List[Box[T]] take T and Box[T]: clean (" + diagCodesOf(okCr) + ")")
  val bad = "package P\nimport Std.CollectionsHost\nrecord Box[T] { v: T }\n" +
    "func f[T](bs: in List[Box[T]], s: in String): Unit {\n  bs.add(s)\n}\n"
  val badCr = checkWithImportedPackages(parse(bad).file, stdCollectionsHostPackages())
  assertEqualInt(countDiagCode(badCr, "T0043"), 1, "List[Box[T]].add(String): one T0043 (" + diagCodesOf(badCr) + ")")
  assertTrue(
    Str.contains(diagMessageFor(badCr, "T0043"), "element type Box[T]"),
    "the T0043 names Box[T]: " + diagMessageFor(badCr, "T0043")
  )
}

test "a lambda added to a list of functions is typed by the element type (#7969)" {
  assertCollectionCallClean("fs: in List[(Int) -> Int]", "fs.add({ n -> n + 1 })", "an (Int) -> Int lambda")
  assertCollectionCallMismatch(
    "fs: in List[(Int) -> Int]",
    "fs.add({ n -> n == 1 })",
    "element type (Int) -> Int",
    "an (Int) -> Bool lambda"
  )
}

test "a same-named local List is not checked as the stdlib collection (#7969)" {
  val src = "package P\nrecord List[T] { }\nfunc f(xs: in List[Int], s: in String): Unit {\n  xs.add(s)\n}\n"
  assertEqualInt(countDiagCode(parseCheck(src), "T0043"), 0, "a local record List's add is not the stdlib member")
}

// ── The built-in `Task[T]` handle (docs/68 §3) ───────────────────────────────
func taskProgram(body: in String): String {
  "package P\nasync func g(): Int { 1 }\nasync func u(): Unit { }\n" + body
}

test "spawn of an async call is a Task[R], and annotating it as such is clean" {
  val cr = parseCheck(
    taskProgram("func f(): Unit {\n  val t: Task[Int] = spawn g()\n  val k: Task[Unit] = spawn u()\n}\n")
  )
  assertEqualInt(diagCount(cr), 0, "spawn g(): Task[Int], spawn u(): Task[Unit]")
}

test "a spawn handle is not its result: it does not satisfy an Int" {
  val cr = parseCheck(taskProgram("func f(): Unit {\n  val n: Int = spawn g()\n}\n"))
  assertTrue(diagCount(cr) > 0, "Task[Int] is not an Int")
  assertTrue(diagMessagesContain(cr, "Task[Int]"), "the diagnostic names the handle type: " + diagCodesOf(cr))
}

test "await of a Task[R] yields R" {
  val ok = parseCheck(taskProgram("func f(): Unit {\n  val t = spawn g()\n  val n: Int = await t\n}\n"))
  assertEqualInt(diagCount(ok), 0, "await t: Int")
  val bad = parseCheck(taskProgram("func f(): Unit {\n  val t = spawn g()\n  val s: String = await t\n}\n"))
  assertTrue(diagCount(bad) > 0, "await t is not a String")
}

test "await spawn and a direct async call both give the callee's result" {
  val cr = parseCheck(
    taskProgram(
      "func f(): Unit {\n  val a: Int = await spawn g()\n  val b: Int = await g()\n  val c: Int = g()\n}\n"
    )
  )
  assertEqualInt(diagCount(cr), 0, "await spawn g(), await g() and g() are Int")
}

test "a generic over a Task[T] infers T from the handle" {
  val cr = parseCheck(
    taskProgram(
      "func unwrap[T](t: in Task[T]): T { await t }\nfunc f(): Unit {\n  val n: Int = unwrap(spawn g())\n}\n"
    )
  )
  assertEqualInt(diagCount(cr), 0, "unwrap(spawn g()): Int, T bound to Int through Task[T]")
}

test "a Task[R] handle satisfies the bare Task extern, and the bare Task satisfies Task[Unit]" {
  val src = taskProgram(
    "extern type Task = \"System.Threading.Tasks.Task\"\n" + "func waitOn(t: in Task): Unit { }\n" +
      "func back(b: in Task): Task[Unit] { b }\n" +
      "func f(): Unit {\n  val t = spawn g()\n  waitOn(t)\n  waitOn(spawn u())\n}\n"
  )
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "handle to bare Task parameter, bare Task to Task[Unit]: " + diagCodesOf(cr))
}

test "a package's own generic Task type wins over the built-in" {
  val cr = parseCheck("package P\nrecord Task[T] {\n  v: T\n}\nfunc f(t: in Task[Int]): Int { t.v }\n")
  assertEqualInt(diagCount(cr), 0, "the user's Task[T] record resolves and has its own field: " + diagCodesOf(cr))
}

test "a spawn handle is not recorded as a source type for the middle end" {
  val cr = parseCheck(
    taskProgram(
      "func w[T](t: in T, n: in Int): Int { n }\nfunc f(): Unit {\n  val t = spawn g()\n  val r = w(t, 1)\n}\n"
    )
  )
  assertEqualInt(diagCount(cr), 0, "a generic called with a handle checks clean")
  assertEqualInt(
    cr.symbols.genericCallTypeArgSites.count,
    0,
    "no type-argument site names the handle type: no backend can spell Task[Int]"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// array[N, T] (D167).
// ─────────────────────────────────────────────────────────────────────────────
test "an array's length is part of its type" {
  val same = "package P\nfunc f(a: in array[3, Int]): array[3, Int] { a }\n"
  assertEqualInt(diagCount(parseCheck(same)), 0, "same length: clean (" + diagCodesOf(parseCheck(same)) + ")")
  val diff = "package P\nfunc f(a: in array[3, Int]): array[4, Int] { a }\n"
  assertTrue(
    hasDiagCode(parseCheck(diff), "T0070"),
    "a differing length does not match the return type (" + diagCodesOf(parseCheck(diff)) + ")"
  )
  val named = "package P\nval SIZE: Int = 3\nfunc f(a: in array[SIZE, Int]): array[3, Int] { a }\n"
  assertEqualInt(diagCount(parseCheck(named)), 0, "a constant length folds (" + diagCodesOf(parseCheck(named)) + ")")
}

test "a bracket literal builds an array of exactly N elements (T0155)" {
  val ok = "package P\nfunc f(): array[3, Int] {\n  val a: array[3, Int] = [1, 2, 3]\n  a\n}\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "three elements: clean (" + diagCodesOf(parseCheck(ok)) + ")")
  val few = "package P\nfunc f(): Int {\n  val a: array[3, Int] = [1, 2]\n  a[0]\n}\n"
  assertEqualInt(countDiagCode(parseCheck(few), "T0155"), 1, "two elements for array[3, Int]")
  val many = "package P\nfunc f(): array[2, Int] { [1, 2, 3] }\n"
  assertEqualInt(countDiagCode(parseCheck(many), "T0155"), 1, "a return value")
  val arg = "package P\nfunc g(a: in array[3, Int]): Int { a[0] }\nfunc f(): Int { g([1, 2, 3, 4]) }\n"
  assertEqualInt(countDiagCode(parseCheck(arg), "T0155"), 1, "an argument")
  val field = "package P\nrecord R { a: array[2, Int] }\nfunc f(): R { R(a = [1, 2, 3]) }\n"
  assertEqualInt(countDiagCode(parseCheck(field), "T0155"), 1, "a field")
  val nested = "package P\nfunc f(): array[2, array[2, Int]] { [[1, 2], [3]] }\n"
  assertEqualInt(countDiagCode(parseCheck(nested), "T0155"), 1, "a nested row")
  val elem = "package P\nfunc f(): array[2, Int] { [1, \"x\"] }\n"
  assertTrue(hasDiagCode(parseCheck(elem), "T0041"), "an element of the wrong type")
}

test "a declaration without an initializer needs an element type with a zero (T0156)" {
  val ok = "package P\nenum M {\n  case A\n  case B\n}\nrecord V { x: Float\n y: Int = 2 }\ntype C = Int range 0 ..= 9\nfunc f() {\n  var a: array[2, Int]\n  var b: array[2, Float]\n  var c: array[2, M]\n  var d: array[2, V]\n  var e: array[2, array[2, Bool]]\n  var g: array[2, C]\n  a[0] = 1\n}\n"
  assertEqualInt(
    diagCount(parseCheck(ok)),
    0,
    "scalars, enums, records, nested arrays, ranges holding 0: clean (" + diagCodesOf(parseCheck(ok)) + ")"
  )
  val str = "package P\nfunc f() {\n  var a: array[2, String]\n  a[0] = \"x\"\n}\n"
  assertEqualInt(countDiagCode(parseCheck(str), "T0156"), 1, "a String has no zero")
  val union = "package P\nunion U {\n  case X\n  case Y(n: Int)\n}\nfunc f() {\n  var a: array[2, U]\n  a[0] = X\n}\n"
  assertEqualInt(countDiagCode(parseCheck(union), "T0156"), 1, "a union has no zero")
  val range = "package P\ntype C = Int range 1 ..= 9\nfunc f() {\n  var a: array[2, C]\n  a[0] = C.from(3)\n}\n"
  assertEqualInt(countDiagCode(parseCheck(range), "T0156"), 1, "a range excluding zero has no zero")
  val field = "package P\nrecord R { a: array[2, String] }\n"
  assertEqualInt(countDiagCode(parseCheck(field), "T0156"), 1, "a field with no default")
  val withDefault = "package P\nrecord R { a: array[2, String] = [\"a\", \"b\"] }\n"
  assertEqualInt(
    diagCount(parseCheck(withDefault)),
    0,
    "a default makes the zero unnecessary (" + diagCodesOf(parseCheck(withDefault)) + ")"
  )
  val initialized = "package P\nfunc f() {\n  var a: array[2, String] = [\"a\", \"b\"]\n  a[0] = \"c\"\n}\n"
  assertEqualInt(
    diagCount(parseCheck(initialized)),
    0,
    "an initializer makes it unnecessary (" + diagCodesOf(parseCheck(initialized)) + ")"
  )
}

test "an element is written through a var local, an out or inout parameter or a var field (T0157)" {
  val ok = "package P\nrecord R { var a: array[2, Int] }\nfunc f(p: inout array[2, Int], q: out array[2, Int], r: in R) {\n  var l: array[2, Int] = [1, 2]\n  l[0] = 1\n  p[0] = 2\n  q = [0, 0]\n  q[1] = 3\n  r.a[0] = 4\n  l[1] += 1\n}\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "writable places: clean (" + diagCodesOf(parseCheck(ok)) + ")")
  val valLocal = "package P\nfunc f() {\n  val l: array[2, Int] = [1, 2]\n  l[0] = 1\n}\n"
  assertEqualInt(countDiagCode(parseCheck(valLocal), "T0157"), 1, "a val local")
  val inParam = "package P\nfunc f(p: in array[2, Int]) {\n  p[0] = 1\n}\n"
  assertEqualInt(countDiagCode(parseCheck(inParam), "T0157"), 1, "an in parameter")
  val valField = "package P\nrecord R { a: array[2, Int] = [1, 2] }\nfunc f(r: in R) {\n  r.a[0] = 1\n}\n"
  assertEqualInt(countDiagCode(parseCheck(valField), "T0157"), 1, "a field that is not var")
  val compound = "package P\nfunc f(p: in array[2, Int]) {\n  p[0] += 1\n}\n"
  assertEqualInt(countDiagCode(parseCheck(compound), "T0157"), 1, "a compound assignment")
  val call = "package P\nfunc g(): array[2, Int] { [1, 2] }\nfunc f() {\n  g()[0] = 1\n}\n"
  assertEqualInt(countDiagCode(parseCheck(call), "T0157"), 1, "a call result")
  val nested = "package P\nfunc f(p: in array[2, array[2, Int]]) {\n  p[0][1] = 1\n}\n"
  assertEqualInt(countDiagCode(parseCheck(nested), "T0157"), 1, "an element of a nested array through an in parameter")
  val argToInout = "package P\nfunc g(p: inout array[2, Int]) {\n  p[0] = 1\n}\nfunc f() {\n  val l: array[2, Int] = [1, 2]\n  g(l)\n}\n"
  assertEqualInt(countDiagCode(parseCheck(argToInout), "T0085"), 1, "a val array passed to inout")
}

test "an array is indexed by an integer or an integer range subtype (T0158)" {
  val ok = "package P\ntype Slot = Int range 0 ..= 1\nfunc f(a: in array[2, Int], s: in Slot, i: in Int): Int { a[s] + a[i] + a[0] }\n"
  assertEqualInt(
    diagCount(parseCheck(ok)),
    0,
    "Int, a range subtype, a literal: clean (" + diagCodesOf(parseCheck(ok)) + ")"
  )
  val str = "package P\nfunc f(a: in array[2, Int]): Int { a[\"x\"] }\n"
  assertEqualInt(countDiagCode(parseCheck(str), "T0158"), 1, "a String index")
  val flt = "package P\nfunc f(a: in array[2, Int], i: in Float): Int { a[i] }\n"
  assertEqualInt(countDiagCode(parseCheck(flt), "T0158"), 1, "a Float index")
  val wideOk = "package P\nalias Idx = Int\ntype Wide = Long range 0 ..= 1\nfunc f(a: in array[2, Int], l: in Long, b: in Byte, n: in Idx, w: in Wide): Int { a[l] + a[b] + a[n] + a[w] + a[1i64] + a[1u8] }\n"
  assertEqualInt(
    diagCount(parseCheck(wideOk)),
    0,
    "Long, Byte, an alias of Int, a Long-based range subtype, suffixed literals (" + diagCodesOf(parseCheck(wideOk)) +
      ")"
  )
}

test "a collection element is not a writable array place (T0157)" {
  val list = "package P\nfunc f(xs: in slice[array[2, Int]]) {\n  xs[0][1] = 5\n}\n"
  assertEqualInt(countDiagCode(parseCheck(list), "T0157"), 1, "an element of a slice of arrays")
  val byRef = "package P\nfunc g(p: inout array[2, Int]) {\n  p[0] = 1\n}\nfunc f(xs: inout array[2, array[2, Int]]) {\n  g(xs[0])\n}\n"
  assertEqualInt(countDiagCode(parseCheck(byRef), "T0157"), 1, "an element is not a variable or field argument")
  val okInout = "package P\nrecord R { var a: array[2, Int] }\nfunc g(p: inout array[2, Int]) {\n  p[0] = 1\n}\nfunc f(r: in R, q: inout array[2, Int]) {\n  g(r.a)\n  g(q)\n}\n"
  assertEqualInt(
    diagCount(parseCheck(okInout)),
    0,
    "a field and an inout parameter (" + diagCodesOf(parseCheck(okInout)) + ")"
  )
}

test "an array has no members but length and toSlice (T0113)" {
  val bad = "package P\nfunc f(a: in array[2, Int]) {\n  a.add(1)\n}\n"
  assertEqualInt(countDiagCode(parseCheck(bad), "T0113"), 1, "a method call")
  val field = "package P\nfunc f(a: in array[2, Int]): Int { a.size }\n"
  assertEqualInt(countDiagCode(parseCheck(field), "T0113"), 1, "a field")
}

test "the index sites record which accesses need no bounds check" {
  val src = "package P\ntype Slot = Int range 0 ..= 3\ntype Wide = Int range 0 ..= 9\nfunc f(a: in array[4, Int], s: in Slot, w: in Wide, i: in Int, r: in Int range 1 ..< 3): Int {\n  a[s] + a[w] + a[i] + a[r] + a[2] + a[4]\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "clean (" + diagCodesOf(cr) + ")")
  var elided = 0
  var checked = 0
  var unwrapped = 0
  for k in mapKeys(cr.symbols.arrayIndexSites) {
    match mapGet(cr.symbols.arrayIndexSites, k) {
      case Some(site) -> {
        if site.elide {
          elided = elided + 1
        } else {
          checked = checked + 1
        }
        if site.unwrap {
          unwrapped = unwrapped + 1
        }
      }
      case None -> ()
    }
  }
  assertEqualInt(
    elided,
    2,
    "Slot and the literal 2 are proven; an inline range is not enforced on every path, so it is checked"
  )
  assertEqualInt(checked, 4, "Wide, Int, the inline range and the literal 4 are checked")
  assertEqualInt(unwrapped, 2, "both named range subtypes are read through .value")
}

test "== on arrays compares element by element and rejects function elements (T0153)" {
  val ok = "package P\nfunc f(a: in array[2, Int], b: in array[2, Int]): Bool { a == b and a != b }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "clean (" + diagCodesOf(parseCheck(ok)) + ")")
  val fns = "package P\nfunc f(a: in array[2, (Int) -> Int], b: in array[2, (Int) -> Int]): Bool { a == b }\n"
  assertEqualInt(countDiagCode(parseCheck(fns), "T0153"), 1, "an array of functions has no ==")
  val mismatch = "package P\nfunc f(a: in array[2, Int], b: in array[3, Int]): Bool { a == b }\n"
  assertEqualInt(countDiagCode(parseCheck(mismatch), "T0032"), 1, "arrays of different lengths")
}

test ".length and .toSlice() on an array" {
  val src = "package P\nfunc f(a: in array[5, Int]): Int {\n  val s = a.toSlice()\n  a.length + s.length\n}\n"
  assertEqualInt(diagCount(parseCheck(src)), 0, "clean (" + diagCodesOf(parseCheck(src)) + ")")
  val bad = "package P\nfunc f(a: in array[5, Int]): slice[String] { a.toSlice() }\n"
  assertTrue(hasDiagCode(parseCheck(bad), "T0070"), "toSlice yields slice[Int] (" + diagCodesOf(parseCheck(bad)) + ")")
}

test "a type with an array field derives no equals, hash, show or ordering (T0159)" {
  val bad = "package P\n@derive(Equals)\nrecord R { a: array[2, Int] }\n"
  assertEqualInt(
    countDiagCode(parseCheck(bad), "T0159"),
    1,
    "a record deriving Equals (" + diagCodesOf(parseCheck(bad)) + ")"
  )
  val union = "package P\n@derive(Show)\nunion U {\n  case A(a: array[2, Int])\n  case B\n}\n"
  assertEqualInt(countDiagCode(parseCheck(union), "T0159"), 1, "a union deriving Show")
  val ok = "package P\nrecord R { a: array[2, Int] }\nfunc f(x: in R, y: in R): Bool { x == y }\n"
  assertEqualInt(diagCount(parseCheck(ok)), 0, "== needs no derive (" + diagCodesOf(parseCheck(ok)) + ")")
  val nested = "package P\nrecord Inner { a: array[2, Int] }\n@derive(Equals)\nrecord Outer { i: Inner }\n"
  assertEqualInt(countDiagCode(parseCheck(nested), "T0159"), 1, "an array reached through a nested record")
  val viaSlice = "package P\n@derive(Equals)\nrecord R { a: slice[array[2, Int]] }\n"
  assertEqualInt(countDiagCode(parseCheck(viaSlice), "T0159"), 1, "an array inside a slice")
  val viaTuple = "package P\n@derive(Equals)\nrecord R { a: (Int, array[2, Int]) }\n"
  assertEqualInt(countDiagCode(parseCheck(viaTuple), "T0159"), 1, "an array inside a tuple")
  val viaAlias = "package P\nalias Row = array[2, Int]\n@derive(Equals)\nrecord R { a: Row }\n"
  assertEqualInt(countDiagCode(parseCheck(viaAlias), "T0159"), 1, "an array behind an alias")
}

test "a ULong range reaching 2^64 - 1 is not a bounds-check proof" {
  val src = "package P\ntype Big = ULong range 0 ..= 18446744073709551615u64\ntype Small = ULong range 0 ..= 3u64\nfunc f(a: in array[4, Int], b: in Big, s: in Small): Int {\n  a[b] + a[s]\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "clean (" + diagCodesOf(cr) + ")")
  var elided = 0
  var checked = 0
  for k in mapKeys(cr.symbols.arrayIndexSites) {
    match mapGet(cr.symbols.arrayIndexSites, k) {
      case Some(site) -> if site.elide { elided = elided + 1 } else { checked = checked + 1 }
      case None -> ()
    }
  }
  assertEqualInt(elided, 1, "only the range that fits the array")
  assertEqualInt(checked, 1, "the full ULong range is checked")
}

test "a zero value is not built for a record with an invariant (T0156)" {
  val bad = "package P\nrecord Inv { x: Int\n invariant: x >= 0 }\nfunc f() {\n  var a: array[2, Inv]\n}\n"
  assertEqualInt(countDiagCode(parseCheck(bad), "T0156"), 1, "a record with an invariant")
  val ok = "package P\nrecord Plain { x: Int }\nfunc f() {\n  var a: array[2, Plain]\n}\n"
  assertEqualInt(
    diagCount(parseCheck(ok)),
    0,
    "a record without one is zero filled (" + diagCodesOf(parseCheck(ok)) + ")"
  )
}

test "a value-generic array length is bound per call and checked per specialisation" {
  val body = "package P\nfunc f[N: Nat](a: in array[N, Int], b: in array[N, Int]): Int {\n  var c = a\n  c[0] = b[0]\n  var t = 0\n  for x in c {\n    t = t + x\n  }\n  if a == b {\n    t = t + N\n  }\n  t + a.length\n}\n"
  val bodyCr = parseCheck(body)
  assertEqualInt(diagCount(bodyCr), 0, "a value-generic body is clean (" + diagCodesOf(bodyCr) + ")")
  val call = "package P\nfunc f[N: Nat](a: in array[N, Int]): array[N, Int] = a\nfunc g(): Int {\n  val a: array[3, Int] = [1, 2, 3]\n  val r: array[3, Int] = f(a)\n  r.length\n}\n"
  val callCr = parseCheck(call)
  assertEqualInt(diagCount(callCr), 0, "the result has the bound length (" + diagCodesOf(callCr) + ")")
  assertEqualInt(callCr.symbols.valueGenericCallSites.count, 1, "the binding is recorded for Lyric.Mono")
  val clash = "package P\nfunc f[N: Nat](a: in array[N, Int], b: in array[N, Int]): Int = 0\nfunc g(): Int {\n  val a: array[3, Int] = [1, 2, 3]\n  val b: array[4, Int] = [1, 2, 3, 4]\n  f(a, b)\n}\n"
  assertEqualInt(
    countDiagCode(parseCheck(clash), "T0043"),
    1,
    "two lengths for one N (" + diagCodesOf(parseCheck(clash)) + ")"
  )
  val nonConst = "package P\nfunc size(): Int = 3\nval M: Int = size()\nfunc first(a: in array[M, Int]): Int = 0\n"
  assertEqualInt(
    countDiagCode(parseCheck(nonConst), "T0160"),
    1,
    "a length that is neither a constant nor a value generic parameter (" + diagCodesOf(parseCheck(nonConst)) + ")"
  )
}

test "an explicit value-generic length is checked against the arguments" {
  val ok = "package P\nfunc f[N: Nat](a: in array[N, Int]): array[N, Int] = a\nfunc g(): Int {\n  val a: array[3, Int] = [1, 2, 3]\n  val r: array[3, Int] = f[3](a)\n  r.length\n}\n"
  val okCr = parseCheck(ok)
  assertEqualInt(diagCount(okCr), 0, "a matching explicit length (" + diagCodesOf(okCr) + ")")
  val bad = "package P\nfunc f[N: Nat](a: in array[N, Int]): Int = 0\nfunc g(): Int {\n  val a: array[5, Int] = [1, 2, 3, 4, 5]\n  f[3](a)\n}\n"
  val badCr = parseCheck(bad)
  assertEqualInt(countDiagCode(badCr, "T0043"), 1, "an argument of another length (" + diagCodesOf(badCr) + ")")
  assertTrue(Str.contains(diagCodesOf(badCr), "'N' = 3"), "the message names the explicit length")
}

test "a value-generic length no argument gives is T0110" {
  val src = "package P\nfunc make[N: Nat](): array[N, Int] {\n  var r: array[N, Int]\n  r\n}\nfunc g(): Int {\n  val m = make()\n  0\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0110"), 1, "the length cannot be inferred (" + diagCodesOf(cr) + ")")
  val explicit = "package P\nfunc make[N: Nat](): array[N, Int] {\n  var r: array[N, Int]\n  r\n}\nfunc g(): Int {\n  val m = make[4]()\n  m.length\n}\n"
  val ecr = parseCheck(explicit)
  assertEqualInt(diagCount(ecr), 0, "an explicit length (" + diagCodesOf(ecr) + ")")
}

test "a record's value generic parameter sizes its array fields" {
  val src = "package P\nrecord FixedVec[T, N: Nat] {\n  var items: array[N, T]\n  func last(self: in FixedVec[T, N]): T = self.items[N - 1]\n}\nfunc g(): Int {\n  val a: array[3, Int] = [1, 2, 3]\n  val v = FixedVec(items = a)\n  val z: FixedVec[String, 2] = FixedVec(items = [\"a\", \"b\"])\n  v.items.length + v.last()\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "a record with a length parameter (" + diagCodesOf(cr) + ")")
  assertEqualInt(
    cr.symbols.valueRecordCtorSites.count,
    2,
    "each construction's lengths are recorded for the middle end"
  )
  val nonConst = "package P\nfunc g(): Int {\n  val n = 4\n  var a: array[n, Int]\n  a.length\n}\n"
  assertFalse(
    Str.contains(diagCodesOf(parseCheck(nonConst)), "#8149"),
    "a non-constant length is not blamed on a type's value parameter (" + diagCodesOf(parseCheck(nonConst)) + ")"
  )
}

test "an instance's length comes from a field, the expected type or a constant" {
  val src = "package P\nval Width = 4\nrecord Grid[W: Nat] {\n  var cells: array[W, Int]\n}\nfunc g(): Int {\n  val a: Grid[Width] = Grid()\n  val b: Grid[2] = Grid()\n  a.cells.length + b.cells.length\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "zero filled at the expected length (" + diagCodesOf(cr) + ")")
  assertEqualInt(cr.symbols.valueTypeArgSites.count, 1, "a constant length argument is recorded with its value")
  val mismatch = "package P\nrecord Grid[W: Nat] {\n  var cells: array[W, Int]\n}\nfunc g(): Int {\n  val a: array[3, Int] = [1, 2, 3]\n  val b: Grid[4] = Grid(cells = a)\n  0\n}\n"
  assertTrue(diagCount(parseCheck(mismatch)) > 0, "two instances of different lengths are different types")
}

test "two fields giving a record's length different values is T0043" {
  val src = "package P\nrecord Two[N: Nat] {\n  a: array[N, Int]\n  b: array[N, Int]\n}\nfunc g(): Int {\n  val x: array[2, Int] = [1, 2]\n  val y: array[3, Int] = [1, 2, 3]\n  val t = Two(a = x, b = y)\n  0\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0043"), 1, "the conflict is reported (" + diagCodesOf(cr) + ")")
  assertEqualInt(countDiagCode(cr, "T0110"), 0, "and not as an uninferable parameter")
}

test "a length argument of the wrong kind is T0163" {
  val src = "package P\nrecord FixedVec[T, N: Nat] {\n  items: array[N, T]\n}\nfunc f(v: in FixedVec[Int, String]): Int = 0\nfunc g(v: in FixedVec[3, 3]): Int = 0\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0163"), 2, "a type for a length and a length for a type (" + diagCodesOf(cr) + ")")
}

test "a union's, opaque type's or protected type's value parameter cannot size an array yet" {
  val u = "package P\nunion Shape[N: Nat] {\n  case Poly(pts: array[N, Float])\n  case Dot\n}\n"
  val ucr = parseCheck(u)
  assertEqualInt(countDiagCode(ucr, "T0160"), 1, "the union case field is reported (" + diagCodesOf(ucr) + ")")
  assertTrue(Str.contains(diagCodesOf(ucr), "#8149"), "the message names the tracking issue")
  val o = "package P\nopaque type Buf[N: Nat] {\n  bytes: array[N, Byte]\n}\n"
  assertEqualInt(
    countDiagCode(parseCheck(o), "T0160"),
    1,
    "an opaque type's field (" + diagCodesOf(parseCheck(o)) + ")"
  )
}

test "a protected invariant is type-checked" {
  val bad = "package P\nprotected type Gauge {\n  var level: Float = 0.1f32\n  invariant: level <= \"x\"\n  entry read(): Float {\n    level\n  }\n}\n"
  val badCr = parseCheck(bad)
  assertTrue(diagCount(badCr) > 0, "comparing a Float field with a String is an error (" + diagCodesOf(badCr) + ")")
  val notBool = "package P\nprotected type Gauge {\n  var level: Int = 1\n  invariant: level + 1\n  entry read(): Int {\n    level\n  }\n}\n"
  assertEqualInt(
    countDiagCode(parseCheck(notBool), "T0132"),
    1,
    "an invariant that is not Bool (" + diagCodesOf(parseCheck(notBool)) + ")"
  )
  val ok = "package P\nprotected type Gauge {\n  var level: Float = 0.1f32\n  invariant: level <= 0.1 and level >= 0.0\n  entry read(): Float {\n    level\n  }\n}\n"
  val okCr = parseCheck(ok)
  assertEqualInt(diagCount(okCr), 0, "fields by bare name and Float literals (" + diagCodesOf(okCr) + ")")
}

test "a protected type's array field follows the zero-fill rule" {
  val ok = "package P\nprotected type T {\n  var hits: array[3, Int]\n}\n"
  val okCr = parseCheck(ok)
  assertEqualInt(diagCount(okCr), 0, "a zeroable element (" + diagCodesOf(okCr) + ")")
  assertEqualInt(okCr.symbols.arrayZeroSites.count, 1, "the field is zero filled")
  val ctor = "package P\nopaque type B {\n  xs: array[2, Int]\n}\nprotected type T {\n  var hits: array[3, Int]\n}\nfunc mk(): Int {\n  val b = B()\n  val t = T()\n  0\n}\n"
  val ctorCr = parseCheck(ctor)
  assertEqualInt(
    countDiagCode(ctorCr, "T0105"),
    0,
    "a zero-filled field is not a required argument (" + diagCodesOf(ctorCr) + ")"
  )
  val bad = "package P\nprotected type T {\n  var names: array[2, String]\n}\n"
  assertEqualInt(
    countDiagCode(parseCheck(bad), "T0156"),
    1,
    "an element with no zero (" + diagCodesOf(parseCheck(bad)) + ")"
  )
}

test "a generic record's array field is zero filled per construction (#8042)" {
  val decl = "package P\nrecord Box[T] {\n  var data: array[2, T]\n  tag: Int\n}\n"
  val ok = decl + "func mk(): Int {\n  val b: Box[Int] = Box(tag = 1)\n  b.data[0]\n}\n"
  val okCr = parseCheck(ok)
  assertEqualInt(diagCount(okCr), 0, "an Int element has a zero (" + diagCodesOf(okCr) + ")")
  assertEqualInt(okCr.symbols.arrayCtorZeroArgs.count, 1, "the construction passes the zero")
  val noZero = decl + "func mk(): Int {\n  val b: Box[String] = Box(tag = 1)\n  b.tag\n}\n"
  assertEqualInt(
    countDiagCode(parseCheck(noZero), "T0105"),
    1,
    "a String element has no zero (" + diagCodesOf(parseCheck(noZero)) + ")"
  )
  val lit = decl + "func mk(): Int {\n  val b = Box(data = [1, 2], tag = 0)\n  b.data[1]\n}\n"
  val litCr = parseCheck(lit)
  assertEqualInt(diagCount(litCr), 0, "a bracket literal binds T (" + diagCodesOf(litCr) + ")")
  val given = decl + "func mk(): Int {\n  val b = Box(data = [1, 2], tag = 0)\n  b.tag\n}\n"
  assertEqualInt(parseCheck(given).symbols.arrayCtorZeroArgs.count, 0, "a given field is not filled")
}

test "toSlice on an array is called, not referenced" {
  val bare = "package P\nfunc f(a: in array[3, Int]): Int {\n  val g = a.toSlice\n  0\n}\n"
  val cr = parseCheck(bare)
  assertEqualInt(countDiagCode(cr, "T0113"), 1, "a bare toSlice (" + diagCodesOf(cr) + ")")
  assertTrue(Str.contains(diagCodesOf(cr), "is called, not referenced"), "the message says to call it")
  val wrapped = "package P\nfunc f(a: in array[3, Int]): Int {\n  val g = { -> a.toSlice() }\n  g().count\n}\n"
  val wcr = parseCheck(wrapped)
  assertEqualInt(diagCount(wcr), 0, "a lambda that calls it (" + diagCodesOf(wcr) + ")")
}

test "an array element passed to out or inout needs a writable array" {
  val bad = "package P\nfunc bump(x: inout Int) {\n  x = x + 10\n}\nfunc f(p: in array[2, Int]) {\n  bump(p[0])\n}\nfunc g() {\n  val a: array[2, Int] = [1, 2]\n  bump(a[1])\n}\n"
  assertEqualInt(countDiagCode(parseCheck(bad), "T0157"), 2, "an element of an in parameter and of a val")
  val ok = "package P\nfunc bump(x: inout Int) {\n  x = x + 10\n}\nfunc f(p: inout array[2, Int]) {\n  bump(p[0])\n  var a: array[2, Int] = [1, 2]\n  bump(a[1])\n}\n"
  val okCr = parseCheck(ok)
  assertEqualInt(diagCount(okCr), 0, "an inout parameter and a var local (" + diagCodesOf(okCr) + ")")
}

test "an array is found at any depth and a recursive shape is T0160" {
  val deep = "package P\nrecord F {\n  arr: array[2, Int]\n}\nrecord E {\n  f: (Int, (Int, (Int, (Int, (Int, (Int, (Int, (Int, (Int, F)))))))))\n}\n@derive(Equals)\nrecord R {\n  e: (Int, (Int, (Int, E)))\n}\n"
  assertEqualInt(
    countDiagCode(parseCheck(deep), "T0159"),
    1,
    "an array twelve levels down (" + diagCodesOf(parseCheck(deep)) + ")"
  )
  val plain = "package P\nrecord G {\n  x: Int\n}\n@derive(Equals)\nrecord R {\n  g: (Int, (Int, (Int, (Int, (Int, (Int, (Int, (Int, (Int, (Int, G))))))))))\n}\n"
  assertEqualInt(
    countDiagCode(parseCheck(plain), "T0159"),
    0,
    "no array at any depth (" + diagCodesOf(parseCheck(plain)) + ")"
  )
  val rec = "package P\nunion Tree {\n  case Leaf(a: array[2, Int])\n  case Node(l: Tree, r: Tree)\n}\nfunc same(x: in Tree, y: in Tree): Bool {\n  x == y\n}\n"
  assertEqualInt(
    countDiagCode(parseCheck(rec), "T0160"),
    1,
    "== on a recursive union holding an array (" + diagCodesOf(parseCheck(rec)) + ")"
  )
}

test "== on a union, tuple or option that holds an array is built element by element" {
  val ok = "package P\nunion U {\n  case A(a: array[2, Int])\n  case B\n}\nfunc f(x: in U, y: in U, p: in (Int, array[2, Int]), q: in (Int, array[2, Int])): Bool {\n  x == y and p != q\n}\n"
  val cr = parseCheck(ok)
  assertEqualInt(diagCount(cr), 0, "clean (" + diagCodesOf(cr) + ")")
  assertEqualInt(cr.symbols.wrapEqSites.count, 2, "both comparisons are recorded")
  val fns = "package P\nfunc f(p: in (array[2, (Int) -> Int], Int), q: in (array[2, (Int) -> Int], Int)): Bool { p == q }\n"
  assertEqualInt(countDiagCode(parseCheck(fns), "T0153"), 1, "a function inside is still T0153")
}

// #7828: a method call that leaves out a defaulted argument records the
// parameter count of the overload it resolved to, so every backend binds the
// same overload; an overload taking exactly the written arguments wins over
// one that fills the rest from defaults, as for a free function.
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

test "a method call omitting a default records the resolved overload's arity (#7828)" {
  val exactSrc = "package P\nrecord O {\n  n: Int\n  func m(self: in O, x: in Int, y: in Int = 2): Int { x + y }\n" +
    "  func m(self: in O, x: in Int): Int { x }\n}\nfunc g(o: in O): Int { o.m(1) }\n"
  val exact = parseCheck(exactSrc)
  assertEqualInt(diagCount(exact), 0, "clean: " + diagCodesOf(exact))
  assertEqualInt(recordedArities(exact).count, 0, "o.m(1) resolves to m(x), which takes exactly the written argument")
  val typedSrc = "package P\nrecord O {\n  n: Int\n  func m(self: in O, x: in String): Int { 0 }\n" +
    "  func m(self: in O, x: in Int, y: in Int = 2): Int { x + y }\n" +
    "  func viaSibling(self: in O): Int { m(1) }\n}\nfunc g(o: in O): Int { o.m(1) }\n"
  val typed = parseCheck(typedSrc)
  assertEqualInt(diagCount(typed), 0, "clean: " + diagCodesOf(typed))
  val ar = recordedArities(typed)
  assertEqualInt(ar.count, 2, "o.m(1) and the bare m(1) both resolve past m(x: String)")
  assertEqualInt(ar[0], 2, "the resolved overload takes two parameters")
  assertEqualInt(ar[1], 2, "the resolved overload takes two parameters")
}

// #8098: a call resolved to a dot-named function records it as such
// (`-1 - count`), so no backend binds the receiver type's same-named method
// instead, whether or not the call leaves out a default.
test "a method call resolved to a dot-named function records it (#8098)" {
  val src = "package P\nrecord O {\n  n: Int\n  func m(self: in O, x: in Int): Int { x }\n}\n" +
    "func O.m(o: in O, x: in Int, y: in Int): Int { x + y }\n" +
    "record E {\n  n: Int\n  func m(self: in E, x: in Int, y: in Int = 2): Int { x + y }\n}\n" +
    "func E.m(e: in E, x: in Int): Int { x }\n" +
    "func g(o: in O, e: in E): Int { o.m(1) + o.m(1, 2) + e.m(1) + e.m(1, 5) }\n"
  val cr = parseCheck(src)
  assertEqualInt(diagCount(cr), 0, "clean: " + diagCodesOf(cr))
  val ar = recordedArities(cr)
  assertEqualInt(ar.count, 2, "o.m(1, 2) and e.m(1) resolve to the dot-named functions")
  assertTrue(ar.contains(-3), "o.m(1, 2): the dot-named O.m taking two")
  assertTrue(ar.contains(-2), "e.m(1): the dot-named E.m taking one, not E's own m(x, y = 2)")
}

// #7828: an impl method whose default differs from the interface member's,
// or which only one of the two declares, is T0161 (a warning) at the impl
// method's parameter; equal defaults are not.
func ifaceDefaultSrc(ifaceParam: in String, implParam: in String): String {
  "package P\ninterface Shape {\n  func area(self: in Self, " + ifaceParam + "): Int\n" +
    "  func label(self: in Self, p: in String = \"s\"): String { p }\n}\n" +
    "record Sq { s: Int }\nimpl Shape for Sq {\n  func area(self: in Sq, " +
    implParam +
    "): Int { self.s * k }\n}\n"
}

test "an impl default that differs from the interface's is T0161 (#7828)" {
  val differ = parseCheck(ifaceDefaultSrc("k: in Int = 2", "k: in Int = 3"))
  assertEqualInt(countDiagCode(differ, "T0161"), 1, "different defaults: " + diagCodesOf(differ))
  assertEqualInt(diagCount(differ), 1, "a warning only")
  assertTrue(diagMessagesContain(differ, "has a different default from the one interface 'Shape' declares"), "message")
  val implOnly = parseCheck(ifaceDefaultSrc("k: in Int", "k: in Int = 3"))
  assertEqualInt(countDiagCode(implOnly, "T0161"), 1, "only the impl declares one: " + diagCodesOf(implOnly))
  assertTrue(diagMessagesContain(implOnly, "has a default that interface 'Shape' does not declare"), "message")
  val ifaceOnly = parseCheck(ifaceDefaultSrc("k: in Int = 2", "k: in Int"))
  assertEqualInt(countDiagCode(ifaceOnly, "T0161"), 1, "only the interface declares one: " + diagCodesOf(ifaceOnly))
  assertTrue(diagMessagesContain(ifaceOnly, "has no default, but interface 'Shape' declares one"), "message")
  val same = parseCheck(ifaceDefaultSrc("k: in Int = (1 + 1)", "k: in Int = 1 + 1"))
  assertEqualInt(countDiagCode(same, "T0161"), 0, "the same default written alike: " + diagCodesOf(same))
  val none = parseCheck(ifaceDefaultSrc("k: in Int", "k: in Int"))
  assertEqualInt(diagCount(none), 0, "no defaults at all: " + diagCodesOf(none))
}

test "an impl overriding an interface default method with another default is T0161 (#7828)" {
  val src = "package P\ninterface Shape {\n  func label(self: in Self, p: in String = \"s\"): String { p }\n}\n" +
    "record Sq { s: Int }\nimpl Shape for Sq {\n  func label(self: in Sq, p: in String = \"q\"): String { p }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0161"), 1, "overridden default method: " + diagCodesOf(cr))
  val sameSrc = "package P\ninterface Shape {\n  func label(self: in Self, p: in String = \"s\"): String { p }\n}\n" +
    "record Sq { s: Int }\nimpl Shape for Sq {\n  func label(self: in Sq, p: in String = \"s\"): String { p }\n}\n"
  assertEqualInt(countDiagCode(parseCheck(sameSrc), "T0161"), 0, "the same default")
}

// #7827: a default known only as a call to a restored package's compiled
// thunk is not compared; a one-sided default still is.
test "T0161 does not compare a default known only as a thunk call (#7827)" {
  val thunk = "func __lyric_default__Shape__area__2__k(): Int { 2 }\n"
  val src = "package P\n" + thunk +
    "interface Shape {\n  func area(self: in Self, k: in Int = __lyric_default__Shape__area__2__k()): Int\n}\n" +
    "record Sq { s: Int }\nimpl Shape for Sq {\n  func area(self: in Sq, k: in Int = 3): Int { self.s * k }\n}\n"
  val cr = parseCheck(src)
  assertEqualInt(countDiagCode(cr, "T0161"), 0, "not compared: " + diagCodesOf(cr))
  val oneSided = "package P\n" + thunk +
    "interface Shape {\n  func area(self: in Self, k: in Int = __lyric_default__Shape__area__2__k()): Int\n}\n" +
    "record Sq { s: Int }\nimpl Shape for Sq {\n  func area(self: in Sq, k: in Int): Int { self.s * k }\n}\n"
  assertEqualInt(countDiagCode(parseCheck(oneSided), "T0161"), 1, "the impl declares none")
}

// #8085: two methods of one name in one record, interface or impl must
// differ in their number of parameters, as two functions must (T0001);
// overloads of different counts stay valid.
test "same-name methods with one parameter count are T0162 (#8085)" {
  val rec = parseCheck(
    "package P\nrecord R {\n  n: Int\n  func scale(self: in R, x: in Int, f: in Int = 1): Int { x * f }\n" +
      "  func scale(self: in R, x: in String, f: in Int = 2): Int { f }\n}\n"
  )
  assertEqualInt(countDiagCode(rec, "T0162"), 1, "record: " + diagCodesOf(rec))
  assertTrue(diagMessagesContain(rec, "method 'scale' of 'R' has the same number of parameters (3)"), "message")
  val iface = parseCheck(
    "package P\ninterface I {\n  func m(self: in Self, x: in Int): Int\n  func m(self: in Self, x: in String): Int\n}\n"
  )
  assertEqualInt(countDiagCode(iface, "T0162"), 1, "interface: " + diagCodesOf(iface))
  val implSrc = parseCheck(
    "package P\ninterface I {\n  func m(self: in Self, x: in Int): Int\n}\nrecord Q { q: Int }\n" +
      "impl I for Q {\n  func m(self: in Q, x: in Int): Int { x }\n  func m(self: in Q, x: in String): Int { 0 }\n}\n"
  )
  assertEqualInt(countDiagCode(implSrc, "T0162"), 1, "impl: " + diagCodesOf(implSrc))
  val ok = parseCheck(
    "package P\nrecord R {\n  n: Int\n  func scale(self: in R, x: in Int): Int { x }\n" +
      "  func scale(self: in R, x: in Int, f: in Int = 2): Int { x * f }\n}\n"
  )
  assertEqualInt(countDiagCode(ok, "T0162"), 0, "different counts: " + diagCodesOf(ok))
}

// #8085 review: T0161 compares every expression form, so an interpolated or
// an `if` default written the same way in both places is not reported.
test "identical interpolated and if defaults are not T0161 (#8085)" {
  val interp = parseCheck(
    ifaceDefaultSrc("k: in String = \"a\${1 + 1}b\"", "k: in String = \"a\${1 + 1}b\"").replace(
      "self.s * k",
      "self.s"
    )
  )
  assertEqualInt(countDiagCode(interp, "T0161"), 0, "interpolated: " + diagCodesOf(interp))
  val cond = parseCheck(ifaceDefaultSrc("k: in Int = if true { 2 } else { 3 }", "k: in Int = if true { 2 } else { 3 }"))
  assertEqualInt(countDiagCode(cond, "T0161"), 0, "if: " + diagCodesOf(cond))
  val condDiff = parseCheck(
    ifaceDefaultSrc("k: in Int = if true { 2 } else { 3 }", "k: in Int = if true { 2 } else { 4 }")
  )
  assertEqualInt(countDiagCode(condDiff, "T0161"), 1, "a different if: " + diagCodesOf(condDiff))
}
