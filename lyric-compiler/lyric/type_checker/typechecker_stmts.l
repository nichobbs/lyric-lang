//! typechecker_stmts.l — statement and function-body type checking.
//! Mirrors compiler/src/Lyric.TypeChecker/StmtChecker.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Pattern binding.
// ─────────────────────────────────────────────────────────────────────────────
func bindPattern(sc: in Scope, pat: in Pattern, ty: in Type): Unit {
  match pat.kind {
    case PBinding(name, innerOpt) -> {
      if name != "_" {
        scopeAdd(sc, LocalBinding(name = name, ty = ty, isMutable = false))
      }
      match innerOpt {
        case None -> {
        }
        case Some(inner) -> bindPattern(sc, inner, ty)
      }
    }
    case PWildcard -> {
    }
    case PTuple(patterns) -> {
      val telems = match unrefine(ty) { case TyTuple(es) -> es; case _ -> newList() }
      var i = 0
      while i < patterns.count {
        val et = if i < telems.count { telems[i] } else { TyError }
        bindPattern(sc, patterns[i], et)
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
    case PParen(inner) -> {
      bindPattern(sc, inner, ty)
    }
    case PRecord(_, fields, _) -> {
      // Field types are TyError here because bindPattern has no tbl access; the
      // typed path (bindPatternTyped in typechecker_exprs.l) resolves real field types.
      var i = 0
      while i < fields.count {
        match fields[i] {
          case RPFNamed(_, p, _) -> bindPattern(sc, p, TyError)
          case RPFShort(nm, _) -> scopeAdd(sc, LocalBinding(name = nm, ty = TyError, isMutable = false))
        }
        i = i + 1
      }
    }
    case _ -> {
    }
  }
}

// A pattern usable as a `for` loop binding: a name (with an irrefutable
// inner), `_`, parentheses, or a tuple of those.  Anything that can fail to
// match an element (constructor, record, literal, range, …) is refutable.
// Keep in sync with the accepted set of `bindForPatternMsil` in
// `msil/codegen.l` (#3187).
func forPatternIrrefutable(p: in Pattern): Bool {
  match p.kind {
    case PWildcard -> true
    case PBinding(_, inner) -> match inner { case None -> true; case Some(ip) -> forPatternIrrefutable(ip) }
    case PParen(ip) -> forPatternIrrefutable(ip)
    case PTuple(ps) -> {
      var i = 0
      while i < ps.count {
        if not forPatternIrrefutable(ps[i]) {
          return false
        }
        i = i + 1
      }
      true
    }
    case _ -> false
  }
}

// The element type a range-driven `for` binds: `Int` when both bounds are
// `Int`, `Long` when both are `Long` — the two shapes the counting-loop
// codegen actually supports (`emitCountingForMsil` drives the increment and
// comparison off the low bound's width; `emitCountingForJvm` panics on a
// width mismatch).  Everything else — mixed Int/Long, non-integer bounds,
// open-ended ranges — degrades to `TyError` (the lenient wildcard), never a
// new rejection: codegen owns those failure modes today.  The bound
// expressions are always inferred so their own contents are checked.
func forRangeElemType(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  bound: in RangeBound,
): Type {
  match bound {
    case RBClosed(lo, hi) -> forRangeBoundsElemType(
      inferExpr(sc, tbl, sigs, diag, lo),
      inferExpr(sc, tbl, sigs, diag, hi)
    )
    case RBHalfOpen(lo, hi, _) -> forRangeBoundsElemType(
      inferExpr(sc, tbl, sigs, diag, lo),
      inferExpr(sc, tbl, sigs, diag, hi)
    )
    case RBLowerOpen(hi) -> {
      val _ = inferExpr(sc, tbl, sigs, diag, hi)
      TyError
    }
    case RBUpperOpen(lo) -> {
      val _ = inferExpr(sc, tbl, sigs, diag, lo)
      TyError
    }
  }
}

// Both counting-loop backends derive the loop variable from the LOW bound
// (`emitCountingForMsil` / `emitCountingForJvm` allocate the counter slot from
// `loTy`), so an unknown-typed high bound — today most commonly `xs.count`,
// which the member checker cannot type yet (docs/59 A4) — does not block
// typing the binding: the low bound alone determines it.  A *known*
// mismatched high bound (Int lo with Long hi or vice versa) degrades to
// `TyError` rather than claiming a type for a loop codegen cannot lower.
func forRangeBoundsElemType(loTy: in Type, hiTy: in Type): Type {
  val hiUnknown = match hiTy { case TyError -> true; case TyVar(_) -> true; case _ -> false }
  if unrefinesToInt(loTy) and (unrefinesToInt(hiTy) or hiUnknown) {
    return TyPrim(pt = PtInt)
  }
  if unrefinesToLong(loTy) and (unrefinesToLong(hiTy) or hiUnknown) {
    return TyPrim(pt = PtLong)
  }
  TyError
}

// When a binding is declared with an inline refined type (`Int range lo .. hi`)
// and initialised with an integer literal, reject a literal that falls outside
// the statically-known bounds (T0015).  This is the inline-refined-type
// construction check; validating constructions of *named* distinct range
// subtypes (`type Age = Int range …`) is Band-4 work and is not covered here.
func checkRefinedLiteralBound(declT: in Type, init: in Expr, diag: in List[Diagnostic]): Unit {
  match declT {
    case TyRefined(_, lo, hi, inc, _) -> match exprLiteralLong(init) {
      case None -> {
      }
      case Some(v) -> {
        // A `ULong` bound or literal above Long.MaxValue is a negative
        // pattern (#7839), so it orders unsigned.
        val isULong = match unrefine(declT) {
          case TyPrim(pt) -> match pt { case PtULong -> true; case _ -> false }
          case _ -> false
        }
        val belowLo = match lo { case None -> false; case Some(l) -> if isULong { ulongLessThan(v, l) } else { v < l } }
        val aboveHi = match hi {
          case None -> false
          case Some(h) -> if isULong {
            if inc {
              ulongLessThan(h, v)
            } else {
              not ulongLessThan(v, h)
            }
          } else {
            if inc {
              v > h
            } else {
              v >= h
            }
          }
        }
        if belowLo or aboveHi {
          val shown = if isULong { ulongPatternToString(v) } else { toString(v) }
          diag.add(errorDiagnostic("T0015", "literal " + shown + " is out of range for type " + renderType(declT), init.span))
        }
      }
    }
    case _ -> {
    }
  }
}

// An unsuffixed integer literal whose value does not fit the plain integer
// type it initialises (`val x: Int = 3000000000`) is reported as T0015 and
// the caller skips its generic type-mismatch diagnostic (#7346).  Before
// this the literal typed as `Int` whatever its value and wrapped silently
// on dotnet.  Refined types are `checkRefinedLiteralBound`'s job.
func reportIntLiteralOutOfRange(declT: in Type, init: in Expr, diag: in List[Diagnostic]): Bool {
  match declT {
    case TyPrim(_) -> match unsuffixedIntLiteralValue(init) {
      case Some(v) -> {
        if isConcreteIntType(declT) and not intValueFitsType(v, declT) {
          diag.add(
            errorDiagnostic("T0015", "literal " + toString(v) + " is out of range for type " + renderType(declT), init.span)
          )
          return true
        }
        false
      }
      case None -> false
    }
    case _ -> false
  }
}

// A variable or a chain of field reads on one: evaluating it twice has no
// side effects.
func isPurePathExpr(e: in Expr): Bool {
  match e.kind {
    case EPath(_) -> true
    case ESelf -> true
    case EMember(recv, _) -> isPurePathExpr(recv)
    case EParen(inner) -> isPurePathExpr(inner)
    case _ -> false
  }
}

// `r += s` / `r -= s` on a homogeneous numeric record that derives `Add` /
// `Sub` (D155) is rewritten to `r = r + s`, which evaluates `r` twice, so it
// needs a variable or field target (T0134), as for a distinct type.
func checkRecordCompoundAssign(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  op: in AssignOp,
  target: in Expr,
  targetType: in Type,
  valueType: in Type,
  span: in Span,
): Unit {
  val isRecord = match targetType {
    case TyUser(tid, _, _) -> match recordSymbolOfTid(tbl, tid) {
      case Some(_) -> true
      case None -> false
    }
    case _ -> false
  }
  if not isRecord {
    return
  }
  // `r op= s` is `r = r op s`, so it needs the marker the binary operator
  // does; only `Add` and `Sub` are derivable on a record (T0152).
  val marker = compoundAssignDerive(op)
  val derivable = match op { case AssPlus -> true; case AssMinus -> true; case _ -> false }
  if not derivable or not hasDerive(tbl, marker, targetType) {
    diag.add(
      errorDiagnostic("T0030", "compound assignment needs " + renderType(targetType) + " to derive " + marker, span)
    )
    return
  }
  val bop = match op { case AssMinus -> BSub; case _ -> BAdd }
  if isPurePathExpr(target) {
    recordRecordArith(tbl, targetType, valueType, bop, span)
  } else {
    diag.add(
      errorDiagnostic(
        "T0134",
        "compound assignment to a record (" + renderType(targetType) +
          ") needs a variable or field target; write the assignment out (`x = x + y`)",
        span
      )
    )
  }
}

func recordOverflowCompound(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  target: in Expr,
  targetType: in Type,
  span: in Span,
): Unit {
  val tn = overflowTypeName(targetType)
  if tn.length == 0 {
    return
  }
  recordOverflowSite(tbl, span, "compound:" + tn)
  if isOverflowPureTarget(target) {
    return
  }
  // The rewrite binds the receiver (and index) once; type them here, where
  // the scope is known.  Re-inferring an already-checked expression reports
  // nothing new, so its diagnostics go to a scratch list.
  val scratch: List[Diagnostic] = newList()
  val arrTemps = arrayCompoundTemps(sc, tbl, sigs, target, span)
  val temps = match arrTemps {
    case Some(at) -> at
    case None -> match target.kind {
      case EIndex(recv, idxs) -> {
        val rt = inferExpr(sc, tbl, sigs, scratch, recv)
        val it = if idxs.count == 1 { typeExprForRef(tbl, inferExpr(sc, tbl, sigs, scratch, idxs[0]), span) } else { None }
        CompoundTemps(recvType = typeExprForRef(tbl, rt, span), indexType = it, arrayChain = false)
      }
      case EMember(recv, _) -> {
        val rt = inferExpr(sc, tbl, sigs, scratch, recv)
        CompoundTemps(recvType = typeExprForRef(tbl, rt, span), indexType = None, arrayChain = false)
      }
      case _ -> CompoundTemps(recvType = None, indexType = None, arrayChain = false)
    }
  }
  val key = recordCopySiteKey(span)
  if tbl.overflowCompoundTemps.containsKey(key) {
    tbl.overflowCompoundTemps.remove(key)
  }
  tbl.overflowCompoundTemps.add(key, temps)
}

// A compound-assignment target the overflow rewrite may evaluate twice
// (`x op= y` becomes `x = <checked x op y>`): a variable, `self`, a field
// path on one, or an index into one by a variable or literal.
pub func isOverflowPureTarget(e: in Expr): Bool {
  match e.kind {
    case EPath(_) -> true
    case ESelf -> true
    case EMember(recv, _) -> isOverflowPureTarget(recv)
    case EParen(inner) -> isOverflowPureTarget(inner)
    case EIndex(recv, idxs) -> {
      if not isOverflowPureTarget(recv) {
        return false
      }
      for ix in idxs {
        val simple = match ix.kind { case EPath(_) -> true; case ELiteral(_) -> true; case _ -> false }
        if not simple {
          return false
        }
      }
      true
    }
    case _ -> false
  }
}

// The `derives` marker a compound operator's binary form requires.
func compoundAssignDerive(op: in AssignOp): String {
  match op {
    case AssPlus -> "Add"
    case AssMinus -> "Sub"
    case AssStar -> "Mul"
    case AssSlash -> "Div"
    case AssPercent -> "Mod"
    case AssEq -> ""
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Statement checking.
// ─────────────────────────────────────────────────────────────────────────────
pub func checkStatement(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  genericNames: in List[String],
  returnTy: in Type,
  returnTyExpr: in Option[TypeExpr],
  diag: in List[Diagnostic],
  stmt: in Statement,
): Unit {
  match stmt.kind {
    // A2 (docs/59 §5.1): an annotated binding resolves its declared type
    // *first* and feeds it to `inferExprExpected`, so a lambda initialiser
    // with unannotated params (`val f: (Int) -> Bool = { x -> x > 0 }`) types
    // its params from the declaration.  Non-lambda initialisers and
    // unannotated bindings take the plain-inference path exactly as before.
    case SLocal(binding) -> match binding {
      case LBVal(pat, tyOpt, init) -> match tyOpt {
        case None -> {
          val initType = inferExpr(sc, tbl, sigs, diag, init)
          recordLocalFuncType(tbl, init, initType)
          recordLocalBranchType(tbl, init, initType)
          // A plain name bound to an evidence-free construction is open: its
          // uses fix its type (#7788).
          val openName = match pat.kind {
            case PBinding(nm, innerPat) -> match innerPat {
              case None -> if nm != "_" { nm } else { "" }
              case Some(_) -> ""
            }
            case _ -> ""
          }
          val openKey = if openName != "" { registerOpenBindingSite(sc, tbl, init, initType) } else { "" }
          val bindTy = if checkLocalValPattern(tbl, diag, pat, initType) { TyError } else { initType }
          if openKey != "" {
            scopeAdd(sc, LocalBinding(name = openName, ty = initType, isMutable = false, openSite = openKey))
          } else {
            bindPattern(sc, pat, bindTy)
            // A destructuring of an open tuple, a literal or a local, binds
            // each name at an open element open to it (#7855).
            if openName == "" {
              val localKey = openSiteOfExpr(sc, init)
              val tupleKey = if localKey != "" { localKey } else { registerOpenBindingSite(sc, tbl, init, initType) }
              bindOpenTuplePattern(sc, tbl, pat, tupleKey)
            }
          }
          recordTuplePatternBindings(tbl, pat, bindTy, false, sc.genericNames)
        }
        case Some(te) -> {
          val ctx = newGenericContext()
          gctxPush(ctx, genericNames)
          val declT = resolveType(tbl, ctx, diag, te)
          val initType = inferExprExpected(sc, tbl, sigs, diag, init, declT)

          val literalOutOfRange = reportIntLiteralOutOfRange(declT, init, diag)
          if not literalOutOfRange and not argSatisfiesParam(tbl, declT, initType) {
            diag.add(
              errorDiagnostic(
                "T0060",
                "val binding declared as " + renderTypeExpr(te, declT) + " but initialiser " +
                  hasTypeOrEmptyLiteral(initType, init) +
                  typeMismatchHint(tbl, declT, initType),
                stmt.span
              )
            )
          }
          recordUnsignedWidening(tbl, declT, initType, init)
          checkRefinedLiteralBound(declT, init, diag)
          val bindTy = if checkLocalValPattern(tbl, diag, pat, declT) { TyError } else { declT }
          bindPattern(sc, pat, bindTy)
          recordTuplePatternBindings(tbl, pat, bindTy, false, sc.genericNames)
        }
      }
      case LBVar(name, tyOpt, initOpt) -> match tyOpt {
        case None -> {
          val initType = match initOpt {
            case None -> TyError
            case Some(e) -> {
              val t = inferExpr(sc, tbl, sigs, diag, e)
              noteArrayStore(tbl, e, t)
              recordLocalFuncType(tbl, e, t)
              recordLocalBranchType(tbl, e, t)
              t
            }
          }
          val openKey = match initOpt { case Some(e) -> registerOpenBindingSite(sc, tbl, e, initType); case None -> "" }
          scopeAdd(sc, LocalBinding(name = name, ty = initType, isMutable = true, openSite = openKey))
        }
        case Some(te) -> {
          val ctx = newGenericContext()
          gctxPush(ctx, genericNames)
          val declT = resolveType(tbl, ctx, diag, te)
          match initOpt {
            case Some(initE) -> {
              val initType = inferExprExpected(sc, tbl, sigs, diag, initE, declT)
              noteArrayStore(tbl, initE, initType)

              val literalOutOfRange = reportIntLiteralOutOfRange(declT, initE, diag)
              if not literalOutOfRange and not argSatisfiesParam(tbl, declT, initType) {
                diag.add(
                  errorDiagnostic(
                    "T0061",
                    "var binding declared as " + renderTypeExpr(te, declT) + " but initialiser " +
                      hasTypeOrEmptyLiteral(initType, initE) +
                      typeMismatchHint(tbl, declT, initType),
                    stmt.span
                  )
                )
              }
              recordUnsignedWidening(tbl, declT, initType, initE)
              checkRefinedLiteralBound(declT, initE, diag)
            }
            case None -> {
              noteArrayZeroInit(tbl, diag, declT, recordCopySiteKey(stmt.span), stmt.span, "var '" + name + "'")
            }
          }
          scopeAdd(sc, LocalBinding(name = name, ty = declT, isMutable = true))
        }
      }
      case LBLet(name, tyOpt, init) -> match tyOpt {
        case None -> {
          val initType = inferExpr(sc, tbl, sigs, diag, init)
          recordLocalFuncType(tbl, init, initType)
          recordLocalBranchType(tbl, init, initType)
          val openKey = registerOpenBindingSite(sc, tbl, init, initType)
          scopeAdd(sc, LocalBinding(name = name, ty = initType, isMutable = false, openSite = openKey))
        }
        case Some(te) -> {
          val ctx = newGenericContext()
          gctxPush(ctx, genericNames)
          val declT = resolveType(tbl, ctx, diag, te)
          val initType = inferExprExpected(sc, tbl, sigs, diag, init, declT)

          val literalOutOfRange = reportIntLiteralOutOfRange(declT, init, diag)
          if not literalOutOfRange and not argSatisfiesParam(tbl, declT, initType) {
            diag.add(
              errorDiagnostic(
                "T0062",
                "let binding declared as " + renderTypeExpr(te, declT) + " but initialiser " +
                  hasTypeOrEmptyLiteral(initType, init) +
                  typeMismatchHint(tbl, declT, initType),
                stmt.span
              )
            )
          }
          recordUnsignedWidening(tbl, declT, initType, init)
          checkRefinedLiteralBound(declT, init, diag)
          scopeAdd(sc, LocalBinding(name = name, ty = declT, isMutable = false))
        }
      }
    }

    case SAssign(target, op, value) -> {
      val targetType = inferExpr(sc, tbl, sigs, diag, target)
      exemptArrayCopy(tbl, target)
      checkArrayElementWrite(sc, tbl, sigs, diag, target)
      val valueType = inferExprExpected(sc, tbl, sigs, diag, value, targetType)
      noteArrayStore(tbl, value, valueType)
      recordHoistedAssignValue(sc, tbl, target, value, valueType, targetType)
      noteOpenBindingAssign(sc, tbl, sigs, target, valueType)
      // `s += <rhs>` onto a String plain-variable target accepts any RHS type
      // (mirroring binary `+`); field/indexed String targets stay strict.  See
      // `isStringPlusVarAssign` (typechecker_exprs.l) for the full rationale
      // and the #5688 follow-up (#5657).
      val stringPlusAssign = isStringPlusVarAssign(target, op, targetType)
      // `x += y`, `-=` and `*=` on an overflow-checked integer type (D163).
      match op {
        case AssPlus -> recordOverflowCompound(sc, tbl, sigs, target, targetType, stmt.span)
        case AssMinus -> recordOverflowCompound(sc, tbl, sigs, target, targetType, stmt.span)
        case AssStar -> recordOverflowCompound(sc, tbl, sigs, target, targetType, stmt.span)
        case _ -> ()
      }
      // A compound assignment on a distinct type is rewritten to
      // `target = T.from(target.value <op> value.value)` (#7361).  That
      // evaluates the target twice, so it must be a variable or field path.
      match op {
        case AssEq -> ()
        case _ -> match distinctFromPath(tbl, targetType) {
          case Some(path) -> {
            // `x op= y` is `x = x op y`, so it needs the same `derives` marker
            // the binary operator does (#7425).
            val marker = compoundAssignDerive(op)
            if not hasDerive(tbl, marker, targetType) {
              diag.add(
                errorDiagnostic("T0030", "compound assignment needs " + renderType(targetType) + " to derive " + marker, stmt.span)
              )
            } else if isPurePathExpr(target) {
              val key = recordCopySiteKey(stmt.span)
              if not tbl.distinctCompoundSites.containsKey(key) {
                tbl.distinctCompoundSites.add(key, path)
              }
            } else {
              diag.add(
                errorDiagnostic(
                  "T0134",
                  "compound assignment to a distinct type (" + renderType(targetType) +
                    ") needs a variable or field target; write the assignment out (`x = x + y`)",
                  stmt.span
                )
              )
            }
          }
          case None -> checkRecordCompoundAssign(tbl, diag, op, target, targetType, valueType, stmt.span)
        }
      }
      // A literal that does not fit the target (`x += -1` on a `UInt`) is
      // T0015, as for a binding, rather than a type mismatch (#7841).
      val literalOutOfRange = not stringPlusAssign and reportIntLiteralOutOfRange(targetType, value, diag)
      if not stringPlusAssign and not literalOutOfRange and not argSatisfiesParam(tbl, targetType, valueType) {
        diag.add(
          errorDiagnostic(
            "T0063",
            "assigned value " + ofTypeOrEmptyLiteral(valueType, value) + " does not match target of type " +
              renderType(targetType) +
              typeMismatchHint(tbl, targetType, valueType),
            stmt.span
          )
        )
      }
      if not stringPlusAssign {
        recordUnsignedWidening(tbl, targetType, valueType, value)
      }
      noteRangeAssign(sc, tbl, target, op, targetType, value, stmt.span)
      recordUnsignedCompoundValue(tbl, op, targetType, valueType, value, stringPlusAssign)
      // #1487 (§5.2): an `in` parameter — like a `val`/`let` binding — is
      // immutable and cannot be reassigned.  The checker records this as
      // `isMutable = false` (in-params and val/let), so a simple-path
      // assignment whose target is an immutable binding is rejected (T0087).
      // `var` locals and `out`/`inout` params are mutable and unaffected.
      match target.kind {
        case EPath(p) -> if p.segments.count == 1 {
          match scopeTryFind(sc, p.segments[0]) {
            case Some(b) -> if not b.isMutable { diag.add(errorDiagnostic("T0087", t0087Msg(p.segments[0]), target.span)) }
            case None -> {
            }
          }
        }
        // `self = …` replaces the receiver, which only an `inout` receiver
        // may do (#8179); an `in` receiver is the caller's value, not its
        // place.
        case ESelf -> {
          val selfMutable = match scopeTryFind(sc, "self") { case Some(b) -> b.isMutable; case None -> false }
          if not selfMutable {
            diag.add(
              errorDiagnostic(
                "T0087",
                "cannot assign `self`: only a record method or dot-named function whose receiver is declared `self: inout` may replace the caller's value",
                target.span
              )
            )
          }
        }
        case _ -> {
        }
      }
    }

    case SReturn(valueOpt) -> match valueOpt {
      case None -> {
        if not typeEquiv(returnTy, TyPrim(pt = PtUnit)) {
          diag.add(
            errorDiagnostic(
              "T0064",
              "return without value but enclosing function returns " + renderOptTypeExpr(returnTyExpr, returnTy),
              stmt.span
            )
          )
        }
      }
      case Some(e) -> {
        // #7696: `return [1, 2, 3]` against a declared `List[T]` return type
        // types the literal directly as `List[T]` here, the same as a
        // `List[T]`-annotated binding's initialiser (docs/decisions/
        // D-progress-1026-return-position-list-literals.md).
        val t = inferExprExpected(sc, tbl, sigs, diag, e, returnTy)
        val isNever = match t { case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }; case _ -> false }
        if not isNever and tbl.lambdaReturnFrames.count > 0 and (match returnTy { case TyError -> true; case _ -> false }) {
          tbl.lambdaReturnFrames[tbl.lambdaReturnFrames.count - 1].add(t)
        }
        // A returned value initialises the result, so it widens like an
        // initialiser (docs/01 §4.1, #7805).
        recordWideningSite(tbl, returnTy, t, e, false)
        if not isNever and not typeAssignable(tbl, returnTy, t) and not numericWidensTo(returnTy, t) {
          diag.add(
            errorDiagnostic(
              "T0065",
              "returned value " + ofTypeOrEmptyLiteral(t, e) + " does not match declared return type " +
                renderOptTypeExpr(returnTyExpr, returnTy) +
                typeMismatchHint(tbl, returnTy, t),
              stmt.span
            )
          )
        }
      }
    }

    case SThrow(e) -> {
      val _ = inferExpr(sc, tbl, sigs, diag, e)
    }

    case SBreak(_) -> {
    }
    case SContinue(_) -> {
    }

    case SInvariant(e) -> checkBoolClause(sc, tbl, sigs, diag, e, "loop invariant", stmt.span)

    case SExpr(e) -> {
      match e.kind {
        case EYield(inner) -> {
          // T0095: yield value must match the generator's declared element type.
          val innerTy = inferExpr(sc, tbl, sigs, diag, inner)
          val isNever = match innerTy { case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }; case _ -> false }
          val isErr = match innerTy { case TyError -> true; case _ -> false }
          if not isNever and not isErr and not typeEquiv(innerTy, returnTy) {
            diag.add(
              errorDiagnostic(
                "T0095",
                "yield value has type " + renderType(innerTy) + " but the generator's declared element type is " +
                  renderType(returnTy),
                e.span
              )
            )
          }
        }
        case _ -> {
          val _ = inferExpr(sc, tbl, sigs, diag, e)
        }
      }
    }

    case SDefer(body) -> {
      checkNoYieldInHandler(diag, body, "a `defer` block", stmt.span)
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, body, false, TyError)
    }

    case SScope(_, body) -> {
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, body, false, TyError)
    }

    case SLoop(_, body) -> {
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, body, false, TyError)
    }

    case SFor(_, pat, iter, body) -> {
      // A range iterator is typed here, not in `inferExpr`'s `ERange` arm: the
      // parser only builds `ERange` in `for`-iterator position, so `for` is the
      // sole consumer of a range's element type and `ERange` itself can keep its
      // lenient `TyError` result (#1478 / docs/59 A1).  Typing the bounds also
      // checks them — before this they were never visited by the checker.
      val elemType = match iter.kind {
        case ERange(bound) -> forRangeElemType(sc, tbl, sigs, diag, bound)
        // An `async func g(): E` generator types its call as its element
        // type `E`, so iterating the call iterates values of type `E`
        // whatever `E` is -- a record, a union, a tuple, or a collection or
        // monad such as `List[Int]` / `Option[Int]`, which must not be read
        // as the thing being iterated (#7750).  Whether the call is a
        // generator call is read off the signature the call itself bound to
        // while it was inferred, never its bare name (#7771).
        case _ -> {
          val iterType = inferExpr(sc, tbl, sigs, diag, iter)
          match arraySiteOf(tbl, iterType, iter.span) {
            case Some(site) -> if not tbl.arrayForSites.containsKey(recordCopySiteKey(iter.span)) {
              tbl.arrayForSites.add(recordCopySiteKey(iter.span), site)
            }
            case None -> if isArrayType(iterType) and not inValueGenericBody(tbl) {
              diag.add(arrayUnknownLength(iterType, iter.span))
            }
          }
          if forIterIsGeneratorCall(tbl, iter) {
            iterType
          } else {
            forIterElemType(tbl, diag, iter, iterType)
          }
        }
      }
      // #3187: a `for` binding must be irrefutable — codegen has no failure
      // path for a non-matching element, so a refutable pattern accepted here
      // would reach the backends' defensive (no-IL) branch and produce a
      // broken binary.  Mirrors `bindForPatternMsil`'s accepted set.
      if not forPatternIrrefutable(pat) {
        diag.add(
          errorDiagnostic(
            "T0112",
            "a `for` loop variable must be an irrefutable pattern (a name, `_`, or a tuple of those); " +
              "refutable patterns are not allowed in a `for` binding — use `match` inside the loop body instead",
            pat.span
          )
        )
      }
      scopePush(sc)
      // Erase unresolved type variables (a `List[T]` / `slice[T]` element inside
      // a generic function) to the lenient wildcard: `TyVar` passes `typeEquiv`
      // but not `isNumericType`, so binding it raw would trip false T0030s on
      // arithmetic the where-bounds make valid.
      bindPattern(sc, pat, eraseTyVars(elemType))
      // A generator's elements reach the loop through an erased iterator
      // (`java.util.Iterator.next()` on the JVM), so the loop variable itself
      // is recorded like a tuple element: `Lyric.Mono` binds it through a
      // local annotated with the generator's element type (#7750).
      recordTuplePatternBindings(tbl, pat, eraseTyVars(elemType), forIterIsGeneratorCall(tbl, iter), sc.genericNames)
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, body, false, TyError)
      scopePop(sc)
    }

    case SWhile(_, cond, body) -> {
      val condT = inferExpr(sc, tbl, sigs, diag, cond)
      if not typeEquiv(condT, TyPrim(pt = PtBool)) {
        diag.add(errorDiagnostic("T0066", "while-condition must be Bool (got " + renderType(condT) + ")", stmt.span))
      }
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, body, false, TyError)
    }

    case STry(body, catches, finally_) -> {
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, body, false, TyError)
      var i = 0
      while i < catches.count {
        val c = catches[i]
        scopePush(sc)
        match c.bindName {
          case None -> {
          }
          case Some(bname) -> {
            scopeAdd(sc, LocalBinding(name = bname, ty = TyException, isMutable = false))
          }
        }
        checkNoYieldInHandler(diag, c.body, "a `catch` block", c.span)
        val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, c.body, false, TyError)
        scopePop(sc)
        i = i + 1
      }
      match finally_ {
        case None -> {
        }
        case Some(fb) -> {
          checkNoYieldInHandler(diag, fb, "a `finally` block", fb.span)
          val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, fb, false, TyError)
        }
      }
    }

    case SItem(_) -> {
    }
    case SRule(_, _) -> {
    }
  }
}

