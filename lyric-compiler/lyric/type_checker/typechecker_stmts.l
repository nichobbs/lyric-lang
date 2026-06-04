// typechecker_stmts.l — statement and function-body type checking.
// Mirrors compiler/src/Lyric.TypeChecker/StmtChecker.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Pattern binding.
// ─────────────────────────────────────────────────────────────────────────────

func bindPattern(
  sc:  in Scope,
  pat: in Pattern,
  ty:  in Type
): Unit {
  match pat.kind {
    case PBinding(name, innerOpt) -> {
      if name != "_" {
        scopeAdd(sc, LocalBinding(name = name, ty = ty, isMutable = false))
      }
      match innerOpt {
        case None         -> {}
        case Some(inner)  -> bindPattern(sc, inner, ty)
      }
    }
    case PWildcard -> {}
    case PTuple(patterns) -> {
      var i = 0
      while i < patterns.count {
        bindPattern(sc, patterns[i], TyError)
        i = i + 1
      }
    }
    case PConstructor(_, args) -> {
      var i = 0
      while i < args.count {
        bindPattern(sc, args[i], TyError)
        i = i + 1
      }
    }
    case POr(patterns) -> {
      if patterns.count > 0 {
        bindPattern(sc, patterns[0], ty)
      }
    }
    case _ -> {}
  }
}

