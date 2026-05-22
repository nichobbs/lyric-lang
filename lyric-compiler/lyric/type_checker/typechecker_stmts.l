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
                  case Some(_) -> {
                    if not typeEquiv(declT, initType) {
                      diag.add(errorDiagnostic("T0061",
                        "var binding declared as " + renderType(declT) +
                        " but initialiser has type " + renderType(initType), stmt.span))
                    }
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

    case STry(body, catches) -> {
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, diag, body)
      var i = 0
      while i < catches.count {
        val c = catches[i]
        scopePush(sc)
        match c.bindName {
          case None       -> {}
          case Some(bname) -> {
            scopeAdd(sc, LocalBinding(name = bname, ty = TyError, isMutable = false))
          }
        }
        val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, diag, c.body)
        scopePop(sc)
        i = i + 1
      }
    }

    case SItem(_)     -> {}
    case SRule(_, _)  -> {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Block checking.
// ─────────────────────────────────────────────────────────────────────────────

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

  val sc = newScope()
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
}