// T0142: a generator suspends at `yield` and resumes where it left off, but a
// `catch`, `finally` or `defer` body runs while an exception or an exit is in
// flight and cannot be suspended and re-entered (§7.2).  A `yield` in the
// protected `try` body itself is fine.
func checkNoYieldInHandler(diag: in List[Diagnostic], body: in Block, what: in String, sp: in Span): Unit {
  if blockContainsYield(body) {
    diag.add(
      errorDiagnostic(
        "T0142",
        "`yield` cannot appear inside " + what +
          ": a generator cannot suspend while a handler or deferred block is running. Move the `yield` " +
          "into the `try` body, or record the value and yield it after the `try`",
        sp
      )
    )
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Block checking.
// ─────────────────────────────────────────────────────────────────────────────
// Whether `label` (a loop's own label, if any) is targeted by `bl`, a
// `break`'s label argument (`None` for a bare `break`), given whether this
// break was reached by passing through a more-nested loop's own break scope
// first (`nested`).  A bare `break` targets only the innermost enclosing
// loop, so once `nested` is true it has already been "claimed" by that
// nested loop and cannot also escape the outer loop being analyzed here.  A
// labelled `break <label>` always identifies its exact target regardless of
// nesting, so `nested` does not affect that case.
func breakTargetsLoop(bl: in Option[String], label: in Option[String], nested: in Bool): Bool {
  match bl {
    case None -> not nested
    case Some(l) -> match label { case Some(ll) -> l == ll; case None -> false }
  }
}

// Whether `blk` — the body of a loop labelled `label` — can transfer control
// out of *that* loop via a `break`: a bare `break` reached without first
// passing through a more-nested loop's own break scope (`nested`), or a
// labelled `break <label>` matching `label` at any depth.  Never descends
// into a nested `ELambda` body (a `break` cannot cross a function boundary,
// mirroring `exprContainsYield`'s treatment of `EYield`).  Used only to
// decide whether an unconditional loop (`loop { }` / `while true { }`)
// diverges when it is a block's trailing statement (#6602): the presence of
// an escaping `break` means the loop can still fall through with `Unit`
// rather than transferring control via `return`/`throw`/an outer `break`.
func blockMayEscapeLoop(blk: in Block, label: in Option[String], nested: in Bool): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtMayEscapeLoop(blk.statements[i], label, nested) {
      return true
    }
    i = i + 1
  }
  false
}