// When a binding is declared with an inline refined type (`Int range lo .. hi`)
// and initialised with an integer literal, reject a literal that falls outside
// the statically-known bounds (T0015).  This is the inline-refined-type
// construction check; validating constructions of *named* distinct range
// subtypes (`type Age = Int range …`) is Band-4 work and is not covered here.
func checkRefinedLiteralBound(
  declT: in Type,
  init:  in Expr,
  diag:  in List[Diagnostic]
): Unit {
  match declT {
    case TyRefined(_, lo, hi, inc) ->
      match exprLiteralLong(init) {
        case None -> {}
        case Some(v) -> {
          val belowLo = match lo { case None -> false; case Some(l) -> v < l }
          val aboveHi =
            match hi {
              case None    -> false
              case Some(h) -> if inc { v > h } else { v >= h }
            }
          if belowLo or aboveHi {
            diag.add(errorDiagnostic("T0015",
              "literal " + toString(v) + " is out of range for type " +
              renderType(declT), init.span))
          }
        }
      }
    case _ -> {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Statement checking.
// ─────────────────────────────────────────────────────────────────────────────

pub func checkStatement(
  sc:           in Scope,
  tbl:          in SymbolTable,
  sigs:         in Map[String, ResolvedSignature],
  genericNames: in List[String],
  returnTy:     in Type,
  diag:         in List[Diagnostic],
  stmt:         in Statement
): Unit {
  match stmt.kind {
    case SLocal(binding) ->
      match binding {
        case LBVal(pat, tyOpt, init) -> {
          val initType = inferExpr(sc, tbl, sigs, diag, init)
          val bindType =
            match tyOpt {
              case None     -> initType
              case Some(te) -> {
                val ctx = newGenericContext()
                gctxPush(ctx, genericNames)
                val declT = resolveType(tbl, ctx, diag, te)
                if not typeEquiv(declT, initType) {
                  diag.add(errorDiagnostic("T0060",
                    "val binding declared as " + renderType(declT) +
                    " but initialiser has type " + renderType(initType), stmt.span))
                }
                checkRefinedLiteralBound(declT, init, diag)
                declT
              }
            }
          bindPattern(sc, pat, bindType)
        }

        case LBVar(name, tyOpt, initOpt) -> {
          val initType =
            match initOpt {
              case None    -> TyError
              case Some(e) -> inferExpr(sc, tbl, sigs, diag, e)
            }
          val bindType =
            match tyOpt {
              case None     -> initType
              case Some(te) -> {
                val ctx = newGenericContext()
                gctxPush(ctx, genericNames)
                val declT = resolveType(tbl, ctx, diag, te)
                match initOpt {
                  case Some(initE) -> {
                    if not typeEquiv(declT, initType) {
                      diag.add(errorDiagnostic("T0061",
                        "var binding declared as " + renderType(declT) +
                        " but initialiser has type " + renderType(initType), stmt.span))
                    }
                    checkRefinedLiteralBound(declT, initE, diag)
                  }
                  case None -> {}
                }
                declT
              }
            }
          scopeAdd(sc, LocalBinding(name = name, ty = bindType, isMutable = true))
        }

        case LBLet(name, tyOpt, init) -> {
          val initType = inferExpr(sc, tbl, sigs, diag, init)
          val bindType =
            match tyOpt {
              case None     -> initType
              case Some(te) -> {
                val ctx = newGenericContext()
                gctxPush(ctx, genericNames)
                val declT = resolveType(tbl, ctx, diag, te)
                if not typeEquiv(declT, initType) {
                  diag.add(errorDiagnostic("T0062",
                    "let binding declared as " + renderType(declT) +
                    " but initialiser has type " + renderType(initType), stmt.span))
                }
                checkRefinedLiteralBound(declT, init, diag)
                declT
              }
            }
          scopeAdd(sc, LocalBinding(name = name, ty = bindType, isMutable = false))
        }
      }

    case SAssign(target, _, value) -> {
      val targetType = inferExpr(sc, tbl, sigs, diag, target)
      val valueType  = inferExpr(sc, tbl, sigs, diag, value)
      if not typeEquiv(targetType, valueType) {
        diag.add(errorDiagnostic("T0063",
          "assigned value of type " + renderType(valueType) +
          " does not match target of type " + renderType(targetType), stmt.span))
      }
      // #1487 (§5.2): an `in` parameter — like a `val`/`let` binding — is
      // immutable and cannot be reassigned.  The checker records this as
      // `isMutable = false` (in-params and val/let), so a simple-path
      // assignment whose target is an immutable binding is rejected (T0087).
      // `var` locals and `out`/`inout` params are mutable and unaffected.
      match target.kind {
        case EPath(p) ->
          if p.segments.count == 1 {
            match scopeTryFind(sc, p.segments[0]) {
              case Some(b) ->
                if not b.isMutable {
                  diag.add(errorDiagnostic("T0087",
                    "cannot reassign immutable binding '" + p.segments[0] +
                    "' (a `val`/`let` or an `in` parameter)", stmt.span))
                }
              case None -> {}
            }
          }
        case _ -> {}
      }
    }

    case SReturn(valueOpt) ->
      match valueOpt {
        case None -> {
          if not typeEquiv(returnTy, TyPrim(pt = PtUnit)) {
            diag.add(errorDiagnostic("T0064",
              "return without value but enclosing function returns " +
              renderType(returnTy), stmt.span))
          }
        }
        case Some(e) -> {
          val t = inferExpr(sc, tbl, sigs, diag, e)
          val isNever = match t { case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }; case _ -> false }
          if not isNever and not typeEquiv(t, returnTy) {
            diag.add(errorDiagnostic("T0065",
              "returned value of type " + renderType(t) +
              " does not match declared return type " + renderType(returnTy), stmt.span))
          }
        }
      }

    case SThrow(e) -> {
      val _ = inferExpr(sc, tbl, sigs, diag, e)
    }

    case SBreak(_)    -> {}
    case SContinue(_) -> {}

    case SInvariant(e) -> {
      val _ = inferExpr(sc, tbl, sigs, diag, e)
    }

    case SExpr(e) -> {
      match e.kind {
        case EYield(inner) -> {
          // T0095: yield value must match the generator's declared element type.
          val innerTy = inferExpr(sc, tbl, sigs, diag, inner)
          val isNever = match innerTy { case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }; case _ -> false }
          val isErr   = match innerTy { case TyError -> true; case _ -> false }
          if not isNever and not isErr and not typeEquiv(innerTy, returnTy) {
            diag.add(errorDiagnostic("T0095",
              "yield value has type " + renderType(innerTy) +
              " but the generator's declared element type is " + renderType(returnTy),
              e.span))
          }
        }
        case _ -> { val _ = inferExpr(sc, tbl, sigs, diag, e) }
      }
    }

    case SDefer(body) -> {
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, diag, body)
    }

    case SScope(_, body) -> {
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, diag, body)
    }

    case SLoop(_, body) -> {
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, diag, body)
    }

    case SFor(_, pat, iter, body) -> {
      val iterType = inferExpr(sc, tbl, sigs, diag, iter)
      val elemType =
        match iterType {
          case TySlice(e)    -> e
          case TyArray(_, e) -> e
          case _             -> TyError
        }
      scopePush(sc)
      bindPattern(sc, pat, elemType)
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, diag, body)
      scopePop(sc)
    }

    case SWhile(_, cond, body) -> {
      val condT = inferExpr(sc, tbl, sigs, diag, cond)
      if not typeEquiv(condT, TyPrim(pt = PtBool)) {
        diag.add(errorDiagnostic("T0066",
          "while-condition must be Bool (got " + renderType(condT) + ")", stmt.span))
      }
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, diag, body)
    }

    case STry(body, catches, finally_) -> {
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, diag, body)
      var i = 0
      while i < catches.count {
        val c = catches[i]
        scopePush(sc)
        match c.bindName {
          case None       -> {}
          case Some(bname) -> {
            scopeAdd(sc, LocalBinding(name = bname, ty = TyException, isMutable = false))
          }
        }
        val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, diag, c.body)
        scopePop(sc)
        i = i + 1
      }
      match finally_ {
        case None     -> {}
        case Some(fb) -> { val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, diag, fb) }
      }
    }

    case SItem(_)     -> {}
    case SRule(_, _)  -> {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Block checking.
// ─────────────────────────────────────────────────────────────────────────────

// A statement after which control never falls through to a block value: an
// explicit `return`/`throw`, or a loop `break`/`continue` (which transfers out
// of the enclosing loop).  A block whose last statement is one of these has type
// `Never` (bottom), so it unifies cleanly as a branch — `if c { return x } else
// { y }` is typed by its `else` branch rather than false-mismatching `Unit` vs
// the value type.  A trailing `SExpr` of type `Never` (e.g. `panic(...)`) is
// already captured by `lastExprType`, so it is not listed here.
func statementDiverges(stmt: in Statement): Bool {
  match stmt.kind {
    case SReturn(_)   -> true
    case SThrow(_)    -> true
    case SBreak(_)    -> true
    case SContinue(_) -> true
    case _            -> false
  }
}

pub func checkBlock(
  sc:           in Scope,
  tbl:          in SymbolTable,
  sigs:         in Map[String, ResolvedSignature],
  genericNames: in List[String],
  returnTy:     in Type,
  diag:         in List[Diagnostic],
  blk:          in Block
): Type {
  scopePush(sc)
  var lastExprType: Type = TyPrim(pt = PtUnit)
  var i = 0
  while i < blk.statements.count {
    val stmt = blk.statements[i]
    match stmt.kind {
      case SExpr(e) -> {
        lastExprType = inferExpr(sc, tbl, sigs, diag, e)
      }
      case _ -> {
        checkStatement(sc, tbl, sigs, genericNames, returnTy, diag, stmt)
        lastExprType = TyPrim(pt = PtUnit)
      }
    }
    i = i + 1
  }
  scopePop(sc)
  // A block whose final statement transfers control away (return/throw/break/
  // continue) yields no fall-through value: its type is `Never`.
  if blk.statements.count > 0 and statementDiverges(blk.statements[blk.statements.count - 1]) {
    return TyPrim(pt = PtNever)
  }
  lastExprType
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Function body checking.
// ─────────────────────────────────────────────────────────────────────────────

func hasExternTargetAnnotation(anns: in List[Annotation]): Bool {
  var i = 0
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 and segs[0] == "externTarget" { return true }
    i = i + 1
  }
  false
}

// #370: detect `@externStatic` and `@externInstance` co-occurring on
// the same declaration.  The MSIL FFI resolver falls back to static
// in that case (so the program still builds), but it's almost
// always a copy-paste bug — surface it as a diagnostic instead of
// silently picking one.
// Keep in sync with `msil/ffi.l` `hasConflictingHints` (#803).  Both
// scan the same annotation pair; the duplication will retire when
// the shared `Lyric.Annotations` rollup lands.
func hasConflictingExternHints(anns: in List[Annotation]): Bool {
  var i = 0
  var hasStatic = false
  var hasInstance = false
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 {
      if segs[0] == "externStatic"   { hasStatic   = true }
      if segs[0] == "externInstance" { hasInstance = true }
    }
    i = i + 1
  }
  hasStatic and hasInstance
}

