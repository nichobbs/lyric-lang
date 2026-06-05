//! mono_self_test.l — exercises the self-hosted Lyric.Mono library.
//! Compiled and executed by SelfHostedMonoTests.fs.  Exit 0 + "ok" in
//! stdout means every check held.
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
package Lyric.MonoSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
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
  Expr(kind = ELiteral(lit = LInt(value = value, suffix = NoIntSuffix)), span = syntheticSpan())
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
func testTypeGenericInferred(): Unit {
  val src = "package P\n" + "func id[T](x: in T): T { x }\n" + "func caller(): Int { id(7) }\n"
  val res = runMono(src)
  assertTrue(hasFunc(res.file, "id__Int"), "id__Int specialisation emitted")
  assertTrue(not hasFunc(res.file, "id"), "generic id removed from output")
  assertEqualInt(res.diagnostics.count, 0, "no mono diagnostics")
}

// Explicit ETypeApp from a synthetic AST — exercises the
// non-inference path through `rewriteExpr`.
func testTypeGenericExplicitTypeApp(): Unit {
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
func testValueGenericExplicit(): Unit {
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
func testValueGenericDistinctSpecs(): Unit {
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
func testValueGenericBodySubstituted(): Unit {
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
func testMixedTypeAndValueGenerics(): Unit {
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
func testConstraintPrimitiveAccepted(): Unit {
  val src = "package P\n" + "func eqCheck[T](a: in T, b: in T): Bool where T: Equals { true }\n" +
    "func caller(): Bool { eqCheck(1, 2) }\n"
  val res = runMono(src)
  assertTrue(hasFunc(res.file, "eqCheck__Int"), "eqCheck__Int specialisation emitted")
  assertEqualInt(res.diagnostics.count, 0, "primitive Int satisfies Equals marker — no diagnostics")
}

// Worklist termination + nested generic call site.
func testNestedGenericCallChain(): Unit {
  val src = "package P\n" + "func id[T](x: in T): T { x }\n" + "func twice[T](x: in T): T { id(x) }\n" +
    "func caller(): Int { twice(42) }\n"
  val res = runMono(src)
  assertTrue(hasFunc(res.file, "twice__Int"), "twice__Int emitted")
  assertTrue(hasFunc(res.file, "id__Int"), "nested id call inside twice__Int specialises to id__Int")
}

// Cross-package surface: `monoFileWithImports` with an imported generic
// FunctionDecl specialises it in the caller's file just like a
// same-package generic.
func testCrossPackageImportedGeneric(): Unit {
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

// Identity behaviour when no generics are present: monoFile returns
// the file unchanged with an empty rewrites map.
func testNoGenericsNoOp(): Unit {
  val src = "package P\n" + "func main(): Int { 0 }\n"
  val res = runMono(src)
  assertEqualInt(res.file.items.count, 1, "single non-generic item preserved")
  assertEqualInt(res.rewrites.count, 0, "no rewrites recorded")
  assertEqualInt(res.diagnostics.count, 0, "no diagnostics")
}

// Imports list passes through unchanged after monomorphisation.
func testImportsPreserved(): Unit {
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
func testNestedGenericReturnInferred(): Unit {
  val src = "package P\n" + "func id[T](x: in T): T { x }\n" + "func wrap[T](y: in T): T { y }\n" +
    "func caller(): Int { wrap(id(7)) }\n"
  val res = runMono(src)
  assertTrue(hasFunc(res.file, "id__Int"), "#349 nested: id__Int specialisation present (inner)")
  assertTrue(hasFunc(res.file, "wrap__Int"), "#349 nested: wrap__Int specialisation present (outer)")
}

// Record field projection `b.value` should be inferred to the field's
// declared type via `state.recordDecls`, threading b's record type
// through the env from the un-annotated `val b = Box(...)`.
func testFieldProjectionInferred(): Unit {
  val src = "package P\n" + "record Box { value: Int }\n" + "func consume[T](x: in T): T { x }\n" +
    "func caller(): Int { val b = Box(value = 11); consume(b.value) }\n"
  val res = runMono(src)
  assertTrue(hasFunc(res.file, "consume__Int"), "#349 field: consume__Int specialisation (b.value inferred as Int)")
}

// Non-generic same-package callee return chains into the inferer.
// `origin(): Int` is non-generic, so the inferer skips unification
// and returns the declared return type directly — that feeds into
// consume's inference.
func testNonGenericReturnFeedsInference(): Unit {
  val src = "package P\n" + "func consume[T](x: in T): T { x }\n" + "func origin(): Int { 0 }\n" +
    "func caller(): Int { consume(origin()) }\n"
  val res = runMono(src)
  assertTrue(hasFunc(res.file, "consume__Int"), "#349 non-generic-return: consume__Int via origin(): Int")
}

// Mixed positional inference — one type-param inferred via nested
// generic call, the other via literal.
func testMixedInferenceShapes(): Unit {
  val src = "package P\n" + "func wrap[T](x: in T): T { x }\n" + "func pair[A, B](a: in A, b: in B): A { a }\n" +
    "func caller(): Int { pair(wrap(3), 9) }\n"
  val res = runMono(src)
  assertTrue(
    hasFunc(res.file, "pair__Int__Int"),
    "#349 mixed: pair__Int__Int specialisation (A from wrap(3), B from 9)"
  )
  assertTrue(hasFunc(res.file, "wrap__Int"), "#349 mixed: wrap__Int (nested) specialisation")
}

func main(): Unit {
  testTypeGenericInferred()
  testTypeGenericExplicitTypeApp()
  testValueGenericExplicit()
  testValueGenericDistinctSpecs()
  testValueGenericBodySubstituted()
  testMixedTypeAndValueGenerics()
  testConstraintPrimitiveAccepted()
  testNestedGenericCallChain()
  testCrossPackageImportedGeneric()
  testNoGenericsNoOp()
  testImportsPreserved()
  testNestedGenericReturnInferred()
  testFieldProjectionInferred()
  testNonGenericReturnFeedsInference()
  testMixedInferenceShapes()
  println("mono self-test: ok")
}