func listAnyExprMayEscapeLoop(es: in List[Expr], label: in Option[String], nested: in Bool): Bool {
  var i = 0
  while i < es.count {
    if exprMayEscapeLoop(es[i], label, nested) {
      return true
    }
    i = i + 1
  }
  false
}

func exprMayEscapeLoop(e: in Expr, label: in Option[String], nested: in Bool): Bool {
  match e.kind {
    case ELambda(_, _) -> false
    case ELiteral(_) -> false
    case EPath(_) -> false
    case ESelf -> false
    case EResult -> false
    case EError -> false
    case EParen(inner) -> exprMayEscapeLoop(inner, label, nested)
    case EAwait(inner) -> exprMayEscapeLoop(inner, label, nested)
    case ESpawn(inner) -> exprMayEscapeLoop(inner, label, nested)
    case EOld(inner) -> exprMayEscapeLoop(inner, label, nested)
    case EPropagate(inner) -> exprMayEscapeLoop(inner, label, nested)
    case ETry(inner) -> exprMayEscapeLoop(inner, label, nested)
    case EYield(inner) -> exprMayEscapeLoop(inner, label, nested)
    case EPrefix(_, inner) -> exprMayEscapeLoop(inner, label, nested)
    case ETuple(elems) -> listAnyExprMayEscapeLoop(elems, label, nested)
    case EList(elems) -> listAnyExprMayEscapeLoop(elems, label, nested)
    case EInterpolated(segs) -> {
      var found = false
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(se) -> {
            if exprMayEscapeLoop(se, label, nested) {
              found = true
            }
          }
          case ISText(_) -> {
          }
        }
        i = i + 1
      }
      found
    }
    case EBinop(_, l, r) -> exprMayEscapeLoop(l, label, nested) or exprMayEscapeLoop(r, label, nested)
    case EAssign(t, _, v) -> exprMayEscapeLoop(t, label, nested) or exprMayEscapeLoop(v, label, nested)
    case EMember(recv, _) -> exprMayEscapeLoop(recv, label, nested)
    case ETypeApp(f, _) -> exprMayEscapeLoop(f, label, nested)
    case EIndex(recv, idxs) -> exprMayEscapeLoop(recv, label, nested) or listAnyExprMayEscapeLoop(idxs, label, nested)
    case ECall(f, args) -> {
      if exprMayEscapeLoop(f, label, nested) {
        return true
      }
      var i = 0
      while i < args.count {
        val found = match args[i] {
          case CAPositional(v) -> exprMayEscapeLoop(v, label, nested)
          case CANamed(_, v, _) -> exprMayEscapeLoop(v, label, nested)
        }
        if found {
          return true
        }
        i = i + 1
      }
      false
    }
    case ERange(rb) -> match rb {
      case RBClosed(a, b) -> exprMayEscapeLoop(a, label, nested) or
        exprMayEscapeLoop(b, label, nested)
      case RBHalfOpen(a, b, _) -> exprMayEscapeLoop(a, label, nested) or
        exprMayEscapeLoop(b, label, nested)
      case RBLowerOpen(a) -> exprMayEscapeLoop(a, label, nested)
      case RBUpperOpen(a) -> exprMayEscapeLoop(a, label, nested)
    }
    case EIf(c, t, eOpt, _) -> {
      if exprMayEscapeLoop(c, label, nested) {
        return true
      }
      val inT = match t {
        case EOBExpr(te) -> exprMayEscapeLoop(te, label, nested)
        case EOBBlock(tb) -> blockMayEscapeLoop(tb, label, nested)
      }
      if inT {
        return true
      }
      match eOpt {
        case None -> false
        case Some(b) -> match b {
          case EOBExpr(ee) -> exprMayEscapeLoop(ee, label, nested)
          case EOBBlock(eb) -> blockMayEscapeLoop(eb, label, nested)
        }
      }
    }
    case EMatch(subj, arms) -> {
      if exprMayEscapeLoop(subj, label, nested) {
        return true
      }
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        val inGuard = match arm.guard { case None -> false; case Some(g) -> exprMayEscapeLoop(g, label, nested) }
        if inGuard {
          return true
        }
        val inBody = match arm.body {
          case EOBExpr(ae) -> exprMayEscapeLoop(ae, label, nested)
          case EOBBlock(ab) -> blockMayEscapeLoop(ab, label, nested)
        }
        if inBody {
          return true
        }
        i = i + 1
      }
      false
    }
    case EBlock(blk) -> blockMayEscapeLoop(blk, label, nested)
    case EUnsafe(blk) -> blockMayEscapeLoop(blk, label, nested)
    case EForall(_, w, body) -> {
      val inW = match w { case None -> false; case Some(we) -> exprMayEscapeLoop(we, label, nested) }
      inW or exprMayEscapeLoop(body, label, nested)
    }
    case EExists(_, w, body) -> {
      val inW = match w { case None -> false; case Some(we) -> exprMayEscapeLoop(we, label, nested) }
      inW or exprMayEscapeLoop(body, label, nested)
    }
  }
}

