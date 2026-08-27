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
    case RBClosed(lo, hi) -> forRangeBoundsElemType(inferExpr(sc, tbl, sigs, diag, lo), inferExpr(sc, tbl, sigs, diag, hi))
    case RBHalfOpen(lo, hi) -> forRangeBoundsElemType(inferExpr(sc, tbl, sigs, diag, lo), inferExpr(sc, tbl, sigs, diag, hi))
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
    case TyRefined(_, lo, hi, inc) -> match exprLiteralLong(init) { case None -> {  }; case Some(v) -> { val belowLo = match lo { case None -> false; case Some(l) -> v < l }; val aboveHi = match hi { case None -> false; case Some(h) -> if inc { v > h } else { v >= h } }; if belowLo or aboveHi { diag.add(errorDiagnostic("T0015", "literal " + toString(v) + " is out of range for type " + renderType(declT), init.span)) } } }
    case _ -> {
    }
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
    case SLocal(binding) -> match binding { case LBVal(pat, tyOpt, init) -> match tyOpt { case None -> bindPattern(sc, pat, inferExpr(sc, tbl, sigs, diag, init)); case Some(te) -> { val ctx = newGenericContext(); gctxPush(ctx, genericNames); val declT = resolveType(tbl, ctx, diag, te); val initType = inferExprExpected(sc, tbl, sigs, diag, init, declT); if not argSatisfiesParam(tbl, declT, initType) { diag.add(errorDiagnostic("T0060", "val binding declared as " + renderTypeExpr(te, declT) + " but initialiser has type " + renderType(initType), stmt.span)) }; checkRefinedLiteralBound(declT, init, diag); bindPattern(sc, pat, declT) } }; case LBVar(name, tyOpt, initOpt) -> match tyOpt { case None -> { val initType = match initOpt { case None -> TyError; case Some(e) -> inferExpr(sc, tbl, sigs, diag, e) }; scopeAdd(sc, LocalBinding(name = name, ty = initType, isMutable = true)) }; case Some(te) -> { val ctx = newGenericContext(); gctxPush(ctx, genericNames); val declT = resolveType(tbl, ctx, diag, te); match initOpt { case Some(initE) -> { val initType = inferExprExpected(sc, tbl, sigs, diag, initE, declT); if not argSatisfiesParam(tbl, declT, initType) { diag.add(errorDiagnostic("T0061", "var binding declared as " + renderTypeExpr(te, declT) + " but initialiser has type " + renderType(initType), stmt.span)) }; checkRefinedLiteralBound(declT, initE, diag) }; case None -> {  } }; scopeAdd(sc, LocalBinding(name = name, ty = declT, isMutable = true)) } }; case LBLet(name, tyOpt, init) -> match tyOpt { case None -> scopeAdd(sc, LocalBinding(name = name, ty = inferExpr(sc, tbl, sigs, diag, init), isMutable = false)); case Some(te) -> { val ctx = newGenericContext(); gctxPush(ctx, genericNames); val declT = resolveType(tbl, ctx, diag, te); val initType = inferExprExpected(sc, tbl, sigs, diag, init, declT); if not argSatisfiesParam(tbl, declT, initType) { diag.add(errorDiagnostic("T0062", "let binding declared as " + renderTypeExpr(te, declT) + " but initialiser has type " + renderType(initType), stmt.span)) }; checkRefinedLiteralBound(declT, init, diag); scopeAdd(sc, LocalBinding(name = name, ty = declT, isMutable = false)) } } }

    case SAssign(target, op, value) -> {
      val targetType = inferExpr(sc, tbl, sigs, diag, target)
      val valueType = inferExpr(sc, tbl, sigs, diag, value)
      // `s += <rhs>` onto a String plain-variable target accepts any RHS type
      // (mirroring binary `+`); field/indexed String targets stay strict.  See
      // `isStringPlusVarAssign` (typechecker_exprs.l) for the full rationale
      // and the #5688 follow-up (#5657).
      val stringPlusAssign = isStringPlusVarAssign(target, op, targetType)
      if not stringPlusAssign and not argSatisfiesParam(tbl, targetType, valueType) {
        diag.add(
          errorDiagnostic(
            "T0063",
            "assigned value of type " + renderType(valueType) + " does not match target of type " + renderType(targetType),
            stmt.span
          )
        )
      }
      // #1487 (§5.2): an `in` parameter — like a `val`/`let` binding — is
      // immutable and cannot be reassigned.  The checker records this as
      // `isMutable = false` (in-params and val/let), so a simple-path
      // assignment whose target is an immutable binding is rejected (T0087).
      // `var` locals and `out`/`inout` params are mutable and unaffected.
      match target.kind {
        case EPath(p) -> if p.segments.count == 1 { match scopeTryFind(sc, p.segments[0]) { case Some(b) -> if not b.isMutable { diag.add(errorDiagnostic("T0087", t0087Msg(p.segments[0]), target.span)) }; case None -> {  } } }
        case _ -> {
        }
      }
    }

    case SReturn(valueOpt) -> match valueOpt { case None -> { if not typeEquiv(returnTy, TyPrim(pt = PtUnit)) { diag.add(errorDiagnostic("T0064", "return without value but enclosing function returns " + renderOptTypeExpr(returnTyExpr, returnTy), stmt.span)) } }; case Some(e) -> { val t = inferExpr(sc, tbl, sigs, diag, e); val isNever = match t { case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }; case _ -> false }; if not isNever and not typeAssignable(tbl, returnTy, t) { diag.add(errorDiagnostic("T0065", "returned value of type " + renderType(t) + " does not match declared return type " + renderOptTypeExpr(returnTyExpr, returnTy), stmt.span)) } } }

    case SThrow(e) -> {
      val _ = inferExpr(sc, tbl, sigs, diag, e)
    }

    case SBreak(_) -> {
    }
    case SContinue(_) -> {
    }

    case SInvariant(e) -> {
      val _ = inferExpr(sc, tbl, sigs, diag, e)
    }

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
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, body, false)
    }

    case SScope(_, body) -> {
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, body, false)
    }

    case SLoop(_, body) -> {
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, body, false)
    }

    case SFor(_, pat, iter, body) -> {
      // A range iterator is typed here, not in `inferExpr`'s `ERange` arm: the
      // parser only builds `ERange` in `for`-iterator position, so `for` is the
      // sole consumer of a range's element type and `ERange` itself can keep its
      // lenient `TyError` result (#1478 / docs/59 A1).  Typing the bounds also
      // checks them — before this they were never visited by the checker.
      val elemType = match iter.kind {
        case ERange(bound) -> forRangeElemType(sc, tbl, sigs, diag, bound)
        case _ -> {
          val iterType = inferExpr(sc, tbl, sigs, diag, iter)
          match iterType {
            case TySlice(e) -> e
            case TyArray(_, e) -> e
            case TyUser(_, iterName, iterArgs) -> {
              // List[T] iterates over T; MapKeyCollection[K,V] over K;
              // MapValueCollection[K,V] over V.  A bare `Map[K,V]` iterator has
              // no runtime lowering on either backend (iteration goes through
              // `.keys()` / `.values()`), so it stays `TyError` — codegen owns
              // that rejection.
              if iterName == "List" and iterArgs.count == 1 {
                iterArgs[0]
              } else if iterName == "MapKeyCollection" and iterArgs.count == 2 {
                iterArgs[0]
              } else if iterName == "MapValueCollection" and iterArgs.count == 2 {
                iterArgs[1]
              } else if iterArgs.count == 1 {
                // Any other single-type-parameter generic collection follows
                // the same List[T] convention: the sole type parameter IS the
                // element type.  This covers extern generic collections
                // (e.g. `extern type JHttpStringCollection[T] = "java.util.Collection"`,
                // the phantom-type-param idiom `Web.Kernel.Runtime`'s
                // `headerNamesOf` uses to expose a JDK `Collection<HttpString>`)
                // as well as any other Lyric-native single-param generic
                // (`Set[T]`, a user-defined wrapper, …) — before this arm,
                // only the literal name `List` got a typed element and
                // everything else fell through to `TyError`, silently
                // erasing the loop variable to `Object` and breaking any
                // extension-method call chained on it downstream (JVM
                // auto-FFI resolving against `java.lang.Object` instead of
                // the real element type, #6565).  A type that isn't actually
                // iterable at runtime is still not separately rejected here
                // — as with the `Map[K,V]` case above, codegen owns that
                // rejection.
                iterArgs[0]
              } else {
                TyError
              }
            }
            case _ -> TyError
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
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, body, false)
      scopePop(sc)
    }

    case SWhile(_, cond, body) -> {
      val condT = inferExpr(sc, tbl, sigs, diag, cond)
      if not typeEquiv(condT, TyPrim(pt = PtBool)) {
        diag.add(errorDiagnostic("T0066", "while-condition must be Bool (got " + renderType(condT) + ")", stmt.span))
      }
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, body, false)
    }

    case STry(body, catches, finally_) -> {
      val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, body, false)
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
        val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, c.body, false)
        scopePop(sc)
        i = i + 1
      }
      match finally_ {
        case None -> {
        }
        case Some(fb) -> {
          val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, fb, false)
        }
      }
    }

    case SItem(_) -> {
    }
    case SRule(_, _) -> {
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Block checking.
// ─────────────────────────────────────────────────────────────────────────────
// Whether `label` (a loop's own label, if any) is targeted by `bl`, a
// `break`'s label argument (`None` for a bare `break`).
func breakTargetsLoop(bl: in Option[String], label: in Option[String]): Bool {
  match bl {
    case None -> true
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
    case ERange(rb) -> match rb { case RBClosed(a, b) -> exprMayEscapeLoop(a, label, nested) or exprMayEscapeLoop(b, label, nested); case RBHalfOpen(a, b) -> exprMayEscapeLoop(a, label, nested) or exprMayEscapeLoop(b, label, nested); case RBLowerOpen(a) -> exprMayEscapeLoop(a, label, nested); case RBUpperOpen(a) -> exprMayEscapeLoop(a, label, nested) }
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
        case Some(b) -> match b { case EOBExpr(ee) -> exprMayEscapeLoop(ee, label, nested); case EOBBlock(eb) -> blockMayEscapeLoop(eb, label, nested) }
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
    case SBreak(bl) -> breakTargetsLoop(bl, label)
    case SContinue(_) -> false
    case SReturn(_) -> false
    case SThrow(e) -> exprMayEscapeLoop(e, label, nested)
    case SInvariant(e) -> exprMayEscapeLoop(e, label, nested)
    case SItem(_) -> false
    case SExpr(e) -> exprMayEscapeLoop(e, label, nested)
    case SAssign(t, _, v) -> exprMayEscapeLoop(t, label, nested) or exprMayEscapeLoop(v, label, nested)
    case SRule(l, r) -> exprMayEscapeLoop(l, label, nested) or exprMayEscapeLoop(r, label, nested)
    case SLocal(binding) -> match binding { case LBVal(_, _, e) -> exprMayEscapeLoop(e, label, nested); case LBLet(_, _, e) -> exprMayEscapeLoop(e, label, nested); case LBVar(_, _, Some(e)) -> exprMayEscapeLoop(e, label, nested); case LBVar(_, _, None) -> false }
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
        match e.kind {
          case EBlock(innerBlk) -> {
            lastExprType = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, innerBlk, valuePos and isLast)
          }
          case EUnsafe(innerBlk) -> {
            lastExprType = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, innerBlk, valuePos and isLast)
          }
          case EIf(cond, thenBranch, elseBranch, _) -> {
            lastExprType = inferIfExpr(sc, tbl, sigs, diag, e, cond, thenBranch, elseBranch, valuePos and isLast)
          }
          case EMatch(scrutinee, arms) -> {
            lastExprType = inferMatchExpr(sc, tbl, sigs, diag, e, scrutinee, arms, valuePos and isLast)
          }
          case _ -> {
            lastExprType = inferExpr(sc, tbl, sigs, diag, e)
          }
        }
      }
      // Codegen lowers value-position try via a shared temp — type the expression as the body (or first handler if body is Never).
      case STry(body, catches, fin) -> {
        // The `try` value is consumed only when the enclosing block is in value
        // position *and* this is the trailing statement; otherwise the value is
        // discarded (#3262).
        val tryValuePos = valuePos and i == blk.statements.count - 1
        var resultTy = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, body, tryValuePos)
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
          val hTy = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, c.body, tryValuePos)
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
            val _ = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, fb, false)
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
        lastExprType = checkBlock(sc, tbl, sigs, genericNames, returnTy, returnTyExpr, diag, body, false)
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
    case SLocal(b) -> match b { case LBVal(_, _, init) -> collectAssignedExpr(init, acc); case LBLet(_, _, init) -> collectAssignedExpr(init, acc); case LBVar(_, _, initOpt) -> match initOpt { case Some(e) -> collectAssignedExpr(e, acc); case None -> {  } } }
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
    case Some(b) -> match b { case FBBlock(blk) -> collectAssignedBlock(blk, assigned); case FBExpr(e) -> collectAssignedExpr(e, assigned) }
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
      case PMOut -> if not listContainsStr(assigned, p.name) { diag.add(errorDiagnostic("T0086", "`out` parameter '" + p.name + "' is never assigned before the function returns", fn.span)) }
      case _ -> {
      }
    }
    k = k + 1
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
      case Some(b0) -> match b0 { case FBBlock(blk0) -> blk0.statements.count == 0; case FBExpr(_) -> false }
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

  match fn.body {
    case None -> {
    }
    case Some(body) -> match body {
      case FBExpr(e) -> {
        val bodyType = inferExpr(sc, tbl, sigs, diag, e)
        val isNever = match bodyType {
          case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }
          case _ -> false
        }
        if not isNever and not typeAssignable(tbl, sig.returnTy, bodyType) {
          diag.add(
            errorDiagnostic(
              "T0070",
              "function body has type " + renderType(bodyType) + " but declared return type is " + declaredReturnTyStr,
              fn.span
            )
          )
        }
      }
      case FBBlock(blk) -> {
        val bodyValuePos = not isUnitType(sig.returnTy)
        val bodyType = checkBlock(sc, tbl, sigs, sig.generics, sig.returnTy, fn.ret, diag, blk, bodyValuePos)
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
        if not isNever and not typeAssignable(tbl, sig.returnTy, bodyType) {
          diag.add(
            errorDiagnostic(
              "T0070",
              "function body trailing expression has type " + renderType(bodyType) + " but declared return type is " +
                declaredReturnTyStr,
              fn.span
            )
          )
        }
      }
    }
  }
  checkOutDefiniteAssignment(diag, fn, sig)
}