// ─────────────────────────────────────────────────────────────────────────────
// §3a. `out` definite-assignment support (#1487 §5.2).
// ─────────────────────────────────────────────────────────────────────────────
//
// Collect the names assigned anywhere in a function body.  Used to enforce that
// every `out` parameter is assigned before the function returns (T0086).  The
// check is the sound subset "never assigned anywhere is a definite violation";
// full all-paths definite-assignment (partial-assignment detection) is a
// follow-up.  The walk is complete over statement and block-bearing forms (so a
// param assigned in any branch / loop / nested block is not falsely flagged).

func addAssignedTarget(target: in Expr, acc: in List[String]): Unit {
  match target.kind {
    case EPath(p)      -> if p.segments.count == 1 { acc.add(p.segments[0]) }
    case EParen(inner) -> addAssignedTarget(inner, acc)
    case _             -> {}
  }
}

func collectAssignedExpr(e: in Expr, acc: in List[String]): Unit {
  match e.kind {
    case EAssign(t, _, v) -> { addAssignedTarget(t, acc); collectAssignedExpr(v, acc) }
    case EParen(inner)    -> collectAssignedExpr(inner, acc)
    case EIf(c, tb, eb, _) -> {
      collectAssignedExpr(c, acc)
      collectAssignedEOB(tb, acc)
      match eb { case Some(x) -> collectAssignedEOB(x, acc); case None -> {} }
    }
    case EMatch(s, arms) -> {
      collectAssignedExpr(s, acc)
      var i = 0
      while i < arms.count {
        match arms[i].guard { case Some(g) -> collectAssignedExpr(g, acc); case None -> {} }
        collectAssignedEOB(arms[i].body, acc)
        i = i + 1
      }
    }
    case EBlock(b)      -> collectAssignedBlock(b, acc)
    case EUnsafe(b)     -> collectAssignedBlock(b, acc)
    case EBinop(_, l, r) -> { collectAssignedExpr(l, acc); collectAssignedExpr(r, acc) }
    case EPrefix(_, x)  -> collectAssignedExpr(x, acc)
    case ECall(f, args) -> {
      collectAssignedExpr(f, acc)
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(ae)  -> collectAssignedExpr(ae, acc)
          case CANamed(_, ae, _) -> collectAssignedExpr(ae, acc)
        }
        i = i + 1
      }
    }
    case EMember(r, _)  -> collectAssignedExpr(r, acc)
    case EIndex(r, idx) -> {
      collectAssignedExpr(r, acc)
      var i = 0
      while i < idx.count { collectAssignedExpr(idx[i], acc); i = i + 1 }
    }
    case EPropagate(x)  -> collectAssignedExpr(x, acc)
    case EAwait(x)      -> collectAssignedExpr(x, acc)
    case EYield(x)      -> collectAssignedExpr(x, acc)
    case ESpawn(x)      -> collectAssignedExpr(x, acc)
    case EOld(x)        -> collectAssignedExpr(x, acc)
    case ETry(x)        -> collectAssignedExpr(x, acc)
    case ETuple(xs)     -> { var i = 0; while i < xs.count { collectAssignedExpr(xs[i], acc); i = i + 1 } }
    case EList(xs)      -> { var i = 0; while i < xs.count { collectAssignedExpr(xs[i], acc); i = i + 1 } }
    case ELambda(_, b)  -> collectAssignedBlock(b, acc)
    case _              -> {}
  }
}