func stmtMayEscapeLoop(stmt: in Statement, label: in Option[String], nested: in Bool): Bool {
  match stmt.kind {
    case SBreak(bl) -> breakTargetsLoop(bl, label, nested)
    case SContinue(_) -> false
    case SReturn(_) -> false
    case SThrow(e) -> exprMayEscapeLoop(e, label, nested)
    case SInvariant(e) -> exprMayEscapeLoop(e, label, nested)
    case SItem(_) -> false
    case SExpr(e) -> exprMayEscapeLoop(e, label, nested)
    case SAssign(t, _, v) -> exprMayEscapeLoop(t, label, nested) or exprMayEscapeLoop(v, label, nested)
    case SRule(l, r) -> exprMayEscapeLoop(l, label, nested) or exprMayEscapeLoop(r, label, nested)
    case SLocal(binding) -> match binding {
      case LBVal(_, _, e) -> exprMayEscapeLoop(e, label, nested)
      case LBLet(_, _, e) -> exprMayEscapeLoop(e, label, nested)
      case LBVar(_, _, Some(e)) -> exprMayEscapeLoop(e, label, nested)
      case LBVar(_, _, None) -> false
    }
    case STry(body, catches, finally_) -> {
      if blockMayEscapeLoop(body, label, nested) {
        return true
      }
      var i = 0
      while i < catches.count {
        if blockMayEscapeLoop(catches[i].body, label, nested) {
          return true
        }
        i = i + 1
      }
      match finally_ {
        case None -> false
        case Some(fb) -> blockMayEscapeLoop(fb, label, nested)
      }
    }
    case SDefer(b) -> blockMayEscapeLoop(b, label, nested)
    case SScope(_, b) -> blockMayEscapeLoop(b, label, nested)
    case SLoop(_, b) -> blockMayEscapeLoop(b, label, true)
    case SFor(_, _, iter, body) -> exprMayEscapeLoop(iter, label, nested) or blockMayEscapeLoop(body, label, true)
    case SWhile(_, cond, body) -> exprMayEscapeLoop(cond, label, nested) or blockMayEscapeLoop(body, label, true)
  }
}

// Is `cond` the literal `true` (directly, or parenthesised)?  Used to
// recognise `while true { }` as an unconditional loop for divergence
// purposes; any other condition — including a `val` bound to `true` — is not
// statically known here and is left alone (#6602).
func isStaticallyTrueCond(cond: in Expr): Bool {
  match cond.kind {
    case ELiteral(lit) -> match lit { case LBool(v) -> v; case _ -> false }
    case EParen(inner) -> isStaticallyTrueCond(inner)
    case _ -> false
  }
}

// A statement after which control never falls through to a block value: an
// explicit `return`/`throw`, a loop `break`/`continue` (which transfers out
// of the enclosing loop), or an unconditional loop (`loop { }` / a
// statically-`true` `while`) whose body has no `break` that could escape it —
// such a loop only exits via `return`/`throw`/an outer `break`, so it never
// falls through either (#6602).  A block whose last statement is one of these
// has type `Never` (bottom), so it unifies cleanly as a branch — `if c {
// return x } else { y }` is typed by its `else` branch rather than
// false-mismatching `Unit` vs the value type.  A trailing `SExpr` of type
// `Never` (e.g. `panic(...)`) is already captured by `lastExprType`, so it is
// not listed here.
func statementDiverges(stmt: in Statement): Bool {
  match stmt.kind {
    case SReturn(_) -> true
    case SThrow(_) -> true
    case SBreak(_) -> true
    case SContinue(_) -> true
    // #3362 fallout: `scope { ... }` is a bare statement (not an `SExpr`), so
    // `checkBlock`'s generic `case _ ->` catch-all types it as a plain `Unit`
    // statement and never asks whether its OWN body unconditionally returns.
    // Before #3362 that didn't matter: a function body ending in
    // `scope { …; return x }` computed `bodyType = Unit`, and
    // `checkFunctionBody`'s old (buggy) guard skipped T0070 whenever the
    // *inferred* body type happened to be `Unit` — silently accepting the
    // Unit misclassification along with every genuine mismatch #3362 fixes.
    // Removing that blanket bypass exposed this: a function declared to
    // return e.g. `Int` whose body is just such a scope now (correctly)
    // needs the block to type as `Never`, not `Unit`, or T0070 false-fires.
    // Recursing on the scope body's own trailing statement mirrors exactly
    // the divergence check `checkBlock`'s tail already applies to an
    // ordinary block, so a `scope { ...; return x }` — the shape several
    // `async_spawn_self_test.l` helpers use — now correctly diverges.
    case SScope(_, body) -> body.statements.count > 0 and statementDiverges(body.statements[body.statements.count - 1])
    // #6602: an unconditional loop (`do { }`) or a statically-true `while`
    // whose body has no `break` that could escape it only exits via
    // `return`/`throw`/an outer `break`, so it never falls through either.
    case SLoop(label, body) -> not blockMayEscapeLoop(body, label, false)
    case SWhile(label, cond, body) -> isStaticallyTrueCond(cond) and not blockMayEscapeLoop(body, label, false)
    case _ -> false
  }
}

