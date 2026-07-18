//! mono_self_test.l — exercises the self-hosted Lyric.Mono library.
//! Run in CI via native `lyric test` (no F# runner shim).
//!
//! Covers (docs/41 §9 Band 5 / #858):
//!   • Same-package specialisation via call-site inference (the
//!     existing baseline behaviour).
//!   • Value-generic specialisation via direct ETypeApp AST
//!     construction.  Lyric's surface syntax parses `f[T]` as an
//!     index expression rather than as a type-app, so value-generic
//!     call sites are exercised by building the AST node directly.
//!     The same code path activates once an explicit type-app surface
//!     ships (or once another middle-end pass synthesises ETypeApp).
//!   • Constraint validation: well-known marker constraints accept
//!     primitive substitutions silently; the diagnostic list stays
//!     empty.
//!   • Cross-package surface: `monoFileWithImports` specialises an
//!     imported generic decl into the user's compilation unit.
//!   • Worklist termination + nested generic call sites.
//!
//! Plus #349 inference improvements:
//!   • Nested generic-call return inference (outer call's type arg
//!     comes from inner call's return).
//!   • Record field projection inference (recv.field).
//!   • Non-generic same-package return chaining.
//!   • Multi-param inference mixing nested calls and literals.
@test_module
package Lyric.MonoSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.AliasRewriter
import Lyric.Mono

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────
func runMono(src: in String): MonoResult {
  val pr = parse(src)
  monoFile(pr.file)
}