func collectAssignedEOB(eob: in ExprOrBlock, acc: in List[String]): Unit {
  match eob {
    case EOBExpr(e)  -> collectAssignedExpr(e, acc)
    case EOBBlock(b) -> collectAssignedBlock(b, acc)
  }
}

func collectAssignedStmt(s: in Statement, acc: in List[String]): Unit {
  match s.kind {
    case SAssign(t, _, v) -> { addAssignedTarget(t, acc); collectAssignedExpr(v, acc) }
    case SLocal(b) ->
      match b {
        case LBVal(_, _, init) -> collectAssignedExpr(init, acc)
        case LBLet(_, _, init) -> collectAssignedExpr(init, acc)
        case LBVar(_, _, initOpt) -> match initOpt { case Some(e) -> collectAssignedExpr(e, acc); case None -> {} }
      }
    case SReturn(vo) -> match vo { case Some(e) -> collectAssignedExpr(e, acc); case None -> {} }
    case SThrow(e)   -> collectAssignedExpr(e, acc)
    case SExpr(e)    -> collectAssignedExpr(e, acc)
    case SInvariant(e) -> collectAssignedExpr(e, acc)
    case SRule(l, r) -> { collectAssignedExpr(l, acc); collectAssignedExpr(r, acc) }
    case STry(body, catches, fin) -> {
      collectAssignedBlock(body, acc)
      var i = 0
      while i < catches.count { collectAssignedBlock(catches[i].body, acc); i = i + 1 }
      match fin { case Some(fb) -> collectAssignedBlock(fb, acc); case None -> {} }
    }
    case SDefer(b)        -> collectAssignedBlock(b, acc)
    case SScope(_, b)     -> collectAssignedBlock(b, acc)
    case SFor(_, _, it, b) -> { collectAssignedExpr(it, acc); collectAssignedBlock(b, acc) }
    case SWhile(_, c, b)  -> { collectAssignedExpr(c, acc); collectAssignedBlock(b, acc) }
    case SLoop(_, b)      -> collectAssignedBlock(b, acc)
    case _                -> {}
  }
}