// #2355 / #3262: emit T0067 when a value-position `try` handler's type can
// neither satisfy nor be satisfied by the body type.  Never (a diverging
// handler), TyError (an already-reported failure), and an Int/Long
// literal-widening pair are absorbed — the same leniencies `unifyBranchTypes`
// applies to `if`/`match` branches.
//
// Unit leniency is asymmetric and depends on whether the `try`'s value is
// actually consumed (`handlerInValuePos`):
//   - A Unit *body* means the `try` produces nothing on the happy path, so a
//     non-Unit handler cannot create a value-position mismatch; always absorbed.
//   - A Unit *handler* beside a non-Unit body is only safe in statement
//     position (the value is discarded).  In value position the shared codegen
//     temp would be left unassigned when the catch fires (#3262), so the Unit
//     handler must raise T0067 there rather than being silently absorbed.
func checkTryHandlerType(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  bodyTy: in Type,
  handlerTy: in Type,
  handlerInValuePos: in Bool,
  span: in Span,
): Unit {
  if isNeverType(handlerTy) or isNeverType(bodyTy) {
    return
  }
  val anyError = match handlerTy {
    case TyError -> true
    case _ -> match bodyTy { case TyError -> true; case _ -> false }
  }
  if anyError {
    return
  }
  if isUnitType(bodyTy) {
    return
  }
  if isUnitType(handlerTy) and not handlerInValuePos {
    return
  }
  if argSatisfiesParam(tbl, bodyTy, handlerTy) or argSatisfiesParam(tbl, handlerTy, bodyTy) {
    return
  }
  match mergeIntWiden(bodyTy, handlerTy) {
    case Some(_) -> {
      return
    }
    case None -> {
    }
  }
  diag.add(
    errorDiagnostic(
      "T0067",
      "catch handler type " + renderType(handlerTy) + " is incompatible with try body type " + renderType(bodyTy),
      span
    )
  )
}

// `valuePos` is true when the trailing value of this block flows out to a
// consumer that requires a value of a known type (a `val`/`let`/`var`
// initialiser, a function body with a non-Unit return type, an `if`/`match`
// value arm, or a value-position `{ … }` / `try` expression).  It governs the
// asymmetric Unit-handler leniency in `checkTryHandlerType` (#3262): only a
// genuinely statement-position `try` may absorb a Unit handler beside a
// non-Unit body.  Statement-position callers (loop / catch / finally bodies)
// pass false.
//
// #7696: `tailExpected` is a SEPARATE signal from `returnTy` — `returnTy` is
// always the enclosing function's declared return type (used for every
// nested `return`'s T0065 check, regardless of nesting), while
// `tailExpected` is the type to check this block's trailing value against,
// and is `TyError` ("no expectation") unless that value is genuinely,
// structurally the enclosing function's return value (reached via
// `checkFunctionBody`'s own top-level call, or a same-chain continuation:
// a nested `{ }`/`unsafe { }`/`try`/`if`/`match` in tail position), or the
// value of a position with its own declared type (#7752: a block/`if`/`match`
// reached through `inferExprExpected` — an annotated binding, a `return`, a
// call argument, …). A block reached any other way (a loop/catch/finally
// body, an unannotated binding initialiser, …) passes `TyError` so a
// literal keeps inferring as `slice[T]` there, exactly as before — using the
// caller's unrelated `returnTy` for this would let the checker accept a
// literal's representation based on a type the codegen call site cannot see
// (docs/decisions/D-progress-1026-return-position-list-literals.md).
pub func checkBlock(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  genericNames: in List[String],
  returnTy: in Type,
  returnTyExpr: in Option[TypeExpr],
  diag: in List[Diagnostic],
  blk: in Block,
  valuePos: in Bool,
  tailExpected: in Type,
): Type {
  scopePush(sc)
  var lastExprType: Type = TyPrim(pt = PtUnit)
  var i = 0
  while i < blk.statements.count {
    val stmt = blk.statements[i]
    match stmt.kind {
      case SExpr(e) -> {
        // A brace / `unsafe` block used as a statement-expression carries the
        // enclosing block's value-position only at the trailing statement;
        // route it through `checkBlock` directly so a non-trailing block's
        // value is correctly treated as discarded (#3262).  An `if`/`match`
        // used as a statement-expression needs the same treatment (#3362):
        // route through `inferIfExpr`/`inferMatchExpr` directly with the
        // real value-position so a lone Unit-typed branch is absorbed
        // silently when the value is discarded, matching the pre-#3362
        // behaviour, but raises T0067 when this statement is actually the
        // block's trailing (consumed) expression.  All other expression
        // forms type via `inferExpr` (always value position — #3362).
        val isLast = i == blk.statements.count - 1
        // #7696: this statement's own tail-expected type — `tailExpected`
        // only when it is genuinely both value-position AND trailing, `TyError`
        // otherwise, exactly like every other tail-chain continuation below.
        val stmtTailExpected = if valuePos and isLast { tailExpected } else { TyError }
        match e.kind {
          case EBlock(innerBlk) -> {
            lastExprType = checkBlock(
              sc,
              tbl,
              sigs,
              genericNames,
              returnTy,
              returnTyExpr,
              diag,
              innerBlk,
              valuePos and isLast,
              stmtTailExpected
            )
          }
          case EUnsafe(innerBlk) -> {
            lastExprType = checkBlock(
              sc,
              tbl,
              sigs,
              genericNames,
              returnTy,
              returnTyExpr,
              diag,
              innerBlk,
              valuePos and isLast,
              stmtTailExpected
            )
          }
          case EIf(cond, thenBranch, elseBranch, _) -> {
            lastExprType = inferIfExpr(
              sc,
              tbl,
              sigs,
              diag,
              e,
              cond,
              thenBranch,
              elseBranch,
              valuePos and isLast,
              stmtTailExpected
            )
          }
          case EMatch(scrutinee, arms) -> {
            lastExprType = inferMatchExpr(sc, tbl, sigs, diag, e, scrutinee, arms, valuePos and isLast, stmtTailExpected)
          }
          case _ -> {
            lastExprType = if valuePos and isLast {
              inferExprExpected(sc, tbl, sigs, diag, e, tailExpected)
            } else {
              inferExpr(sc, tbl, sigs, diag, e)
            }
          }
        }
      }
      // Codegen lowers value-position try via a shared temp — type the expression as the body (or first handler if body is Never).
      case STry(body, catches, fin) -> {
        // The `try` value is consumed only when the enclosing block is in value
        // position *and* this is the trailing statement; otherwise the value is
        // discarded (#3262).
        val tryValuePos = valuePos and i == blk.statements.count - 1
        // #7696: same "tail chain continues" reasoning as above — a
        // value-position, trailing `try`'s own body/handler literal can still
        // be the function's return value.
        val tryTailExpected = if tryValuePos { tailExpected } else { TyError }
        var resultTy = checkBlock(
          sc,
          tbl,
          sigs,
          genericNames,
          returnTy,
          returnTyExpr,
          diag,
          body,
          tryValuePos,
          tryTailExpected
        )
        var ci = 0
        while ci < catches.count {
          val c = catches[ci]
          scopePush(sc)
          match c.bindName {
            case None -> {
            }
            case Some(bname) -> {
              scopeAdd(sc, LocalBinding(name = bname, ty = TyException, isMutable = false))
            }
          }
          checkNoYieldInHandler(diag, c.body, "a `catch` block", c.span)
          val hTy = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, c.body, tryValuePos, tryTailExpected)
          scopePop(sc)
          if typeEquiv(resultTy, TyPrim(pt = PtNever)) {
            resultTy = hTy
          } else {
            // #2355: codegen routes the body and every handler through one
            // shared temp, so a non-diverging handler must produce a value
            // compatible with the body type.  Never/TyError and a Unit body
            // stay lenient, mirroring `unifyBranchTypes`; a Unit handler beside
            // a non-Unit body is only absorbed in statement position (#3262).
            checkTryHandlerType(tbl, diag, resultTy, hTy, tryValuePos, c.span)
          }
          ci = ci + 1
        }
        match fin {
          case None -> {
          }
          case Some(fb) -> {
            // The `finally` block's value is always discarded.
            checkNoYieldInHandler(diag, fb, "a `finally` block", fb.span)
            val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, fb, false, TyError)
          }
        }
        lastExprType = resultTy
      }
      // #6603: `scope { }`'s own value is always discarded (it is a
      // structured-concurrency grouping construct, not a value-producing
      // block — mirrors `checkStatement`'s `false` here), but the checked
      // body type still carries `Never` when every path through it diverges
      // (e.g. `scope { if c { return x } else { return y } }`).  Capturing
      // that into `lastExprType` — instead of routing purely through the
      // syntax-only `statementDiverges` check, which has no `SScope` case —
      // lets a trailing `scope` correctly propagate divergence to the
      // enclosing block instead of defaulting to `Unit`.
      case SScope(_, body) -> {
        val bodyTy = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, body, false, TyError)
        val isNever = match bodyTy { case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }; case _ -> false }
        lastExprType = if isNever { bodyTy } else { TyPrim(pt = PtUnit) }
      }
      case _ -> {
        checkStatement(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, stmt)
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
    if segs.count == 1 and segs[0] == "externTarget" {
      return true
    }
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
      if segs[0] == "externStatic" {
        hasStatic = true
      }
      if segs[0] == "externInstance" {
        hasInstance = true
      }
    }
    i = i + 1
  }
  hasStatic and hasInstance
}

// T0086: sound never-assigned subset only; full all-paths definite-assignment is a follow-up.
func addAssignedTarget(target: in Expr, acc: in List[String]): Unit {
  match target.kind {
    case EPath(p) -> if p.segments.count == 1 { acc.add(p.segments[0]) }
    case EParen(inner) -> addAssignedTarget(inner, acc)
    case _ -> {
    }
  }
}

