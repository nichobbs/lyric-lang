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
  // the predicate stays erased — no concrete specialisation is produced.
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

  // Without the interface decl, `b.probe()`'s return type is unknown, so the
  // predicate stays erased.
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

  // Without the record decl, `p.tok`'s type is unknown, so the predicate stays
  // erased.
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