func collectAssignedBlock(blk: in Block, acc: in List[String]): Unit {
  var i = 0
  while i < blk.statements.count {
    collectAssignedStmt(blk.statements[i], acc)
    i = i + 1
  }
}

// #1487 (§5.2): every `out` parameter must be assigned before the function
// returns.  Flag any out param never assigned anywhere in the body (T0086).
func checkOutDefiniteAssignment(diag: in List[Diagnostic], fn: in FunctionDecl, sig: in ResolvedSignature): Unit {
  var hasOut = false
  var pi = 0
  while pi < sig.params.count {
    match sig.params[pi].mode { case PMOut -> { hasOut = true } case _ -> {} }
    pi = pi + 1
  }
  if not hasOut { return }
  val assigned: List[String] = newList()
  match fn.body {
    case None -> {}
    case Some(b) ->
      match b {
        case FBBlock(blk) -> collectAssignedBlock(blk, assigned)
        case FBExpr(e)    -> collectAssignedExpr(e, assigned)
      }
  }
  var k = 0
  while k < sig.params.count {
    val p = sig.params[k]
    match p.mode {
      case PMOut ->
        if not listContainsStr(assigned, p.name) {
          diag.add(errorDiagnostic("T0086",
            "`out` parameter '" + p.name +
            "' is never assigned before the function returns", fn.span))
        }
      case _ -> {}
    }
    k = k + 1
  }
}

pub func checkFunctionBody(
  tbl:  in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  fn:   in FunctionDecl,
  sig:  in ResolvedSignature
): Unit {
  if hasExternTargetAnnotation(fn.annotations) {
    // F0002: both @externStatic and @externInstance on one extern.
    if hasConflictingExternHints(fn.annotations) {
      diag.add(errorDiagnostic(
        "F0002",
        "function '" + fn.name + "' has both @externStatic and "
        + "@externInstance — pick one (the FFI resolver cannot "
        + "honour both, and will fall back to @externStatic)",
        fn.span))
    }
    return
  }

  val sc = newScopeForFunction(sig.returnTy, sig.generics)
  var i = 0
  while i < sig.params.count {
    val p = sig.params[i]
    val isMut = match p.mode { case PMIn -> false; case _ -> true }
    scopeAdd(sc, LocalBinding(name = p.name, ty = p.ty, isMutable = isMut))
    i = i + 1
  }

  match fn.body {
    case None -> {}
    case Some(body) ->
      match body {
        case FBExpr(e) -> {
          val bodyType = inferExpr(sc, tbl, sigs, diag, e)
          val isNever = match bodyType { case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }; case _ -> false }
          if not isNever and not typeEquiv(bodyType, sig.returnTy) {
            diag.add(errorDiagnostic("T0070",
              "function body has type " + renderType(bodyType) +
              " but declared return type is " + renderType(sig.returnTy), fn.span))
          }
        }
        case FBBlock(blk) -> {
          val bodyType = checkBlock(sc, tbl, sigs, sig.generics, sig.returnTy, diag, blk)
          val isUnit  = match bodyType { case TyPrim(pt) -> match pt { case PtUnit -> true; case _ -> false }; case _ -> false }
          val isNever = match bodyType { case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }; case _ -> false }
          if not isUnit and not isNever and not typeEquiv(bodyType, sig.returnTy) {
            diag.add(errorDiagnostic("T0070",
              "function body trailing expression has type " + renderType(bodyType) +
              " but declared return type is " + renderType(sig.returnTy), fn.span))
          }
        }
      }
  }
  checkOutDefiniteAssignment(diag, fn, sig)
}