func collectAssignedExpr(e: in Expr, acc: in List[String]): Unit {
  match e.kind {
    case EAssign(t, _, v) -> {
      addAssignedTarget(t, acc)
      collectAssignedExpr(v, acc)
    }
    case EParen(inner) -> collectAssignedExpr(inner, acc)
    case EIf(c, tb, eb, _) -> {
      collectAssignedExpr(c, acc)
      collectAssignedEOB(tb, acc)
      match eb {
        case Some(x) -> collectAssignedEOB(x, acc)
        case None -> {
        }
      }
    }
    case EMatch(s, arms) -> {
      collectAssignedExpr(s, acc)
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(g) -> collectAssignedExpr(g, acc)
          case None -> {
          }
        }
        collectAssignedEOB(arms[i].body, acc)
        i = i + 1
      }
    }
    case EBlock(b) -> collectAssignedBlock(b, acc)
    case EUnsafe(b) -> collectAssignedBlock(b, acc)
    case EBinop(_, l, r) -> {
      collectAssignedExpr(l, acc)
      collectAssignedExpr(r, acc)
    }
    case EPrefix(_, x) -> collectAssignedExpr(x, acc)
    case ECall(f, args) -> {
      collectAssignedExpr(f, acc)
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(ae) -> {
            // A bare variable passed as a call argument may bind an `out`/`inout`
            // parameter of the callee (`writeVia(dst: out Int) { writeRaw(dst) }`),
            // which assigns it.  This syntax-only walker has no symbol table to
            // resolve the callee's parameter modes, so credit the argument as a
            // potential assignment — same deliberate false-negative trade-off as
            // the ELambda carve-out below; a truly never-mentioned out param is
            // still flagged.
            addAssignedTarget(ae, acc)
            collectAssignedExpr(ae, acc)
          }
          case CANamed(_, ae, _) -> {
            addAssignedTarget(ae, acc)
            collectAssignedExpr(ae, acc)
          }
        }
        i = i + 1
      }
    }
    case EMember(r, _) -> collectAssignedExpr(r, acc)
    case EIndex(r, idx) -> {
      collectAssignedExpr(r, acc)
      var i = 0
      while i < idx.count {
        collectAssignedExpr(idx[i], acc)
        i = i + 1
      }
    }
    case EPropagate(x) -> collectAssignedExpr(x, acc)
    case EAwait(x) -> collectAssignedExpr(x, acc)
    case EYield(x) -> collectAssignedExpr(x, acc)
    case ESpawn(x) -> collectAssignedExpr(x, acc)
    case EOld(x) -> collectAssignedExpr(x, acc)
    case ETry(x) -> collectAssignedExpr(x, acc)
    case ETuple(xs) -> {
      var i = 0
      while i < xs.count {
        collectAssignedExpr(xs[i], acc)
        i = i + 1
      }
    }
    case EList(xs) -> {
      var i = 0
      while i < xs.count {
        collectAssignedExpr(xs[i], acc)
        i = i + 1
      }
    }
    case ELambda(_, b) -> collectAssignedBlock(b, acc)
    // Known false-negative: an assignment inside a lambda body suppresses T0086 even
    // if the lambda is never called before the function exits.  The alternative
    // (excluding ELambda) would false-positive valid capture-and-call patterns.
    case _ -> {
    }
  }
}

func collectAssignedEOB(eob: in ExprOrBlock, acc: in List[String]): Unit {
  match eob {
    case EOBExpr(e) -> collectAssignedExpr(e, acc)
    case EOBBlock(b) -> collectAssignedBlock(b, acc)
  }
}

func collectAssignedStmt(s: in Statement, acc: in List[String]): Unit {
  match s.kind {
    case SAssign(t, _, v) -> {
      addAssignedTarget(t, acc)
      collectAssignedExpr(v, acc)
    }
    case SLocal(b) -> match b {
      case LBVal(_, _, init) -> collectAssignedExpr(init, acc)
      case LBLet(_, _, init) -> collectAssignedExpr(init, acc)
      case LBVar(_, _, initOpt) -> match initOpt {
        case Some(e) -> collectAssignedExpr(e, acc)
        case None -> {
        }
      }
    }
    case SReturn(vo) -> match vo { case Some(e) -> collectAssignedExpr(e, acc); case None -> {  } }
    case SThrow(e) -> collectAssignedExpr(e, acc)
    case SExpr(e) -> collectAssignedExpr(e, acc)
    case SInvariant(e) -> collectAssignedExpr(e, acc)
    case SRule(l, r) -> {
      collectAssignedExpr(l, acc)
      collectAssignedExpr(r, acc)
    }
    case STry(body, catches, fin) -> {
      collectAssignedBlock(body, acc)
      var i = 0
      while i < catches.count {
        collectAssignedBlock(catches[i].body, acc)
        i = i + 1
      }
      match fin {
        case Some(fb) -> collectAssignedBlock(fb, acc)
        case None -> {
        }
      }
    }
    case SDefer(b) -> collectAssignedBlock(b, acc)
    case SScope(_, b) -> collectAssignedBlock(b, acc)
    case SFor(_, _, it, b) -> {
      collectAssignedExpr(it, acc)
      collectAssignedBlock(b, acc)
    }
    case SWhile(_, c, b) -> {
      collectAssignedExpr(c, acc)
      collectAssignedBlock(b, acc)
    }
    case SLoop(_, b) -> collectAssignedBlock(b, acc)
    case _ -> {
    }
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
    match sig.params[pi].mode {
      case PMOut -> {
        hasOut = true
      }
      case _ -> {
      }
    }
    pi = pi + 1
  }
  if not hasOut {
    return
  }
  val assigned: List[String] = newList()
  var bodyless = false
  match fn.body {
    case None -> {
      bodyless = true
    }
    case Some(b) -> match b {
      case FBBlock(blk) -> collectAssignedBlock(blk, assigned)
      case FBExpr(e) -> collectAssignedExpr(e, assigned)
    }
  }
  if bodyless {
    // body-less signatures (interface/extern decls): nothing to check; an empty
    // `assigned` list would otherwise false-flag every `out` param as T0086.
    return
  }
  var k = 0
  while k < sig.params.count {
    val p = sig.params[k]
    match p.mode {
      case PMOut -> if not listContainsStr(assigned, p.name) {
        diag.add(
          errorDiagnostic("T0086", "`out` parameter '" + p.name + "' is never assigned before the function returns", fn.span)
        )
      }
      case _ -> {
      }
    }
    k = k + 1
  }
}

// Contract clauses are type-checked against the function's own scope
// (parameters, and `result` as the declared return type through `EResult`),
// before elaboration turns them into asserts (#7228).  Before this an
// ill-typed clause type-checked silently and failed, or miscompiled, in
// codegen.
func checkContractClauses(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  contracts: in List[ContractClause],
): Unit {
  var i = 0
  while i < contracts.count {
    match contracts[i] {
      case CCRequires(e, sp) -> checkBoolClause(sc, tbl, sigs, diag, e, "requires", sp)
      case CCEnsures(e, sp) -> checkBoolClause(sc, tbl, sigs, diag, e, "ensures", sp)
      case CCWhen(e, sp) -> checkBoolClause(sc, tbl, sigs, diag, e, "when", sp)
      case CCDecreases(e, sp) -> {
        sc.contractDepth.add(0)
        val t = inferExpr(sc, tbl, sigs, diag, e)
        sc.contractDepth.removeAt(sc.contractDepth.count - 1)
        val lenient = match t { case TyError -> true; case _ -> false }
        if not isConcreteIntType(t) and not lenient {
          diag.add(errorDiagnostic("T0132", "a decreases: measure must be an integer (got " + renderType(t) + ")", sp))
        }
      }
      case CCRaises(_, _) -> ()
    }
    i = i + 1
  }
}

func checkBoolClause(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  e: in Expr,
  kind: in String,
  sp: in Span,
): Unit {
  sc.contractDepth.add(0)
  val t = inferExpr(sc, tbl, sigs, diag, e)
  sc.contractDepth.removeAt(sc.contractDepth.count - 1)
  if not typeEquiv(t, TyPrim(pt = PtBool)) {
    diag.add(errorDiagnostic("T0132", "a " + kind + ": clause must be Bool (got " + renderType(t) + ")", sp))
  }
}

pub func checkFunctionBody(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  fn: in FunctionDecl,
  sig: in ResolvedSignature,
  extraLocals: in List[LocalBinding],
  selfFieldLocals: in List[LocalBinding],
  selfChecked: in Bool,
  selfType: in Type,
): Unit {
  val valueGeneric = declHasValueGenerics(fn.generics)
  if valueGeneric {
    tbl.valueGenericBodies.add(1)
  }
  checkFunctionBodyAt(tbl, sigs, diag, fn, sig, extraLocals, selfFieldLocals, selfChecked, selfType)
  if valueGeneric {
    tbl.valueGenericBodies.removeAt(tbl.valueGenericBodies.count - 1)
  }
}

func declHasValueGenerics(generics: in Option[GenericParams]): Bool {
  match generics {
    case Some(gp) -> {
      for p in gp.params {
        match p {
          case GPValue(_, _, _) -> return true
          case _ -> ()
        }
      }
      false
    }
    case None -> false
  }
}