func hasFunc(file: in SourceFile, name: in String): Bool {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> {
        if decl.name == name {
          return true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

func findFunc(file: in SourceFile, name: in String): Option[FunctionDecl] {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> {
        if decl.name == name {
          return Some(value = decl)
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  None
}

// Pull the trailing (implicit-return or explicit `return`) expression out of
// a func's body — mirrors `Lyric.Mono.lambdaBodyResultTE`'s statement-kind
// match.  Used to inspect what a call site's callee looks like AFTER mono,
// so a test can assert a call was left completely UNREWRITTEN (still names
// the original bare function, not a `__`-suffixed specialisation).
func lastStmtExprInFunc(file: in SourceFile, name: in String): Option[Expr] {
  match findFunc(file, name) {
    case None -> None
    case Some(decl) -> match decl.body { case None -> None; case Some(fb) -> match fb { case FBExpr(e) -> Some(value = e); case FBBlock(blk) -> { if blk.statements.count == 0 { None } else { match blk.statements[blk.statements.count - 1].kind { case SExpr(e) -> Some(value = e); case SReturn(vOpt) -> vOpt; case _ -> None } } } } }
  }
}

// The bare (single-segment) callee name of `e`, when `e` is a plain
// `ECall(EPath([name]), args)` — `None` for anything else (a specialised
// call site's callee is still a single-segment `EPath`, just under the
// mangled `__`-suffixed name, so this only needs the single-segment case).
func callFnBareName(e: in Expr): Option[String] {
  match e.kind {
    case ECall(fn, _) -> match fn.kind { case EPath(p) -> { if p.segments.count == 1 { Some(value = p.segments[0]) } else { None } }; case _ -> None }
    case _ -> None
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic-AST helpers
// ─────────────────────────────────────────────────────────────────────────────
//
// Lyric's surface syntax parses `f[T](args)` as `EIndex` followed by `ECall`,
// not as `ETypeApp`.  To exercise the value-generic + explicit-type-app
// codepath in `Lyric.Mono`, we splice a synthetic ETypeApp call into a
// parsed source's caller body.  The helpers below rebuild a SourceFile by
// substituting one function's body with a synthetic ECall(ETypeApp(...),
// []) expression.
func syntheticSpan(): Span {
  Span(startPos = Position(offset = 0, line = 1, column = 1), endPos = Position(offset = 0, line = 1, column = 1))
}

func pathExpr(name: in String): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  Expr(kind = EPath(path = ModulePath(segments = segs, span = syntheticSpan())), span = syntheticSpan())
}

func litIntExpr(value: in Long): Expr {
  Expr(kind = ELiteral(lit = LInt(value = value, suffix = NoIntSuffix, raw = "")), span = syntheticSpan())
}

func litStringExpr(text: in String): Expr {
  Expr(kind = ELiteral(lit = LString(text = text)), span = syntheticSpan())
}

func litFloatExpr(raw: in String): Expr {
  Expr(kind = ELiteral(lit = LFloat(value = 0.0, suffix = NoFloatSuffix, raw = raw)), span = syntheticSpan())
}

// Count the items in `file` whose function name starts with `prefix`.  Used to
// assert that two distinct value-generic args produced two distinct
// specialisations rather than colliding onto one (the #5502 regression).
func countFuncsWithPrefix(file: in SourceFile, prefix: in String): Int {
  var n = 0
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> if decl.name.startsWith(prefix) { n = n + 1 }
      case _ -> ()
    }
    i = i + 1
  }
  n
}

func typeRefExpr(name: in String): TypeExpr {
  val segs: List[String] = newList()
  segs.add(name)
  TypeExpr(kind = TRef(path = ModulePath(segments = segs, span = syntheticSpan())), span = syntheticSpan())
}

// Build a synthetic `ECall(ETypeApp(EPath(fname), targs), args)` Expr.
func synthTypeAppCall(fname: in String, targs: in List[TypeArg], args: in List[CallArg]): Expr {
  val fn = pathExpr(fname)
  val typeApp = Expr(kind = ETypeApp(fn = fn, args = targs), span = syntheticSpan())
  Expr(kind = ECall(fn = typeApp, args = args), span = syntheticSpan())
}

// Replace the body of the function named `callerName` in `file` with an
// expression body containing `bodyExpr`.  All other items pass through
// unchanged.  Used to splice a synthetic ETypeApp call into a parsed
// source for value-generic testing.
func replaceCallerBody(file: in SourceFile, callerName: in String, bodyExpr: in Expr): SourceFile {
  val newItems: List[Item] = newList()
  var i = 0
  while i < file.items.count {
    val item = file.items[i]
    match item.kind {
      case IFunc(decl) -> {
        if decl.name == callerName {
          val newDecl = FunctionDecl(
            docComments = decl.docComments,
            annotations = decl.annotations,
            visibility = decl.visibility,
            isAsync = decl.isAsync,
            name = decl.name,
            generics = decl.generics,
            params = decl.params,
            ret = decl.ret,
            whereClause = decl.whereClause,
            contracts = decl.contracts,
            body = Some(value = FBExpr(expr = bodyExpr)),
            span = decl.span
          )
          newItems.add(
            Item(
              docComments = item.docComments,
              annotations = item.annotations,
              visibility = item.visibility,
              kind = IFunc(decl = newDecl),
              span = item.span
            )
          )
        } else {
          newItems.add(item)
        }
      }
      case _ -> newItems.add(item)
    }
    i = i + 1
  }
  SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = newItems,
    span = file.span
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────
// Type-generic inference via param annotation — the existing baseline.
test "type generic inferred" {
  val src = "package P\n" + "func id[T](x: in T): T { x }\n" + "func caller(): Int { id(7) }\n"
  val res = runMono(src)
  assertTrue(hasFunc(res.file, "id__Int"), "id__Int specialisation emitted")
  assertTrue(not hasFunc(res.file, "id"), "generic id removed from output")
  assertEqualInt(res.diagnostics.count, 0, "no mono diagnostics")
}

// Explicit ETypeApp from a synthetic AST — exercises the
// non-inference path through `rewriteExpr`.
test "type generic explicit type app" {
  val src = "package P\n" + "func empty[T](): Int { 0 }\n" + "func caller(): Int { 0 }\n"
  val pr = parse(src)

  val targs: List[TypeArg] = newList()
  targs.add(TAType(ty = typeRefExpr("String")))
  val synthCall = synthTypeAppCall("empty", targs, newList())
  val patched = replaceCallerBody(pr.file, "caller", synthCall)

  val res = monoFile(patched)
  assertTrue(hasFunc(res.file, "empty__String"), "empty__String specialisation emitted via explicit ETypeApp")
}

// Value-generic specialisation via synthetic AST: ETypeApp carrying
// a single TAValue(LInt(3)) argument.
test "value generic explicit" {
  val src = "package P\n" + "func ones[N: Nat](): Int { 0 }\n" + "func caller(): Int { 0 }\n"
  val pr = parse(src)

  val targs: List[TypeArg] = newList()
  targs.add(TAValue(expr = litIntExpr(3i64)))
  val synthCall = synthTypeAppCall("ones", targs, newList())
  val patched = replaceCallerBody(pr.file, "caller", synthCall)

  val res = monoFile(patched)
  assertTrue(hasFunc(res.file, "ones__V3"), "ones__V3 specialisation emitted for value-generic (key 'V' prefix)")
  assertTrue(not hasFunc(res.file, "ones"), "generic ones removed from output")
}

// Two distinct value args produce two distinct specialisations.
test "value generic distinct specs" {
  val src = "package P\n" + "func ones[N: Nat](): Int { 0 }\n" + "func caller(): Int { 0 }\n"
  val pr = parse(src)

  // Build a synthetic block containing two ETypeApp calls: ones[3] and ones[5].
  val targs3: List[TypeArg] = newList()
  targs3.add(TAValue(expr = litIntExpr(3i64)))
  val targs5: List[TypeArg] = newList()
  targs5.add(TAValue(expr = litIntExpr(5i64)))
  val call3 = synthTypeAppCall("ones", targs3, newList())
  val call5 = synthTypeAppCall("ones", targs5, newList())

  // Splice each into a separate `caller` body and run mono twice; the
  // simpler approach is to fold both into one binop.
  val sum = Expr(kind = EBinop(op = BAdd, lhs = call3, rhs = call5), span = syntheticSpan())
  val patched = replaceCallerBody(pr.file, "caller", sum)

  val res = monoFile(patched)
  assertTrue(hasFunc(res.file, "ones__V3"), "ones__V3 emitted")
  assertTrue(hasFunc(res.file, "ones__V5"), "ones__V5 emitted")
}

// #5502 regression: two DISTINCT, equal-length String value-args must produce
// two distinct specialisations.  The pre-fix key `"s" + length` collided any
// two equal-length strings, so the second value reused the first's spec via
// `seenSpecs` — baking the wrong string constant into the emitted IL.
test "value generic distinct string specs (no key collision)" {
  val src = "package P\n" + "func tag[S: Str](): Int { 0 }\n" + "func caller(): Int { 0 }\n"
  val pr = parse(src)

  // "ab" and "cd" are both length 2 — the exact collision the old key hit.
  val targsAb: List[TypeArg] = newList()
  targsAb.add(TAValue(expr = litStringExpr("ab")))
  val targsCd: List[TypeArg] = newList()
  targsCd.add(TAValue(expr = litStringExpr("cd")))
  val callAb = synthTypeAppCall("tag", targsAb, newList())
  val callCd = synthTypeAppCall("tag", targsCd, newList())
  val sum = Expr(kind = EBinop(op = BAdd, lhs = callAb, rhs = callCd), span = syntheticSpan())
  val patched = replaceCallerBody(pr.file, "caller", sum)

  val res = monoFile(patched)
  assertEqualInt(
    countFuncsWithPrefix(res.file, "tag__"),
    2,
    "two equal-length string args must yield two distinct specialisations, not one collided spec"
  )
  assertTrue(not hasFunc(res.file, "tag"), "generic tag removed from output")
}

// #5502 regression: two DISTINCT Float value-args must produce two distinct
// specialisations.  The pre-fix key was the constant `"f"` for every float
// literal, so all float-valued generics collided onto one spec.
test "value generic distinct float specs (no key collision)" {
  val src = "package P\n" + "func scale[F: Real](): Int { 0 }\n" + "func caller(): Int { 0 }\n"
  val pr = parse(src)

  val targs15: List[TypeArg] = newList()
  targs15.add(TAValue(expr = litFloatExpr("1.5")))
  val targs25: List[TypeArg] = newList()
  targs25.add(TAValue(expr = litFloatExpr("2.5")))
  val call15 = synthTypeAppCall("scale", targs15, newList())
  val call25 = synthTypeAppCall("scale", targs25, newList())
  val sum = Expr(kind = EBinop(op = BAdd, lhs = call15, rhs = call25), span = syntheticSpan())
  val patched = replaceCallerBody(pr.file, "caller", sum)

  val res = monoFile(patched)
  assertEqualInt(
    countFuncsWithPrefix(res.file, "scale__"),
    2,
    "two distinct float args must yield two distinct specialisations, not one collided spec"
  )
  assertTrue(not hasFunc(res.file, "scale"), "generic scale removed from output")
}

// The substituted body of a value-generic specialisation no longer
// references the value-param name as an `EPath` leaf.
test "value generic body substituted" {
  val src = "package P\n" + "func ones[N: Nat](): Int { N }\n" + "func caller(): Int { 0 }\n"
  val pr = parse(src)

  val targs: List[TypeArg] = newList()
  targs.add(TAValue(expr = litIntExpr(7i64)))
  val synthCall = synthTypeAppCall("ones", targs, newList())
  val patched = replaceCallerBody(pr.file, "caller", synthCall)

  val res = monoFile(patched)
  match findFunc(res.file, "ones__V7") {
    case None -> panic("ones__V7 missing")
    case Some(decl) -> {
      assertTrue(not bodyReferencesPath(decl.body, "N"), "ones__V7 body no longer references N (substitution fired)")
    }
  }
}

// True iff `body` contains any `EPath([name])` shape — used to confirm
// that value-generic substitution rewrote every leaf occurrence of the
// value parameter.
func bodyReferencesPath(body: in Option[FunctionBody], name: in String): Bool {
  match body {
    case None -> false
    case Some(fb) -> {
      match fb {
        case FBExpr(e) -> exprReferencesPath(e, name)
        case FBBlock(b) -> blockReferencesPath(b, name)
      }
    }
  }
}

func exprReferencesPath(e: in Expr, name: in String): Bool {
  match e.kind {
    case EPath(p) -> p.segments.count == 1 and p.segments[0] == name
    case EParen(inner) -> exprReferencesPath(inner, name)
    case EBinop(_, lhs, rhs) -> exprReferencesPath(lhs, name) or exprReferencesPath(rhs, name)
    case EBlock(b) -> blockReferencesPath(b, name)
    case _ -> false
  }
}

func blockReferencesPath(b: in Block, name: in String): Bool {
  var i = 0
  while i < b.statements.count {
    val st = b.statements[i]
    match st.kind {
      case SExpr(e) -> {
        if exprReferencesPath(e, name) {
          return true
        }
      }
      case SReturn(opt) -> {
        match opt {
          case Some(e) -> {
            if exprReferencesPath(e, name) {
              return true
            }
          }
          case None -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

// Mixed type + value generics: `func f[T, N: Nat](x: T): T` produces a
// mangled spec name combining both T and N substitutions.
test "mixed type and value generics" {
  val src = "package P\n" + "func repN[T, N: Nat](x: in T): T { x }\n" + "func caller(): Int { 0 }\n"
  val pr = parse(src)

  val targs: List[TypeArg] = newList()
  targs.add(TAType(ty = typeRefExpr("Int")))
  targs.add(TAValue(expr = litIntExpr(4i64)))
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = litIntExpr(9i64)))
  val synthCall = synthTypeAppCall("repN", targs, args)
  val patched = replaceCallerBody(pr.file, "caller", synthCall)

  val res = monoFile(patched)
  assertTrue(hasFunc(res.file, "repN__Int__V4"), "repN__Int__V4 mangled name combines type + value args")
}

// Constraint validation: where clause with marker constraint and a
// primitive concrete type produces no diagnostic.
test "constraint primitive accepted" {
  val src = "package P\n" + "func eqCheck[T](a: in T, b: in T): Bool where T: Equals { true }\n" +
    "func caller(): Bool { eqCheck(1, 2) }\n"
  val res = runMono(src)
  assertTrue(hasFunc(res.file, "eqCheck__Int"), "eqCheck__Int specialisation emitted")
  assertEqualInt(res.diagnostics.count, 0, "primitive Int satisfies Equals marker — no diagnostics")
}

// Worklist termination + nested generic call site.
test "nested generic call chain" {
  val src = "package P\n" + "func id[T](x: in T): T { x }\n" + "func twice[T](x: in T): T { id(x) }\n" +
    "func caller(): Int { twice(42) }\n"
  val res = runMono(src)
  assertTrue(hasFunc(res.file, "twice__Int"), "twice__Int emitted")
  assertTrue(hasFunc(res.file, "id__Int"), "nested id call inside twice__Int specialises to id__Int")
}

// Cross-package surface: `monoFileWithImports` with an imported generic
// FunctionDecl specialises it in the caller's file just like a
// same-package generic.
test "cross package imported generic" {
  val callerSrc = "package Caller\n" + "func caller(): Int { idImported(11) }\n"
  val importedSrc = "package Lib\n" + "pub func idImported[T](x: in T): T { x }\n"

  val callerPr = parse(callerSrc)
  val importedPr = parse(importedSrc)

  // Pull every generic IFunc decl out of the imported file.
  val importedGen: List[FunctionDecl] = newList()
  var i = 0
  while i < importedPr.file.items.count {
    match importedPr.file.items[i].kind {
      case IFunc(decl) -> {
        match decl.generics {
          case Some(_) -> importedGen.add(decl)
          case None -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }

  val res = monoFileWithImports(callerPr.file, importedGen)
  assertTrue(
    hasFunc(res.file, "idImported__Int"),
    "cross-package idImported__Int specialisation appended to caller file"
  )
}

// Collect the generic IFunc decls of a parsed file plus the inference-only
// union-case constructor synths for its unions — the same feed the MSIL
// bridge composes via `collectStdlibGenericFuncs` + `collectStdlibUnionCtorDecls`.
func genericsAndUnionCtors(file: in SourceFile): List[FunctionDecl] {
  val feed: List[FunctionDecl] = newList()
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> {
        match decl.generics {
          case Some(_) -> feed.add(decl)
          case None -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  val ctors = unionCtorInferenceDecls(file.items)
  var ci = 0
  while ci < ctors.count {
    feed.add(ctors[ci])
    ci = ci + 1
  }
  feed
}

// #5604: a generic call whose only type-argument source is a UNION-CASE
// CONSTRUCTOR argument (`isSome(Some(value = 1))`) must specialise.  The
// inference-only ctor synths (`unionCtorInferenceDecls`) type the argument
// as `OptLike[Int]`, binding T — without them the call silently stayed
// generic and codegen dropped it (returning its own argument).
test "union-case ctor argument binds imported generic's type param (#5604)" {
  val callerSrc = "package Caller\n" + "func caller(): Bool { isLike(SomeLike(v = 5)) }\n"
  val libSrc = "package Lib\n" + "pub union OptLike[T] { case SomeLike(v: T)\n case NoneLike }\n" +
    "pub func isLike[T](o: in OptLike[T]): Bool { match o { case SomeLike(x) -> true\n case _ -> false } }\n"
  val callerPr = parse(callerSrc)
  val libPr = parse(libSrc)
  val res = monoFileWithImports(callerPr.file, genericsAndUnionCtors(libPr.file))
  assertTrue(hasFunc(res.file, "isLike__Int"), "isLike specialises to isLike__Int from the SomeLike(v = 5) argument")
  assertFalse(hasFunc(res.file, "SomeLike__Int"), "the inference-only ctor synth is never itself specialised")
}

// Same-file unions get the same treatment without any imported feed: the
// monomorphizer synthesises the ctor decls from the file's own IUnion items.
test "union-case ctor argument binds same-file generic's type param (#5604)" {
  val src = "package P\n" + "union BoxLike[T] { case Full(v: T)\n case Empty }\n" +
    "func pick[T](b: in BoxLike[T]): Bool { match b { case Full(x) -> true\n case _ -> false } }\n" +
    "func caller(): Bool { pick(Full(v = 3)) }\n"
  val res = runMono(src)
  assertTrue(hasFunc(res.file, "pick__Int"), "pick specialises to pick__Int from the Full(v = 3) argument")
}

// #5604: a lambda argument's ANNOTATED parameter types (and, when the body
// ends in an inferable trailing expression, its result type) bind type
// params.  `forEach([], { x: Int -> () })` / `mapOption(None, { x: Int ->
// x * 2 })` were the stdlib shapes that silently stayed generic.
test "lambda argument binds imported generic's type params (#5604)" {
  val callerSrc = "package Caller\n" + "func caller(): Bool { mapLike(1, { y: Int -> y > 0 }) }\n"
  val libSrc = "package Lib\n" + "pub func mapLike[T, U](x: in T, f: (T) -> U): U { f(x) }\n"
  val callerPr = parse(callerSrc)
  val libPr = parse(libSrc)
  val res = monoFileWithImports(callerPr.file, genericsAndUnionCtors(libPr.file))
  assertTrue(
    hasFunc(res.file, "mapLike__Int__Bool"),
    "mapLike binds T from the lambda's annotated param and U from its body"
  )
}

// #5841: `Type.tryFrom(x)` / `Type.from(x)` are compiler-synthesised static
// factories on a distinct/range-subtype (#1501) — `recv` is a bare type NAME
// that never resolves to a value, so before this fix `inferCallReturnTE`
// could not see through the call at all.  A generic caller inferring its
// type argument from the result (`isOkLike(Age.tryFrom(25))`) then fell back
// to defaulting BOTH `T` and `E` to `Object`, producing a specialisation
// (`Object`/`Object`) that does not match the real `Result[Age, String]`
// instantiation the codegen backend actually constructs — a runtime
// mismatch at the union-match site (#5841).
test "distinct-type tryFrom feeds imported generic specialisation with the real payload type (#5841)" {
  val callerSrc = "package Caller\n" + "type Age = Int range 0 ..= 150\n" +
    "func caller(): Bool { isOkLike(Age.tryFrom(25)) }\n"
  val libSrc = "package Lib\n" +
    "pub func isOkLike[T, E](r: in Result[T, E]): Bool { match r { case Ok(_) -> true\n case Err(_) -> false } }\n"
  val callerPr = parse(callerSrc)
  val libPr = parse(libSrc)
  val res = monoFileWithImports(callerPr.file, genericsAndUnionCtors(libPr.file))
  assertTrue(
    hasFunc(res.file, "isOkLike__Age__String"),
    "Age.tryFrom(...) infers Result[Age, String] — not the Object/Object default"
  )
  assertFalse(hasFunc(res.file, "isOkLike__Object__Object"), "must not fall back to the Object/Object default")
}

test "distinct-type from feeds imported generic specialisation with the real payload type (#5841)" {
  val callerSrc = "package Caller\n" + "type Age = Int range 0 ..= 150\n" +
    "func caller(): Bool { isLike(Age.from(5)) }\n"
  val libSrc = "package Lib\n" + "pub func isLike[T](x: in T): Bool { true }\n"
  val callerPr = parse(callerSrc)
  val libPr = parse(libSrc)
  val res = monoFileWithImports(callerPr.file, genericsAndUnionCtors(libPr.file))
  assertTrue(hasFunc(res.file, "isLike__Age"), "Age.from(...) infers Age, not the Object default")
}

// #5843: two DIFFERENT cross-package functions can share a bare name (the
// bridges collect every stdlib package's non-generic `pub func`s into one
// flat inference pool regardless of what the compiled file imports, e.g.
// `Std.String.toUpper(String): String` vs `Std.Char.toUpper(Char): Char`).
// A first fix (#5843) evicted the ambiguous name from inference entirely so
// a generic caller could never guess the WRONG overload's return type and
// mis-specialise into an instantiation the runtime value never has — but
// that pushed EVERY ambiguous call onto the Object-fallback specialisation,
// which doesn't just leave the call un-specialised, it CRASHES at runtime
// against a real generic instantiation (the erased `Object`/`Object` arms
// can never match).  This supersedes that eviction with call-site overload
// resolution (#5961/#5962 preserved): when the call site's argument types
// are known, they resolve the ambiguity instead of evicting it — here the
// lambda's ANNOTATED `s: String` param uniquely matches `LibA.dup(String):
// String` (not `LibB.dup(Char): Char`), so `U` correctly specialises to
// `String`, not the erased `Object` default.
test "ambiguous cross-package function name resolves via call-site argument-type matching (#5843, supersedes eviction)" {
  val callerSrc = "package Caller\n" + "func caller(): String { mapLike2(\"hi\", { s: String -> dup(s) }) }\n"
  val libSrc = "package Lib\n" + "pub func mapLike2[T, U](x: in T, f: (T) -> U): U { f(x) }\n"
  val libASrc = "package LibA\n" + "pub func dup(s: in String): String { s + s }\n"
  val libBSrc = "package LibB\n" + "pub func dup(c: in Char): Char { c }\n"

  val callerPr = parse(callerSrc)
  val libPr = parse(libSrc)
  val libAPr = parse(libASrc)
  val libBPr = parse(libBSrc)

  val feed: List[FunctionDecl] = newList()
  var i = 0
  while i < libPr.file.items.count {
    match libPr.file.items[i].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    i = i + 1
  }
  var ja = 0
  while ja < libAPr.file.items.count {
    match libAPr.file.items[ja].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    ja = ja + 1
  }
  var jb = 0
  while jb < libBPr.file.items.count {
    match libBPr.file.items[jb].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    jb = jb + 1
  }

  val res = monoFileWithImports(callerPr.file, feed)
  assertTrue(
    hasFunc(res.file, "mapLike2__String__String"),
    "the lambda's annotated 'String' param uniquely matches LibA.dup; U resolves to String, not the Object default"
  )
  assertFalse(
    hasFunc(res.file, "mapLike2__String__Object"),
    "a resolvable call site must not degrade to the Object fallback"
  )
  assertFalse(hasFunc(res.file, "mapLike2__String__Char"), "must never guess the wrong overload's return type")
}

// Counterpart of the above: when the call site's argument type is NOT
// knowable (an unannotated lambda param with no other type source), overload
// resolution has nothing to match against and correctly gives up — the
// generic still safely defaults to Object instead of guessing, exactly the
// #5843 degradation the eviction fix relied on.
//
// The lambda body calls `dup(w)` on a name that is never bound anywhere
// (not a lambda param, not a local) rather than reusing the lambda's own
// `T`-typed param: #5604 seeds an UNANNOTATED lambda param from the
// declared parameter type once the caller's substitution already makes it
// concrete, so `{ z -> dup(z) }` would actually still resolve `z: String`
// via `T` (already pinned by the `"hi"` argument) — a genuinely
// unresolvable argument needs a type source `T`'s pinning cannot reach.
test "ambiguous cross-package function name with an unresolvable call site still defaults to Object (#5843)" {
  val callerSrc = "package Caller\n" + "func caller(): Object { mapLike2(\"hi\", { z -> dup(w) }) }\n"
  val libSrc = "package Lib\n" + "pub func mapLike2[T, U](x: in T, f: (T) -> U): U { f(x) }\n"
  val libASrc = "package LibA\n" + "pub func dup(s: in String): String { s + s }\n"
  val libBSrc = "package LibB\n" + "pub func dup(c: in Char): Char { c }\n"

  val callerPr = parse(callerSrc)
  val libPr = parse(libSrc)
  val libAPr = parse(libASrc)
  val libBPr = parse(libBSrc)

  val feed: List[FunctionDecl] = newList()
  var i = 0
  while i < libPr.file.items.count {
    match libPr.file.items[i].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    i = i + 1
  }
  var ja = 0
  while ja < libAPr.file.items.count {
    match libAPr.file.items[ja].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    ja = ja + 1
  }
  var jb = 0
  while jb < libBPr.file.items.count {
    match libBPr.file.items[jb].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    jb = jb + 1
  }

  val res = monoFileWithImports(callerPr.file, feed)
  assertTrue(
    hasFunc(res.file, "mapLike2__String__Object"),
    "an untyped lambda param gives overload resolution nothing to match; U safely defaults to Object instead of guessing"
  )
  assertFalse(hasFunc(res.file, "mapLike2__String__Char"), "must never guess the wrong overload's return type")
  assertFalse(hasFunc(res.file, "mapLike2__String__String"), "must never guess either overload's return type")
}

// Regression pin for the real-world shape that motivated superseding blunt
// eviction with call-site overload resolution: `lyric-storage`'s
// `isOk(delete(bucket, key))` crashed at runtime because `delete` was
// ambiguous across `Std.Directory.delete(String): Result[Unit, IOError]`
// (arity 1), `Storage.delete(bucket, key): Result[Unit, StorageError]`
// (arity 2), and `Cache.delete(store, key): Unit` (arity 2) — eviction
// discarded the name entirely, so `isOk` degraded to the Object-defaulted
// `isOk__Object__Object`, which then panicked (`match not exhaustive`)
// against the real `Result[Unit, StorageError]` instance at runtime.  Here,
// an arity-1 and an arity-2 overload share the bare name `del`; a
// 2-argument call site can only mean the arity-2 overload, so ARITY ALONE
// must resolve it (before any argument-type matching is even attempted) —
// assert the resulting specialisation carries that overload's return type
// (`Result[Unit, String]`), not the Object-defaulted fallback.
test "arity alone disambiguates an ambiguous name at a 2-argument call site (storage delete shape)" {
  val callerSrc = "package Caller\n" + "record SomeRecord { tag: Int }\n" +
    "func mkRec(): SomeRecord { SomeRecord(tag = 1) }\n" +
    "func caller(): Bool { isOkLike(del(mkRec(), \"k\")) }\n"
  val libSrc = "package Lib\n" + "pub func isOkLike[T, E](r: in Result[T, E]): Bool { true }\n"
  val libASrc = "package LibA\n" + "pub func del(s: in String): Result[Unit, String] { del(s) }\n"
  val libBSrc = "package LibB\n" + "pub func del(b: in SomeRecord, k: in String): Result[Unit, String] { del(b, k) }\n"

  val callerPr = parse(callerSrc)
  val libPr = parse(libSrc)
  val libAPr = parse(libASrc)
  val libBPr = parse(libBSrc)

  val feed: List[FunctionDecl] = newList()
  var i = 0
  while i < libPr.file.items.count {
    match libPr.file.items[i].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    i = i + 1
  }
  var ja = 0
  while ja < libAPr.file.items.count {
    match libAPr.file.items[ja].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    ja = ja + 1
  }
  var jb = 0
  while jb < libBPr.file.items.count {
    match libBPr.file.items[jb].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    jb = jb + 1
  }

  val res = monoFileWithImports(callerPr.file, feed)
  assertTrue(
    hasFunc(res.file, "isOkLike__Unit__String"),
    "a 2-argument call site can only match the arity-2 'del' overload; isOkLike specialises over Result[Unit, String]"
  )
  assertFalse(
    hasFunc(res.file, "isOkLike__Object__Object"),
    "must not degrade to the Object fallback when arity alone resolves the ambiguity"
  )
}

// Regression pin for the `lyric-validation`/`Std.Iter` shape found in a
// round-6 follow-up review: `Validation.all(errors: in slice[slice[...]]):
// slice[...]` (arity 1, NON-generic) and `Std.Iter.all[T](xs: in slice[T],
// pred: (T) -> Bool): Bool` (arity 2, GENERIC) share the bare name `all`.
// The INFERENCE-side ambiguity fix above (`resolveAmbiguousOverload`) does
// not, by itself, protect the separate Phase-2 REWRITE path: `genDecls` is a
// first-wins slot exactly like `funcDecls`, so if the GENERIC candidate
// happens to be collected first, it occupies `genDecls["all"]` — and
// `rewriteExpr`'s bare-`EPath` generic-call arm only rejected call sites with
// MORE arguments than the generic's param count (the #3627/#3677 guard),
// never FEWER, so the arity-1 `all(errors)` call slipped through, got
// "specialised" against the arity-2 generic's signature, and was rewritten
// with an argument list that doesn't match the specialisation it names —
// invalid IL at runtime.  `genDeclResolvesForCallSite` closes this by
// checking, for an ambiguous name, that THIS call site's arguments actually
// resolve (via `resolveAmbiguousOverload`) to the specific candidate sitting
// in `genDecls` before rewriting proceeds.  Feeds the GENERIC decl first so
// it wins the first-wins `genDecls` slot, exactly reproducing the reported
// collection order.
test "non-generic arity-1 sharing a name with a generic arity-2 is left unspecialised (lyric-validation/Std.Iter shape)" {
  val callerSrc = "package Caller\n" + "func caller(xs: in slice[slice[String]]): slice[String] { all(xs) }\n"
  val genLibSrc = "package Iter\n" + "pub func all[T](xs: in slice[T], pred: in (T) -> Bool): Bool { true }\n"
  val nonGenLibSrc = "package Validation\n" +
    "pub func all(errors: in slice[slice[String]]): slice[String] { errors[0] }\n"

  val callerPr = parse(callerSrc)
  val genLibPr = parse(genLibSrc)
  val nonGenLibPr = parse(nonGenLibSrc)

  // Generic first, so it wins `genDecls`' first-wins slot under "all" —
  // this ordering is exactly what exposed the bug.
  val feed: List[FunctionDecl] = newList()
  var gi = 0
  while gi < genLibPr.file.items.count {
    match genLibPr.file.items[gi].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    gi = gi + 1
  }
  var ni = 0
  while ni < nonGenLibPr.file.items.count {
    match nonGenLibPr.file.items[ni].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    ni = ni + 1
  }

  val res = monoFileWithImports(callerPr.file, feed)
  assertFalse(hasFunc(res.file, "all__String"), "must not create a bogus specialisation of the generic 'all'")
  assertFalse(hasFunc(res.file, "all__Slice_String"), "must not create a bogus specialisation of the generic 'all'")
  match lastStmtExprInFunc(res.file, "caller") {
    case None -> assertTrue(false, "caller's body must still be inspectable after mono")
    case Some(bodyExpr) -> {
      match callFnBareName(bodyExpr) {
        case None -> assertTrue(false, "caller's call site must still be a plain single-segment call")
        case Some(calleeName) -> {
          assertEqual(
            calleeName,
            "all",
            "the arity-1 call must survive completely unrewritten (still names 'all', not a '__'-suffixed specialisation) so it binds to the non-generic Validation.all at codegen"
          )
        }
      }
    }
  }
}

// A duplicate REGISTRATION of the exact same decl (e.g. the same generic
// collected via two overlapping collector passes) must not be treated as a
// name collision — only a genuinely DIFFERENT signature under the same name
// counts as ambiguous.
test "identical duplicate cross-package registration is not ambiguous" {
  val callerSrc = "package Caller\n" + "func caller(): Bool { isSomeDup(dup2(5)) }\n"
  val libSrc = "package Lib\n" + "pub func dup2(x: in Int): Int { x }\n" +
    "pub func isSomeDup[T](x: in T): Bool { true }\n"
  val callerPr = parse(callerSrc)
  val libPr = parse(libSrc)
  val feed: List[FunctionDecl] = newList()
  var i = 0
  while i < libPr.file.items.count {
    match libPr.file.items[i].kind {
      case IFunc(decl) -> {
        feed.add(decl)
        // Simulate the same decl entering the pool twice (e.g. overlapping
        // stdlib-package / private-generic collectors).
        if decl.name == "dup2" {
          feed.add(decl)
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  val res = monoFileWithImports(callerPr.file, feed)
  assertTrue(hasFunc(res.file, "isSomeDup__Int"), "duplicate registration of the identical decl is not ambiguity")
}

// #5961: an ambiguity between two IMPORTS must never evict a SAME-PACKAGE
// local function's entry — the local shadows every import ("same-package
// wins"), so it is exactly what the type checker resolves at the call site
// and inference must keep using it.  Before the fix, the eviction removed
// whatever occupied the name, local included, silently degrading a
// perfectly unambiguous local call to the Object fallback.
test "local function survives imported-name ambiguity eviction (#5961)" {
  val callerSrc = "package Caller\n" + "func dup(s: in String): String { s + s }\n" +
    "func caller(): String { mapLike2(\"hi\", { s: String -> dup(s) }) }\n"
  val libSrc = "package Lib\n" + "pub func mapLike2[T, U](x: in T, f: (T) -> U): U { f(x) }\n"
  val libASrc = "package LibA\n" + "pub func dup(s: in String): String { s + s }\n"
  val libBSrc = "package LibB\n" + "pub func dup(c: in Char): Char { c }\n"
  val callerPr = parse(callerSrc)
  val libPr = parse(libSrc)
  val libAPr = parse(libASrc)
  val libBPr = parse(libBSrc)
  val feed: List[FunctionDecl] = newList()
  var i = 0
  while i < libPr.file.items.count {
    match libPr.file.items[i].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    i = i + 1
  }
  var ja = 0
  while ja < libAPr.file.items.count {
    match libAPr.file.items[ja].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    ja = ja + 1
  }
  var jb = 0
  while jb < libBPr.file.items.count {
    match libBPr.file.items[jb].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    jb = jb + 1
  }
  val res = monoFileWithImports(callerPr.file, feed)
  assertTrue(
    hasFunc(res.file, "mapLike2__String__String"),
    "the local dup's String return drives inference; the imports' ambiguity must not evict the local"
  )
  assertFalse(hasFunc(res.file, "mapLike2__String__Object"), "the local call must not degrade to the Object fallback")
}

// #5962: two imported functions sharing a name whose signatures differ ONLY
// in parameter mode are a genuine ambiguity, not a duplicate — the sig key
// folds modes in, so they evict like any other conflicting pair.
test "imported functions differing only in parameter mode are ambiguous (#5962)" {
  val callerSrc = "package Caller\n" + "func caller(): String { mapLike2(\"hi\", { s: String -> dup(s) }) }\n"
  val libSrc = "package Lib\n" + "pub func mapLike2[T, U](x: in T, f: (T) -> U): U { f(x) }\n"
  val libASrc = "package LibA\n" + "pub func dup(s: in String): String { s + s }\n"
  val libBSrc = "package LibB\n" + "pub func dup(s: inout String): String { s }\n"
  val callerPr = parse(callerSrc)
  val libPr = parse(libSrc)
  val libAPr = parse(libASrc)
  val libBPr = parse(libBSrc)
  val feed: List[FunctionDecl] = newList()
  var i = 0
  while i < libPr.file.items.count {
    match libPr.file.items[i].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    i = i + 1
  }
  var ja = 0
  while ja < libAPr.file.items.count {
    match libAPr.file.items[ja].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    ja = ja + 1
  }
  var jb = 0
  while jb < libBPr.file.items.count {
    match libBPr.file.items[jb].kind {
      case IFunc(decl) -> feed.add(decl)
      case _ -> ()
    }
    jb = jb + 1
  }
  val res = monoFileWithImports(callerPr.file, feed)
  assertTrue(
    hasFunc(res.file, "mapLike2__String__Object"),
    "mode-differing same-name imports are ambiguous; U safely defaults to Object"
  )
}

test "lambda-only argument binds type param when no other source exists (#5604)" {
  val callerSrc = "package Caller\n" + "func caller(): Int { eachLike({ z: Int -> () }) }\n"
  val libSrc = "package Lib\n" + "pub func eachLike[T](f: (T) -> Unit): Int { 0 }\n"
  val callerPr = parse(callerSrc)
  val libPr = parse(libSrc)
  val res = monoFileWithImports(callerPr.file, genericsAndUnionCtors(libPr.file))
  assertTrue(hasFunc(res.file, "eachLike__Int"), "eachLike binds T from the lambda's annotated param alone")
}

// #5604: an IMPORTED generic whose type params the arguments cannot pin
// (`isNone(None)` — a nullary case carries no type information) defaults the
// unbound params to Object and specialises, matching the erased uniform-ABI
// meaning.  Generic pub funcs are never emitted to any assembly, so leaving
// the call generic meant codegen silently dropped it.  Local generics keep
// the loud M0002 (covered by the existing M0002 tests).
// #5604: a ctor argument that pins only SOME of the union's type params
// (`isOk(Ok(value = 7))` — T pinned by the field, E unpinned) must
// specialise with the pinned slot concrete and the unpinned slot Object —
// the exact instantiation the argument's `newobj` builds (field-derived
// per-slot, `object` fill).  An all-Object specialisation here mismatched
// the construction and the specialised match's closed isinst never fired.
test "partially-pinned union-ctor argument mixes concrete and Object slots (#5604)" {
  val callerSrc = "package Caller\n" + "func caller(): Bool { isOkLike2(MkOk(v = 7)) }\n"
  val libSrc = "package Lib\n" + "pub union ResLike[T, E] { case MkOk(v: T)\n case MkErr(e: E) }\n" +
    "pub func isOkLike2[T, E](r: in ResLike[T, E]): Bool { match r { case MkOk(x) -> true\n case _ -> false } }\n"
  val callerPr = parse(callerSrc)
  val libPr = parse(libSrc)
  val res = monoFileWithImports(callerPr.file, genericsAndUnionCtors(libPr.file))
  assertTrue(
    hasFunc(res.file, "isOkLike2__Int__Object"),
    "isOkLike2 pins T from the MkOk field and defaults the unpinned E to Object"
  )
}

// #5604: a binding initialised from an imported generic call must track the
// CALL's (defaulted) instantiation, so a later generic call over the binding
// specialises at the instantiation the value actually carries.
test "binding from an imported generic call tracks the defaulted instantiation (#5604)" {
  val callerSrc = "package Caller\n" + "func caller(): Bool { val m = wrapIt(MkOk(v = 5))\n isOkLike2(m) }\n"
  val libSrc = "package Lib\n" + "pub union ResLike[T, E] { case MkOk(v: T)\n case MkErr(e: E) }\n" +
    "pub func wrapIt[T, E](r: in ResLike[T, E]): ResLike[T, E] { r }\n" +
    "pub func isOkLike2[T, E](r: in ResLike[T, E]): Bool { match r { case MkOk(x) -> true\n case _ -> false } }\n"
  val callerPr = parse(callerSrc)
  val libPr = parse(libSrc)
  val res = monoFileWithImports(callerPr.file, genericsAndUnionCtors(libPr.file))
  assertTrue(hasFunc(res.file, "wrapIt__Int__Object"), "wrapIt specialises with T pinned and E defaulted")
  assertTrue(
    hasFunc(res.file, "isOkLike2__Int__Object"),
    "isOkLike2 over the binding reuses the call's defaulted instantiation"
  )
}

test "unconstrained imported generic defaults unbound type params to Object (#5604)" {
  val callerSrc = "package Caller\n" + "func caller(): Bool { isEmptyLike(NoneLike) }\n"
  val libSrc = "package Lib\n" + "pub union OptLike[T] { case SomeLike(v: T)\n case NoneLike }\n" +
    "pub func isEmptyLike[T](o: in OptLike[T]): Bool { match o { case NoneLike -> true\n case _ -> false } }\n"
  val callerPr = parse(callerSrc)
  val libPr = parse(libSrc)
  val res = monoFileWithImports(callerPr.file, genericsAndUnionCtors(libPr.file))
  assertTrue(
    hasFunc(res.file, "isEmptyLike__Object"),
    "isEmptyLike defaults its unbound T to Object instead of staying generic"
  )
}

// #3705: a generic union predicate (`isErrLike`, the shape of stdlib
// `isOk`/`isErr`) is specialised over the *concrete* Result type only
// when the monomorphizer can infer the argument's type — which, for a
// cross-package call `isErrLike(makeRes())`, requires the non-generic
// callee `makeRes`'s declared return type.  Feeding the non-generic decl
// (as `collectInBundleNonGenericFuncs` now does in the MSIL bridge) is what
// turns the call into `isErrLike__Int__String`; without it the call would
// hit the type-erased generic, whose `isinst Result_Err<object,object>`
// never matches the concrete value at runtime ("Unable to cast Result_Err
// to Boolean").
test "non-generic callee return feeds cross-package union-predicate specialisation (#3705)" {
  val callerSrc = "package Caller\n" + "func caller(): Bool { isErrLike(makeRes()) }\n"
  val genericSrc = "package Lib\n" +
    "pub func isErrLike[T, E](r: in Result[T, E]): Bool { match r { case Ok(v) -> false\n case Err(c) -> true } }\n"
  val nonGenericSrc = "package Lib\n" + "pub func makeRes(): Result[Int, String] { Ok(1) }\n"

  val genericPr = parse(genericSrc)
  val nonGenericPr = parse(nonGenericSrc)

  // The generic predicate alone (mirrors the pre-fix feed).
  val genOnly: List[FunctionDecl] = newList()
  var gi = 0
  while gi < genericPr.file.items.count {
    match genericPr.file.items[gi].kind {
      case IFunc(decl) -> match decl.generics { case Some(_) -> genOnly.add(decl); case None -> () }
      case _ -> ()
    }
    gi = gi + 1
  }

  // Without the non-generic callee, the argument type can't be inferred, so
  // no CONCRETE specialisation is produced (the unbound params default to
  // Object — see the #5604 defaulting test below).
  val resNoFeed = monoFileWithImports(parse(callerSrc).file, genOnly)
  assertTrue(
    not hasFunc(resNoFeed.file, "isErrLike__Int__String"),
    "without makeRes fed, isErrLike is not specialised (call hits the erased generic)"
  )

  // With the non-generic callee fed alongside the generic, mono infers
  // makeRes(): Result[Int, String], unifies T=Int / E=String, and emits the
  // concrete specialisation.
  val withFeed: List[FunctionDecl] = newList()
  var wgi = 0
  while wgi < genOnly.count {
    withFeed.add(genOnly[wgi])
    wgi = wgi + 1
  }
  var ni = 0
  while ni < nonGenericPr.file.items.count {
    match nonGenericPr.file.items[ni].kind {
      case IFunc(decl) -> match decl.generics { case Some(_) -> (); case None -> withFeed.add(decl) }
      case _ -> ()
    }
    ni = ni + 1
  }

  val resFeed = monoFileWithImports(parse(callerSrc).file, withFeed)
  assertTrue(
    hasFunc(resFeed.file, "isErrLike__Int__String"),
    "with makeRes fed, isErrLike__Int__String specialisation is appended"
  )
}

// #3813: a generic union predicate over the result of an *interface-method*
// call (`isOkLike(b.probe())` where `b: Widget`) specialises over the
// concrete method return type only when the monomorphizer can see the
// interface decl — fed via `monoFileWithImportsAndIfaces`.  Mirrors the
// lyric-storage `isOk(bucket.exists(...))` shape that motivated #3813.
test "interface-method return feeds union-predicate specialisation (#3813)" {
  val callerSrc = "package Caller\n" + "func caller(b: in Widget): Bool { isOkLike(b.probe()) }\n"
  val genericSrc = "package Lib\n" +
    "pub func isOkLike[T, E](r: in Result[T, E]): Bool { match r { case Ok(v) -> true\n case Err(c) -> false } }\n"
  val ifaceSrc = "package Lib\n" + "pub interface Widget { func probe(): Result[Bool, String] }\n"

  val genericPr = parse(genericSrc)
  val ifacePr = parse(ifaceSrc)

  val genFeed: List[FunctionDecl] = newList()
  var gi = 0
  while gi < genericPr.file.items.count {
    match genericPr.file.items[gi].kind {
      case IFunc(decl) -> match decl.generics { case Some(_) -> genFeed.add(decl); case None -> () }
      case _ -> ()
    }
    gi = gi + 1
  }

  val ifaceFeed: List[InterfaceDecl] = newList()
  var ii = 0
  while ii < ifacePr.file.items.count {
    match ifacePr.file.items[ii].kind {
      case IInterface(decl) -> ifaceFeed.add(decl)
      case _ -> ()
    }
    ii = ii + 1
  }

  // Without the interface decl, `b.probe()`'s return type is unknown, so no
  // concrete specialisation is produced (unbound params default to Object).
  val emptyIfaces: List[InterfaceDecl] = newList()
  val resNoIface = monoFileWithImportsAndIfaces(parse(callerSrc).file, genFeed, emptyIfaces)
  assertTrue(
    not hasFunc(resNoIface.file, "isOkLike__Bool__String"),
    "without the Widget interface fed, isOkLike is not specialised"
  )

  // With the interface decl fed, mono infers b.probe(): Result[Bool, String]
  // and specialises the predicate.
  val resIface = monoFileWithImportsAndIfaces(parse(callerSrc).file, genFeed, ifaceFeed)
  assertTrue(
    hasFunc(resIface.file, "isOkLike__Bool__String"),
    "with the Widget interface fed, isOkLike__Bool__String specialisation is appended"
  )
}

// #3813 follow-up: a generic predicate over a *field projection* on an
// imported record (`isSomeLike(p.tok)` where `p: Page` and `tok:
// Option[String]`) specialises only when the cross-package record decl is fed
// via `monoFileWithImportsAndTypeDecls`.  Mirrors the lyric-storage
// `isSome(page.nextContinuationToken)` shape.
test "imported record field feeds union-predicate specialisation (#3813)" {
  val callerSrc = "package Caller\n" + "func caller(p: in Page): Bool { isSomeLike(p.tok) }\n"
  val genericSrc = "package Lib\n" +
    "pub func isSomeLike[T](o: in Option[T]): Bool { match o { case Some(v) -> true\n case None -> false } }\n"
  val recordSrc = "package Lib\n" + "pub record Page { tok: Option[String]\n truncated: Bool }\n"

  val genericPr = parse(genericSrc)
  val recordPr = parse(recordSrc)

  val genFeed: List[FunctionDecl] = newList()
  var gi = 0
  while gi < genericPr.file.items.count {
    match genericPr.file.items[gi].kind {
      case IFunc(decl) -> match decl.generics { case Some(_) -> genFeed.add(decl); case None -> () }
      case _ -> ()
    }
    gi = gi + 1
  }

  val recFeed: List[RecordDecl] = newList()
  var ri = 0
  while ri < recordPr.file.items.count {
    match recordPr.file.items[ri].kind {
      case IRecord(decl) -> recFeed.add(decl)
      case _ -> ()
    }
    ri = ri + 1
  }

  val emptyIfaces: List[InterfaceDecl] = newList()
  val emptyRecs: List[RecordDecl] = newList()

  // Without the record decl, `p.tok`'s type is unknown, so no concrete
  // specialisation is produced (unbound params default to Object).
  val resNoRec = monoFileWithImportsAndTypeDecls(parse(callerSrc).file, genFeed, emptyIfaces, emptyRecs)
  assertTrue(
    not hasFunc(resNoRec.file, "isSomeLike__String"),
    "without the Page record fed, isSomeLike is not specialised"
  )

  // With the record decl fed, mono infers p.tok: Option[String] and
  // specialises the predicate.
  val resRec = monoFileWithImportsAndTypeDecls(parse(callerSrc).file, genFeed, emptyIfaces, recFeed)
  assertTrue(
    hasFunc(resRec.file, "isSomeLike__String"),
    "with the Page record fed, isSomeLike__String specialisation is appended"
  )
}

// Identity behaviour when no generics are present: monoFile returns
// the file unchanged with an empty rewrites map.
test "no generics no op" {
  val src = "package P\n" + "func main(): Int { 0 }\n"
  val res = runMono(src)
  assertEqualInt(res.file.items.count, 1, "single non-generic item preserved")
  assertEqualInt(res.rewrites.count, 0, "no rewrites recorded")
  assertEqualInt(res.diagnostics.count, 0, "no diagnostics")
}

// Imports list passes through unchanged after monomorphisation.
test "imports preserved" {
  val src = "package P\n" + "import Std.Core\n" + "func id[T](x: in T): T { x }\n" + "func caller(): Int { id(1) }\n"
  val res = runMono(src)
  assertEqualInt(res.file.imports.count, 1, "import declarations preserved in mono output")
}

// ─────────────────────────────────────────────────────────────────────────────
// #349 inference improvements
// ─────────────────────────────────────────────────────────────────────────────
// Outer generic call's type arg comes from an inner generic call's
// return type — pre-#349 the inferer returned None for `id(7)` because
// `inferExprTE` didn't see ECall.  Post-#349 it reads
// `state.funcDecls`, finds id is generic with return T, infers T=Int
// from the literal 7, and specialises wrap to wrap__Int.
test "nested generic return inferred" {
  val src = "package P\n" + "func id[T](x: in T): T { x }\n" + "func wrap[T](y: in T): T { y }\n" +
    "func caller(): Int { wrap(id(7)) }\n"
  val res = runMono(src)
  assertTrue(hasFunc(res.file, "id__Int"), "#349 nested: id__Int specialisation present (inner)")
  assertTrue(hasFunc(res.file, "wrap__Int"), "#349 nested: wrap__Int specialisation present (outer)")
}

// Record field projection `b.value` should be inferred to the field's
// declared type via `state.recordDecls`, threading b's record type
// through the env from the un-annotated `val b = Box(...)`.
test "field projection inferred" {
  val src = "package P\n" + "record Box { value: Int }\n" + "func consume[T](x: in T): T { x }\n" +
    "func caller(): Int { val b = Box(value = 11); consume(b.value) }\n"
  val res = runMono(src)
  assertTrue(hasFunc(res.file, "consume__Int"), "#349 field: consume__Int specialisation (b.value inferred as Int)")
}

// Non-generic same-package callee return chains into the inferer.
// `origin(): Int` is non-generic, so the inferer skips unification
// and returns the declared return type directly — that feeds into
// consume's inference.
test "non generic return feeds inference" {
  val src = "package P\n" + "func consume[T](x: in T): T { x }\n" + "func origin(): Int { 0 }\n" +
    "func caller(): Int { consume(origin()) }\n"
  val res = runMono(src)
  assertTrue(hasFunc(res.file, "consume__Int"), "#349 non-generic-return: consume__Int via origin(): Int")
}

// ── Multi-segment qualified generic call (#2943) ──────────────────────────────
// PR #2936 added handling for `Pkg.func(arg)` where `func[T]` is a generic
// imported from `Pkg`.  Before the fix, only single-segment `func(arg)` call
// sites were picked up by the monomorphiser's genDecls lookup; multi-segment
// paths landed in the `else` branch and were never specialised.
//
// The test mirrors the `lyric-validation` integration repro:
//   `Validation.toResult(42, errors)` where `toResult[T]` is a generic from
//   package `Validation`.  The alias rewriter converts the qualified call to
//   `EPath(["Validation", "toResult"])` so the last-segment lookup in
//   `rewriteExpr` applies.
test "multi-segment qualified generic call is specialised (#2943)" {
  // Caller uses `Validation.toResult(42)` — a multi-segment qualified call
  // to an imported generic.  The alias rewriter must run first (it converts
  // the single-segment `import Validation` to the `Validation=Validation`
  // entry that rewrites `EMember(EPath(["Validation"]), "toResult")` →
  // `EPath(["Validation", "toResult"])`); then the monomorphiser looks up
  // the last segment `"toResult"` in genDecls and specialises it to
  // `toResult__Int`.
  val callerSrc = "package App\nimport Validation\nfunc caller(): Int { Validation.toResult(42) }\n"
  val importedSrc = "package Validation\npub func toResult[T](x: in T): T { x }\n"

  val callerPr = parse(callerSrc)
  val importedPr = parse(importedSrc)

  // Alias-rewrite the caller so `Validation.toResult(42)` becomes
  // `EPath(["Validation", "toResult"])(42)` — without this step the mono
  // pass sees EMember and does not reach the multi-segment `else` branch.
  val callerRewritten = rewriteFile(callerPr.file)

  val importedGen: List[FunctionDecl] = newList()
  var i = 0
  while i < importedPr.file.items.count {
    match importedPr.file.items[i].kind {
      case IFunc(decl) -> {
        match decl.generics {
          case Some(_) -> importedGen.add(decl)
          case None -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }

  val res = monoFileWithImports(callerRewritten, importedGen)
  assertTrue(hasFunc(res.file, "toResult__Int"), "#2943 multi-segment qualified: toResult__Int specialisation appended")
}

// ── Multi-segment qualified call must not be hijacked by a same-named generic
//    with fewer parameters (#3627) ────────────────────────────────────────────
// `Helper.assertEq("x", "y", "z")` passes three arguments, but the only
// `assertEq` reachable in genDecls is a one-parameter generic `assertEq[T](x)`
// (this mirrors the real collision between a package's non-generic
// `assertEq(a, b, msg): Unit` and `Std.Core.Proof.assertEq[T](x): T`).  Because
// genDecls is keyed by the bare last segment, the monomorphiser used to match
// the generic by name and rewrite the call into `assertEq__String`, stranding
// the two extra arguments on the stack -> InvalidProgramException at runtime.
// A genuine call to the generic can never supply more args than it has params,
// so the call must be left untouched for normal (non-generic) resolution.
test "multi-segment qualified call is not hijacked by a fewer-param same-named generic (#3627)" {
  val callerSrc = "package App\nimport Helper\nfunc caller(): Unit { Helper.assertEq(\"x\", \"y\", \"z\") }\n"
  val importedSrc = "package Helper\npub func assertEq[T](x: in T): T { x }\n"

  val callerPr = parse(callerSrc)
  val importedPr = parse(importedSrc)
  val callerRewritten = rewriteFile(callerPr.file)

  val importedGen: List[FunctionDecl] = newList()
  var i = 0
  while i < importedPr.file.items.count {
    match importedPr.file.items[i].kind {
      case IFunc(decl) -> {
        match decl.generics {
          case Some(_) -> importedGen.add(decl)
          case None -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }

  val res = monoFileWithImports(callerRewritten, importedGen)
  assertTrue(
    not hasFunc(res.file, "assertEq__String"),
    "#3627: a 3-arg qualified call must not be specialised against a 1-param generic"
  )
}

// Single-segment (unqualified) sibling of #3627 (#3677): the same arity guard
// applies to the unqualified-call branch of `rewriteExpr`.  An unqualified
// `assertEq("x","y","z")` (three args) must not be specialised against a
// same-file one-param generic `assertEq[T](x)` — leave it for normal resolution
// rather than emitting a broken `assertEq__String`.
test "unqualified call is not hijacked by a fewer-param same-named generic (#3677)" {
  val src = "package P\n" + "func assertEq[T](x: in T): T { x }\n" +
    "func caller(): Unit { assertEq(\"x\", \"y\", \"z\") }\n"
  val res = runMono(src)
  assertTrue(
    not hasFunc(res.file, "assertEq__String"),
    "#3677: a 3-arg unqualified call must not be specialised against a 1-param generic"
  )
}

// Mixed positional inference — one type-param inferred via nested
// generic call, the other via literal.
test "mixed inference shapes" {
  val src = "package P\n" + "func wrap[T](x: in T): T { x }\n" + "func pair[A, B](a: in A, b: in B): A { a }\n" +
    "func caller(): Int { pair(wrap(3), 9) }\n"
  val res = runMono(src)
  assertTrue(
    hasFunc(res.file, "pair__Int__Int"),
    "#349 mixed: pair__Int__Int specialisation (A from wrap(3), B from 9)"
  )
  assertTrue(hasFunc(res.file, "wrap__Int"), "#349 mixed: wrap__Int (nested) specialisation")
}

// ─────────────────────────────────────────────────────────────────────────────
// Constraint validation (docs/59 §5.2 B3) and unspecialisable-call / budget
// diagnostics (B2, B5).
// ─────────────────────────────────────────────────────────────────────────────
func diagCountCode(diags: in List[Diagnostic], code: in String): Int {
  var n = 0
  var i = 0
  while i < diags.count {
    if diags[i].code == code {
      n = n + 1
    }
    i = i + 1
  }
  n
}

// B3: a primitive that lacks the bound's marker must raise M0001 — before
// the fix `satisfiesMarker` returned true on every branch, so this
// diagnostic was unreachable.
test "where bound violated by primitive raises M0001" {
  val src = "package P\n" + "func subAll[T](a: in T, b: in T): T where T: Sub { a }\n" +
    "func caller(): String { subAll(\"x\", \"y\") }\n"
  val res = runMono(src)
  assertEqualInt(diagCountCode(res.diagnostics, "M0001"), 1, "String does not satisfy 'where T: Sub' — M0001 fires")
}

// B3: a primitive that carries the marker specialises without diagnostics.
// `Add` on Int (arithmetic) and on String (concatenation) both hold.
test "where bound satisfied by primitive proceeds" {
  val src = "package P\n" + "func addAll[T](a: in T, b: in T): T where T: Add { a }\n" +
    "func callerI(): Int { addAll(1, 2) }\n" +
    "func callerS(): String { addAll(\"x\", \"y\") }\n"
  val res = runMono(src)
  assertTrue(hasFunc(res.file, "addAll__Int"), "Int satisfies Add — specialisation emitted")
  assertTrue(hasFunc(res.file, "addAll__String"), "String satisfies Add (concatenation) — specialisation emitted")
  assertEqualInt(diagCountCode(res.diagnostics, "M0001"), 0, "no M0001 for satisfied bounds")
}

// B3: non-primitive type arguments accept silently — mono cannot see
// `@derive(...)` lists pre-resolution; the type checker's T0108 owns them.
test "where bound on user type accepts silently" {
  val src = "package P\n" + "record Plain { value: Int }\n" + "func subAll[T](a: in T, b: in T): T where T: Sub { a }\n" +
    "func caller(p: in Plain, q: in Plain): Plain { subAll(p, q) }\n"
  val res = runMono(src)
  assertEqualInt(diagCountCode(res.diagnostics, "M0001"), 0, "user types pass silently (T0108 owns derive lists)")
  assertTrue(hasFunc(res.file, "subAll__Plain"), "specialisation still proceeds for user types")
}

// B2: a call to a same-package generic whose type arguments cannot be
// inferred must raise M0002 — the generic decl is erased from the output,
// so the surviving call site would be a dangling reference at codegen
// (previously a silent runtime crash).
test "uninferable call to dropped same-package generic raises M0002" {
  val src = "package P\n" + "func pick[T](): Int { 0 }\n" + "func caller(): Int { pick() }\n"
  val res = runMono(src)
  assertEqualInt(diagCountCode(res.diagnostics, "M0002"), 1, "zero-arg call cannot infer T — M0002 fires")
}

// B2: an UNANNOTATED lambda argument cannot drive inference (no param
// types to unify, no env to type the body), so a same-package generic call
// whose only evidence is such a lambda must raise M0002 instead of
// dangling.  Annotated lambdas DO drive inference — see the #5604 tests.
test "lambda-arg call to dropped same-package generic raises M0002" {
  val src = "package P\n" + "func applyIt[T](f: in (T) -> T): Int { 0 }\n" +
    "func caller(): Int { applyIt({ x -> x }) }\n"
  val res = runMono(src)
  assertEqualInt(diagCountCode(res.diagnostics, "M0002"), 1, "lambda arg cannot drive inference — M0002 fires")
}

// B2 negative: the same uninferable shape against an IMPORTED generic must
// stay silent — its unbound type params default to Object and the call
// specialises (#5604); nothing dangles, so no diagnostic.
test "uninferable call to imported generic stays silent" {
  val callerSrc = "package Caller\n" + "func caller(): Int { pickImported() }\n"
  val importedSrc = "package Lib\n" + "pub func pickImported[T](): Int { 0 }\n"
  val importedPr = parse(importedSrc)
  val importedGen: List[FunctionDecl] = newList()
  var i = 0
  while i < importedPr.file.items.count {
    match importedPr.file.items[i].kind {
      case IFunc(decl) -> match decl.generics { case Some(_) -> importedGen.add(decl); case None -> () }
      case _ -> ()
    }
    i = i + 1
  }
  val res = monoFileWithImports(parse(callerSrc).file, importedGen)
  assertEqualInt(diagCountCode(res.diagnostics, "M0002"), 0, "imported generics keep the erased fallback — no M0002")
}

// B2 negative: the #3677 arity-overflow shape (call has MORE args than the
// same-named generic has params) targets an unrelated function and must not
// raise M0002 either.
test "arity-overflow call to same-named generic stays silent (#3677)" {
  val src = "package P\n" + "func assertEq[T](x: in T): T { x }\n" +
    "func caller(): Unit { assertEq(\"x\", \"y\", \"z\") }\n"
  val res = runMono(src)
  assertEqualInt(diagCountCode(res.diagnostics, "M0002"), 0, "#3677 shape resolves elsewhere — no M0002")
}

// B5: unbounded recursive instantiation must terminate with M0003 instead
// of the former compiler panic.  `deepen[A,B,C]` re-instantiates itself
// with a strictly larger type in one slot per call, so the worklist grows
// without bound until the 10k budget trips.
test "specialisation budget exhaustion raises M0003 instead of panicking" {
  val src = "package P\n" + "func wrap[T](x: in T): List[T] { wrap(x) }\n" +
    "func deepen[A, B, C](a: in A, b: in B, c: in C): Int { deepen(wrap(a), b, c) + deepen(a, wrap(b), c) + deepen(a, b, wrap(c)) }\n" +
    "func caller(): Int { deepen(1, 2, 3) }\n"
  val res = runMono(src)
  assertEqualInt(diagCountCode(res.diagnostics, "M0003"), 1, "budget exhaustion surfaces as a single M0003 diagnostic")
}

// #5754: a local variable literally named `result` (legal outside a
// contract clause since the #5735 parser fix — see parser_self_test.l)
// must still flow through call-site inference and specialise like any
// other identifier reference, not silently resolve as the reserved
// `EResult` contract keyword.
test "local named result specialises correctly through a generic call (#5754)" {
  val src = "package P\n" + "func id[T](x: in T): T { x }\n" +
    "func caller(): Int {\n  val result: Int = 7\n  id(result)\n}\n"
  val res = runMono(src)
  assertTrue(hasFunc(res.file, "id__Int"), "id__Int specialisation emitted for a local named result")
  assertTrue(not hasFunc(res.file, "id"), "generic id removed from output")
  assertEqualInt(res.diagnostics.count, 0, "no mono diagnostics")
}