func checkFunctionBodyAt(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  fn: in FunctionDecl,
  sig: in ResolvedSignature,
  extraLocals: in List[LocalBinding],
  selfFieldLocals: in List[LocalBinding],
  selfChecked: in Bool,
  selfType: in Type,
): Unit {
  if hasExternTargetAnnotation(fn.annotations) {
    // F0002: both @externStatic and @externInstance on one extern.
    if hasConflictingExternHints(fn.annotations) {
      diag.add(
        errorDiagnostic(
          "F0002",
          "function '" + fn.name + "' has both @externStatic and " + "@externInstance — pick one (the FFI resolver cannot " +
            "honour both, and will fall back to @externStatic)",
          fn.span
        )
      )
    }
    return
  }

  // #6485/#6487: `self.field` — the explicit-receiver spelling of the same
  // bare-name field access #6481 seeded below — never resolves through a
  // scope lookup (`self` is a keyword; every occurrence parses to the
  // dedicated `ESelf` AST node, never `EPath(["self"])`), so it needs its own
  // map keyed by field name.  Built from `selfFieldLocals`, a list decoupled
  // from `extraLocals` so a caller can seed the `self.`-map independently of
  // (or identically to, as every current caller does — #6487's review found
  // record/impl bodies need bare-name field access too, #6173) the bare-name
  // scope bindings below.
  val selfFields: Map[String, Type] = newMap()
  var sf = 0
  while sf < selfFieldLocals.count {
    selfFields.add(selfFieldLocals[sf].name, selfFieldLocals[sf].ty)
    sf = sf + 1
  }
  // #6467: `fn.ret` also seeds the scope's `returnTyExpr`, so T0064/T0065
  // (raised deep inside a nested block via `checkStatement`) render the same
  // alias-aware display as T0070/T0114 below.
  val sc = newScopeForFunction(sig.returnTy, sig.generics, fn.ret, selfFields, selfChecked, selfType)
  // #6481/#6487: a member body (protected `entry`/`func`, a record-body
  // method, or an impl method — #6173) reads/writes the enclosing type's
  // fields as bare names (the implicit-`self` idiom every one of these
  // supports, regardless of whether the member kind ALSO carries an
  // explicit `self` param); the caller seeds those bindings here so a bare
  // `count = count + 1` resolves — and so writing a `let`/immutable field
  // trips the SAME `isMutable`-driven T0087 the ordinary val/let-reassignment
  // check already gives locals, with no separate mode-checker rule needed.
  // Seeded BEFORE params so a param name shadows a same-named field
  // (last-added wins in `scopeTryFind`), matching ordinary inner-scope-
  // shadows-outer precedent.  Empty for plain top-level functions.
  var el = 0
  while el < extraLocals.count {
    scopeAdd(sc, extraLocals[el])
    el = el + 1
  }
  // #6418: `fn.ret` is the ORIGINAL (pre-erasure) return-type annotation —
  // `Lyric.TypeAliasResolve` runs before this checker, so `fn.ret`'s
  // `TypeExpr` (when present) already carries `aliasName` if the user wrote
  // an alias here. `sig.returnTy` is the resolved `Type` this whole function
  // checks against; render the two together once, reused by every
  // declared-return-type diagnostic below instead of re-deriving it per site.
  val declaredReturnTyStr = match fn.ret {
    case Some(rte) -> renderTypeExpr(rte, sig.returnTy)
    case None -> renderType(sig.returnTy)
  }
  // A value generic parameter (`N: Nat`) is an `Int` constant in the body;
  // each specialisation substitutes its bound value (D167 item 6).
  for vp in valueGenericNames(fn.generics) {
    scopeAdd(sc, LocalBinding(name = vp, ty = TyPrim(pt = PtInt), isMutable = false))
  }
  var i = 0
  while i < sig.params.count {
    val p = sig.params[i]
    val isMut = match p.mode { case PMIn -> false; case _ -> true }
    scopeAdd(sc, LocalBinding(name = p.name, ty = p.ty, isMutable = isMut))
    i = i + 1
  }

  // #5603: a concrete function with a non-Unit return type must have a body
  // that can produce a value — an absent body (`body: None` parses fine and
  // codegen emits nothing, so the function returns garbage at runtime) or an
  // empty block is a hard error.  Legitimately body-less forms stay exempt:
  // `@axiom` functions (checked here), `@externTarget` externs (early return
  // above), `extern func` / interface method signatures (different item
  // kinds, never routed through this function).  A `TyError` return type is
  // already diagnosed at the declaration; skip to avoid a cascade.
  val returnNeedsBody = not isUnitType(sig.returnTy) and (match sig.returnTy { case TyError -> false; case _ -> true }) and
    not fnHasAnnotation(fn, "axiom")
  if returnNeedsBody {
    val bodyMissing = match fn.body {
      case None -> true
      case Some(b0) -> match b0 {
        case FBBlock(blk0) -> blk0.statements.count == 0
        case FBExpr(_) -> false
      }
    }
    if bodyMissing {
      diag.add(
        errorDiagnostic(
          "T0114",
          "function '" + fn.name + "' declares return type " + declaredReturnTyStr +
            " but has no body that produces a value (only @axiom functions, externs, and interface method signatures may omit the body)",
          fn.span
        )
      )
    }
  }

  checkLoopLabels(diag, fn)
  checkContractClauses(sc, tbl, sigs, diag, fn.contracts)

  match fn.body {
    case None -> {
    }
    case Some(body) -> match body {
      case FBExpr(e) -> {
        // #7696: an expression-bodied function's body IS its return value —
        // type a bracket literal directly against `sig.returnTy`, matching
        // `return`/the block-body tail below (docs/decisions/
        // D-progress-1026-return-position-list-literals.md).
        val bodyType = inferExprExpected(sc, tbl, sigs, diag, e, sig.returnTy)
        val isNever = match bodyType {
          case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }
          case _ -> false
        }
        // #6641 fallout: see the matching FBBlock-case comment below — a
        // generator's declared return type is its yielded element type,
        // not what its body's own control flow must produce.
        if not sig.isGenerator {
          recordWideningSite(tbl, sig.returnTy, bodyType, e, false)
        }
        if not isNever and not sig.isGenerator and not typeAssignable(tbl, sig.returnTy, bodyType) and not numericWidensTo(sig.returnTy, bodyType) {
          diag.add(
            errorDiagnostic(
              "T0070",
              "function body " + hasTypeOrEmptyLiteral(bodyType, e) + " but declared return type is " + declaredReturnTyStr +
                typeMismatchHint(tbl, sig.returnTy, bodyType),
              fn.span
            )
          )
        }
      }
      case FBBlock(blk) -> {
        val bodyValuePos = not isUnitType(sig.returnTy)
        // #7696: `sig.returnTy` doubles as `tailExpected` here — this is the
        // ROOT of the tail chain `checkBlock`/`inferIfExpr`/`inferMatchExpr`
        // thread it through (see `checkBlock`'s header comment). Passing it
        // unconditionally is safe even when `bodyValuePos` is false (a Unit
        // return type never matches the `List[T]`-shaped gate those sites
        // check for).
        val bodyType = checkBlock(sc, tbl, sigs, sig.generics, sig.returnTy, fn.ret, diag, blk, bodyValuePos, sig.returnTy)
        val isNever = match bodyType {
          case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }
          case _ -> false
        }
        // #3362: compare `bodyType` against the DECLARED `sig.returnTy`
        // unconditionally (modulo the `Never`/bottom-type exception above).
        // This used to also skip whenever the *inferred* `bodyType` was
        // Unit — but that checked the wrong type (whether the body matched
        // itself, trivially true, instead of whether it matched the
        // declared return type), so a function declared to return a
        // non-Unit type whose trailing `if`/`match` produced Unit on one
        // arm (and a real value on the other, itself now flagged by
        // `unifyBranchTypes`'s value-position check) compiled with zero
        // diagnostics. `typeAssignable` already accepts a genuinely
        // Unit-returning function whose body is Unit, so removing the
        // bypass does not regress that case.
        //
        // #6641 fallout (found by CI, not filed as a separate issue): an
        // `async func`'s declared return type is the GENERATOR'S YIELDED
        // ELEMENT type when `sig.isGenerator` (the body contains a `yield`),
        // not the type its control-flow body must literally produce —
        // `async func evens(n: Int): Int { var i = 0; while i < n { yield
        // i * 2; i = i + 1 } }` never "returns" an `Int` via normal
        // fall-through at all; each `yield` is separately checked against
        // the element type by `EYield`'s own handling above. The old
        // blanket Unit-body bypass this section's #3362 fix removed
        // happened to also exempt generators (a `while`-loop body infers
        // `Unit`); removing it without a principled generator exemption
        // reopened this as a false-positive T0070 on every generator whose
        // body's own control-flow type isn't the element type — check
        // `sig.isGenerator` explicitly instead of relying on that accident.
        if not sig.isGenerator {
          match blockValueExpr(blk) {
            case Some(tailE) -> recordWideningSite(tbl, sig.returnTy, bodyType, tailE, false)
            case None -> ()
          }
        }
        if not isNever and not sig.isGenerator and not typeAssignable(tbl, sig.returnTy, bodyType) and not numericWidensTo(sig.returnTy, bodyType) {
          diag.add(
            errorDiagnostic(
              "T0070",
              "function body trailing expression has type " + renderType(bodyType) + " but declared return type is " +
                declaredReturnTyStr +
                typeMismatchHint(tbl, sig.returnTy, bodyType),
              fn.span
            )
          )
        }
      }
    }
  }
  checkOutDefiniteAssignment(diag, fn, sig)
}

// #7778: a local `val` binds its pattern with no failure path -- codegen
// destructures the initializer unconditionally -- so the pattern must match
// every value of the initializer's type (the local counterpart of the
// module-level T0144, #7763).  Returns what makes `pat` fail to, or "" when
// it always matches: a tuple pattern needs a tuple type of its arity, a
// constructor pattern the sole case of a single-case union, and a record
// pattern a head naming the initializer's own record, only that record's
// fields and only irrefutable field patterns -- codegen casts to the head's
// record and reads each field unconditionally (#7808); a literal, range, type-test,
// alternative or const pattern can always fail.  A type the checker could
// not resolve (`TyError`, a type parameter, `Never`) cannot rule a shape out,
// so only the pattern's own refutable forms count under it.
func localValPatternProblem(tbl: in SymbolTable, pat: in Pattern, ty: in Type): String {
  match pat.kind {
    case PWildcard -> ""
    case PError -> ""
    case PBinding(_, inner) -> match inner { case Some(ip) -> localValPatternProblem(tbl, ip, ty); case None -> "" }
    case PParen(ip) -> localValPatternProblem(tbl, ip, ty)
    case PTuple(ps) -> {
      val t = unrefine(ty)
      if localValShapeUnknown(t) {
        return localValElemsProblem(tbl, ps, newList())
      }
      match t {
        case TyTuple(elems) -> if elems.count == ps.count {
          localValElemsProblem(tbl, ps, elems)
        } else {
          "a " + toString(ps.count) + "-element tuple pattern is bound to a value of type " + renderType(ty)
        }
        case _ -> "a " + toString(ps.count) + "-element tuple pattern is bound to a value of type " + renderType(ty)
      }
    }
    case PRecord(head, fields, _) -> {
      val t = unrefine(ty)
      if localValShapeUnknown(t) {
        return localValRecordFieldsProblem(tbl, fields, newList(), false, ty)
      }
      val headName = if head.segments.count > 0 { head.segments[head.segments.count - 1] } else { "" }
      match t {
        case TyUser(tid, _, targs) -> {
          if localValRecordHeadNames(tbl, headName, tid) {
            localValRecordFieldsProblem(tbl, fields, fieldsOfRecordInstantiated(tbl, tid, targs), true, ty)
          } else {
            "a record pattern (`" + headName + " { ... }`) is bound to a value of type " + renderType(ty)
          }
        }
        case _ -> "a record pattern (`" + headName + " { ... }`) is bound to a value of type " + renderType(ty)
      }
    }
    case PConstructor(head, args) -> {
      val t = unrefine(ty)
      if localValShapeUnknown(t) {
        return localValElemsProblem(tbl, args, newList())
      }
      val caseName = if head.segments.count > 0 { head.segments[head.segments.count - 1] } else { "" }
      match finiteCaseNames(tbl, t) {
        case Some(names) -> {
          if names.count != 1 or names[0] != caseName {
            return "a constructor pattern (`" + caseName + "`), which matches only one case of " + renderType(ty) +
              "; destructure it with a `match` instead"
          }
          val scratch: List[Diagnostic] = newList()
          val fieldTys: List[Type] = match unionCaseSymbolForScrutinee(tbl, scratch, pat2fnExpr(head, pat.span), t) {
            case Some(caseSym) -> caseFieldTypesInstantiated(tbl, scratch, caseSym, t)
            case None -> newList()
          }
          localValElemsProblem(tbl, args, fieldTys)
        }
        case None -> "a constructor pattern (`" + caseName + "`) is bound to a value of type " + renderType(ty) +
          ", which has no cases"
      }
    }
    case _ -> refutablePatternForm(pat) + ", which can fail to match" + localValRefutableHint(pat)
  }
}

func localValRefutableHint(p: in Pattern): String {
  match p.kind {
    case PTypeTest(inner, _) -> match inner.kind {
      case PBinding(_, None) -> "; declare the type with `val <name>: <Type> = ...` instead"
      case _ -> "; destructure it with a `match` instead"
    }
    case _ -> "; destructure it with a `match` instead"
  }
}

// The first problem among `ps` bound to `tys` element-wise (an element with
// no type is checked against `TyError`), or "".
func localValElemsProblem(tbl: in SymbolTable, ps: in List[Pattern], tys: in List[Type]): String {
  var i = 0
  while i < ps.count {
    val problem = localValPatternProblem(tbl, ps[i], if i < tys.count { tys[i] } else { TyError })
    if problem.length > 0 {
      return problem
    }
    i = i + 1
  }
  ""
}

// True when a record pattern's head `headName` names the record `tid` itself
// (its declared or exposed record symbol); the head's qualifier, privacy and
// reachability are `checkLocalValRecordHeads`'s to report once the pattern's
// shape is known to fit.
func localValRecordHeadNames(tbl: in SymbolTable, headName: in String, tid: in TypeId): Bool {
  for cand in symTableTryFindAll(tbl, headName) {
    val hit = match cand.kind {
      case DKRecord(did, _) -> typeIdEq(did, tid)
      case DKExposedRec(did, _) -> typeIdEq(did, tid)
      case _ -> false
    }
    if hit {
      return true
    }
  }
  false
}

// The first problem among a record pattern's fields.  When the record is
// known (`known`), every named and shorthand field must be one of its fields;
// codegen reads each unconditionally.
func localValRecordFieldsProblem(
  tbl: in SymbolTable,
  fields: in List[RecordPatternField],
  recFields: in List[FieldEntry],
  known: in Bool,
  ty: in Type,
): String {
  for f in fields {
    val fname = match f { case RPFNamed(n, _, _) -> n; case RPFShort(n, _) -> n }
    if known and not localValRecordHasField(recFields, fname) {
      return "the record pattern names field `" + fname + "`, which " + renderType(ty) + " does not have"
    }
    match f {
      case RPFNamed(_, fp, _) -> {
        val problem = localValPatternProblem(tbl, fp, fieldEntryType(recFields, fname))
        if problem.length > 0 {
          return problem
        }
      }
      case RPFShort(_, _) -> ()
    }
  }
  ""
}

func localValRecordHasField(recFields: in List[FieldEntry], name: in String): Bool {
  for fe in recFields {
    if fe.name == name {
      return true
    }
  }
  false
}

// The record-pattern head diagnostics a `match` arm gets from
// `bindPatternTyped` (T0137 qualifier, T0097 privacy, T0020 reachability),
// for a local `val` pattern `localValPatternProblem` accepted.
func checkLocalValRecordHeads(tbl: in SymbolTable, diag: in List[Diagnostic], pat: in Pattern, ty: in Type): Unit {
  match pat.kind {
    case PBinding(_, inner) -> match inner {
      case Some(ip) -> checkLocalValRecordHeads(tbl, diag, ip, ty)
      case None -> ()
    }
    case PParen(ip) -> checkLocalValRecordHeads(tbl, diag, ip, ty)
    case PTuple(ps) -> {
      val elems = match unrefine(ty) { case TyTuple(es) -> es; case _ -> newList() }
      var i = 0
      while i < ps.count {
        checkLocalValRecordHeads(tbl, diag, ps[i], if i < elems.count { elems[i] } else { TyError })
        i = i + 1
      }
    }
    case PRecord(head, fields, _) -> {
      checkRecordPatternHead(tbl, diag, head, pat.span, ty)
      val recFields: List[FieldEntry] = match unrefine(ty) {
        case TyUser(tid, _, targs) -> fieldsOfRecordInstantiated(tbl, tid, targs)
        case _ -> newList()
      }
      for f in fields {
        match f {
          case RPFNamed(fname, fp, _) -> checkLocalValRecordHeads(tbl, diag, fp, fieldEntryType(recFields, fname))
          case RPFShort(_, _) -> ()
        }
      }
    }
    case PConstructor(head, args) -> {
      val t = unrefine(ty)
      val scratch: List[Diagnostic] = newList()
      val fieldTys: List[Type] = if localValShapeUnknown(t) {
        newList()
      } else {
        match unionCaseSymbolForScrutinee(tbl, scratch, pat2fnExpr(head, pat.span), t) {
          case Some(caseSym) -> caseFieldTypesInstantiated(tbl, scratch, caseSym, t)
          case None -> newList()
        }
      }
      var i = 0
      while i < args.count {
        checkLocalValRecordHeads(tbl, diag, args[i], if i < fieldTys.count { fieldTys[i] } else { TyError })
        i = i + 1
      }
    }
    case _ -> ()
  }
}

func localValShapeUnknown(t: in Type): Bool {
  match t {
    case TyError -> true
    case TyVar(_) -> true
    case TySelf -> true
    case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }
    case _ -> false
  }
}

// Reports T0146 when a local `val`'s pattern cannot match every value of
// `ty`; true when it did, so the caller binds the pattern's names leniently
// instead of against a type they do not have.
func checkLocalValPattern(tbl: in SymbolTable, diag: in List[Diagnostic], pat: in Pattern, ty: in Type): Bool {
  match pat.kind {
    case PBinding(_, None) -> return false
    case _ -> ()
  }
  val problem = localValPatternProblem(tbl, pat, ty)
  if problem.length == 0 {
    checkLocalValRecordHeads(tbl, diag, pat, ty)
    return false
  }
  diag.add(
    errorDiagnostic(
      "T0146",
      "a local `val` pattern must match every value of its initializer (a `val` has no failure path), but " + problem,
      pat.span
    )
  )
  true
}

// The element type a `for` binds when it iterates a value of `iterType` (a
// range or a generator call is typed by the caller), or `TyError` after
// reporting T0126 when the value is not iterable (#7781).  The iterable types
// are the ones both backends lower: a slice or array, the stdlib `List[T]`
// and `Map[K, V]`'s key/value collections -- recognised by identity, never
// by their bare names (#7737) -- and extern types, whose iteration the host
// collection protocol (`IEnumerable` / `java.lang.Iterable`) decides at
// codegen; a single-type-parameter extern type iterates its type argument
// (the phantom-type-param idiom, e.g.
// `extern type JHttpStringCollection[T] = "java.util.Collection"`, #6565).
// Every other type -- a record, union, enum, opaque, protected, distinct or
// interface type of any arity, a primitive, a tuple, a function, a nullable
// value, the stdlib `Map` itself -- has no iteration lowering: codegen's
// fallback index-loop protocol casts it to a list and fails at runtime.
// Only a single-parameter one was rejected before (#6720); the others typed
// the loop variable `TyError`, which silenced every diagnostic involving it
// in the loop body.  An iterator whose own inference already failed
// (`TyError`), a type parameter and `Self` stay lenient: whether they are
// iterable is not decidable here.
func forIterElemType(tbl: in SymbolTable, diag: in List[Diagnostic], iter: in Expr, iterType: in Type): Type {
  match unrefine(iterType) {
    case TyError -> TyError
    case TyVar(_) -> TyError
    case TySelf -> TyError
    case TySlice(e) -> e
    case TyArray(_, e, _) -> e
    case TyUser(iterId, _, iterArgs) -> {
      if iterArgs.count == 1 and isStdCollectionsHostType(tbl, iterId, "List") {
        iterArgs[0]
      } else if iterArgs.count == 2 and isStdCollectionsHostType(tbl, iterId, "MapKeyCollection") {
        iterArgs[0]
      } else if iterArgs.count == 2 and isStdCollectionsHostType(tbl, iterId, "MapValueCollection") {
        iterArgs[1]
      } else if iterArgs.count == 2 and isStdCollectionsHostType(tbl, iterId, "Map") {
        reportNotIterable(
          diag,
          iter,
          "cannot iterate over '" + renderType(iterType) + "' directly: iterate `mapKeys(m)`, `mapValues(m)` or " +
            "`mapEntries(m)` from Std.Collections"
        )
      } else if symTableIsExternTypeId(tbl, iterId) {
        if iterArgs.count == 1 {
          iterArgs[0]
        } else {
          TyError
        }
      } else {
        reportNotIterable(
          diag,
          iter,
          "cannot iterate over '" + renderType(iterType) + "': not a recognized iterable type" +
            shadowedStdCollectionNote(tbl, iterType) +
            distinctIterNote(tbl, iterId)
        )
      }
    }
    case TyPrim(pt) -> match pt {
      case PtNever -> TyError
      // D-progress-1006: a `String`'s elements would have to be UTF-16 code
      // units, and a surrogate half is not a `Char` (docs/01 §2.1), so name
      // the two explicit views instead.
      case PtString -> reportNotIterable(
        diag,
        iter,
        "cannot iterate over 'String' directly: iterate its Unicode scalar values with " +
          "`for cp in Std.String.codePoints(s)` (each an `Int`), or index code units with " +
          "`s.codeUnitAt(i)` for `i` in `0 ..< s.length`"
      )
      case _ -> reportNotIterable(
        diag,
        iter,
        "cannot iterate over '" + renderType(iterType) +
          "': not a recognized iterable type"
      )
    }
    case _ -> reportNotIterable(
      diag,
      iter,
      "cannot iterate over '" + renderType(iterType) + "': not a recognized iterable type"
    )
  }
}

func reportNotIterable(diag: in List[Diagnostic], iter: in Expr, message: in String): Type {
  diag.add(errorDiagnostic("T0126", message, iter.span))
  TyError
}

// A note for T0126 on a distinct type: its value is a wrapper, not the
// underlying collection, so the loop has to name the underlying value.
func distinctIterNote(tbl: in SymbolTable, tid: in TypeId): String {
  match symTableTypeSymbolOf(tbl, tid) {
    case Some(sym) -> match sym.kind {
      case DKDistinctType(_, _) -> " (a distinct type is not its underlying type: iterate its `.value`)"
      case _ -> ""
    }
    case None -> ""
  }
}

// True when a `for` iterates a call to a yield-bearing `async func` (a
// generator): its call types as the declared element type, so a `String`
// generator's call looks like a `String` here (D-progress-1006's T0126 must
// not fire on it).  Decided by the signature the `ECall` arm bound the call
// to (`SymbolTable.generatorCallSites`), so it must be asked after `iter` is
// inferred.  A bare-name + arity lookup misread any same-named non-generator
// -- a method, a type-associated function, a shadowing local function value,
// another package's function -- as the generator (#7771).
func forIterIsGeneratorCall(tbl: in SymbolTable, iter: in Expr): Bool {
  match iter.kind {
    case ECall(_, _) -> tbl.generatorCallSites.containsKey(recordCopySiteKey(iter.span))
    case _ -> false
  }
}
