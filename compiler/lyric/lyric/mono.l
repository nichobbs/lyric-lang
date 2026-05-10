// lyric/mono.l — self-hosted monomorphizer (Phase 5 §M5.2).
//
// Call-site monomorphizer for generic functions defined in the same
// compilation unit.  Imported generic functions (e.g. mapOption from
// Std.Core) use real CLR generic types at runtime — this pass handles
// same-package generic functions that the self-hosted PE emitter would
// otherwise be unable to instantiate.
//
// Algorithm:
//   1. Collect all generic IFunc items from the SourceFile into a lookup map.
//   2. Walk non-generic function bodies, rewriting call sites that reference
//      same-package generic functions.  At each such call site, infer the
//      concrete type arguments by unifying the function's TypeExpr parameter
//      types against the known types of the argument expressions (literals
//      and variables declared with explicit type annotations).
//   3. If all type parameters are resolved, compute a mangled specialised
//      name (e.g. "mapFoo__Int__String"), queue a SpecRequest, and rewrite
//      the call to use the specialised name.
//   4. Process the worklist: for each SpecRequest, substitute the type vars
//      in the generic FunctionDecl's param/ret TypeExprs, then walk the
//      specialised body (which may enqueue further SpecRequests for nested
//      generic calls).
//   5. Return a MonoResult carrying the rewritten SourceFile (generic IFunc
//      items removed, specialised items appended) and a rewrites map.
//
// Limitations (Phase 5 bootstrap grade):
//   • Only same-package generics are specialised.  Imported generics use
//     real CLR generics as emitted by the F# bootstrap compiler.
//   • Type inference covers literals, explicitly-annotated variables, and
//     function parameters.  Complex expression types (method calls, field
//     projections, lambdas) are not inferred; those call sites are left
//     un-specialised.
//   • Value generic parameters (GPValue) are not handled; only type-level
//     GPType parameters are specialised.

package Lyric.Mono

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Public types
// ─────────────────────────────────────────────────────────────────────────────

/// Result of the monomorphisation pass.
pub record MonoResult {
  /// Rewritten SourceFile: generic IFunc items are removed, specialised
  /// IFunc items are appended, and call sites in non-generic items are
  /// rewritten to use the specialised names.
  file:     SourceFile
  /// Maps generic function names to the last-seen specialised name (for
  /// downstream diagnostics; not needed for correctness).
  rewrites: Map[String, String]
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Internal state
// ─────────────────────────────────────────────────────────────────────────────

record SpecRequest {
  specName: String
  baseDecl: FunctionDecl
  subst:    Map[String, TypeExpr]
}

record MonoState {
  genDecls:  Map[String, FunctionDecl]
  seenSpecs: Map[String, Bool]
  allSpecs:  List[SpecRequest]
}

func newMonoState(genDecls: in Map[String, FunctionDecl]): MonoState {
  MonoState(
    genDecls  = genDecls,
    seenSpecs = newMap(),
    allSpecs  = newList())
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Synthetic span / path helpers
// ─────────────────────────────────────────────────────────────────────────────

func synPos(): Position { Position(offset = 0, line = 1, column = 1) }
func synSpan(): Span { Span(startPos = synPos(), endPos = synPos()) }

func singleSegPath(name: in String): ModulePath {
  val segs: List[String] = newList()
  segs.add(name)
  ModulePath(segments = segs, span = synSpan())
}

func singleSegPathExpr(name: in String, span: in Span): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  val path = ModulePath(segments = segs, span = span)
  Expr(kind = EPath(path = path), span = span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. TypeExpr key (for mangled specialisation names)
// ─────────────────────────────────────────────────────────────────────────────

func typeExprKey(te: in TypeExpr): String {
  match te.kind {
    case TRef(path)         -> pathSegsKey(path.segments)
    case TGenericApp(h, as) -> pathSegsKey(h.segments) + "_" + typeArgListKey(as)
    case TUnit              -> "Unit"
    case TNever             -> "Never"
    case TSelf              -> "Self"
    case TArray(_, elem)    -> "Arr_" + typeExprKey(elem)
    case TSlice(elem)       -> "Slice_" + typeExprKey(elem)
    case TNullable(inner)   -> "Nullable_" + typeExprKey(inner)
    case TTuple(ts)         -> "Tup_" + typeExprListKey(ts)
    case TFunction(ps, r)   -> "Fn_" + typeExprListKey(ps) + "_" + typeExprKey(r)
    case TParen(inner)      -> typeExprKey(inner)
    case TRefined(p, _)     -> pathSegsKey(p.segments)
    case TError             -> "Err"
  }
}

func pathSegsKey(segs: in List[String]): String {
  var result = ""
  var i = 0
  while i < segs.count {
    if i > 0 { result = result + "." }
    result = result + segs[i]
    i = i + 1
  }
  result
}

func typeArgListKey(args: in List[TypeArg]): String {
  var result = ""
  var i = 0
  while i < args.count {
    if i > 0 { result = result + "_" }
    match args[i] {
      case TAType(te) -> result = result + typeExprKey(te)
      case TAValue(_) -> result = result + "V"
    }
    i = i + 1
  }
  result
}

func typeExprListKey(ts: in List[TypeExpr]): String {
  var result = ""
  var i = 0
  while i < ts.count {
    if i > 0 { result = result + "_" }
    result = result + typeExprKey(ts[i])
    i = i + 1
  }
  result
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. TypeExpr substitution (type-var name → concrete TypeExpr)
// ─────────────────────────────────────────────────────────────────────────────

func substTypeExpr(subst: in Map[String, TypeExpr], te: in TypeExpr): TypeExpr {
  val s = te.span
  match te.kind {
    case TRef(path) -> {
      if path.segments.count == 1 {
        match mapGet(subst, path.segments[0]) {
          case Some(concrete) -> concrete
          case None           -> te
        }
      } else { te }
    }
    case TGenericApp(h, args) -> {
      val newArgs: List[TypeArg] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case TAType(inner) ->
            newArgs.add(TAType(ty = substTypeExpr(subst, inner)))
          case TAValue(e)    ->
            newArgs.add(TAValue(expr = e))
        }
        i = i + 1
      }
      TypeExpr(kind = TGenericApp(head = h, args = newArgs), span = s)
    }
    case TTuple(ts) -> {
      val newTs: List[TypeExpr] = newList()
      var i = 0
      while i < ts.count { newTs.add(substTypeExpr(subst, ts[i])); i = i + 1 }
      TypeExpr(kind = TTuple(types = newTs), span = s)
    }
    case TNullable(inner) ->
      TypeExpr(kind = TNullable(inner = substTypeExpr(subst, inner)), span = s)
    case TSlice(elem) ->
      TypeExpr(kind = TSlice(element = substTypeExpr(subst, elem)), span = s)
    case TArray(sz, elem) ->
      TypeExpr(kind = TArray(size = sz, element = substTypeExpr(subst, elem)), span = s)
    case TFunction(ps, r) -> {
      val newPs: List[TypeExpr] = newList()
      var i = 0
      while i < ps.count { newPs.add(substTypeExpr(subst, ps[i])); i = i + 1 }
      TypeExpr(kind = TFunction(parameters = newPs, retTy = substTypeExpr(subst, r)), span = s)
    }
    case TParen(inner) ->
      TypeExpr(kind = TParen(inner = substTypeExpr(subst, inner)), span = s)
    case _ -> te
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Unification — TypeExpr-level, structural, one-sided
// ─────────────────────────────────────────────────────────────────────────────

// Unify `paramTE` (may contain TRef to a type param name listed in
// `typeParams`) against `argTE` (concrete caller type).  Bindings are
// accumulated in `subst` (map from type-param name → concrete TypeExpr).
// Conflicts are silently ignored (first-binding wins).

func unifyTE(
  typeParams: in List[String],
  paramTE:    in TypeExpr,
  argTE:      in TypeExpr,
  subst:      in Map[String, TypeExpr]
): Unit {
  match paramTE.kind {
    case TRef(path) -> {
      if path.segments.count == 1 {
        val name = path.segments[0]
        if listContainsStr(typeParams, name) {
          if not subst.containsKey(name) {
            subst.add(name, argTE)
          }
        }
      }
    }
    case TGenericApp(h1, a1) -> {
      match argTE.kind {
        case TGenericApp(h2, a2) -> {
          if pathSegsKey(h1.segments) == pathSegsKey(h2.segments) &&
             a1.count == a2.count {
            var i = 0
            while i < a1.count {
              match a1[i] {
                case TAType(te1) -> {
                  match a2[i] {
                    case TAType(te2) -> unifyTE(typeParams, te1, te2, subst)
                    case _           -> ()
                  }
                }
                case _ -> ()
              }
              i = i + 1
            }
          }
        }
        case _ -> ()
      }
    }
    case TNullable(inner1) -> {
      match argTE.kind {
        case TNullable(inner2) -> unifyTE(typeParams, inner1, inner2, subst)
        case _                 -> ()
      }
    }
    case TTuple(ts1) -> {
      match argTE.kind {
        case TTuple(ts2) -> {
          if ts1.count == ts2.count {
            var i = 0
            while i < ts1.count {
              unifyTE(typeParams, ts1[i], ts2[i], subst)
              i = i + 1
            }
          }
        }
        case _ -> ()
      }
    }
    case TFunction(ps1, r1) -> {
      match argTE.kind {
        case TFunction(ps2, r2) -> {
          if ps1.count == ps2.count {
            var i = 0
            while i < ps1.count { unifyTE(typeParams, ps1[i], ps2[i], subst); i = i + 1 }
            unifyTE(typeParams, r1, r2, subst)
          }
        }
        case _ -> ()
      }
    }
    case _ -> ()
  }
}

func listContainsStr(xs: in List[String], s: in String): Bool {
  var i = 0
  while i < xs.count {
    if xs[i] == s { return true }
    i = i + 1
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Generic parameter name extraction
// ─────────────────────────────────────────────────────────────────────────────

func extractTypeParamNames(gps: in Option[GenericParams]): List[String] {
  val result: List[String] = newList()
  match gps {
    case None -> ()
    case Some(gp) -> {
      var i = 0
      while i < gp.params.count {
        match gp.params[i] {
          case GPType(name, _) -> result.add(name)
          case GPValue(_, _, _) -> ()
        }
        i = i + 1
      }
    }
  }
  result
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Specialised function name mangling
// ─────────────────────────────────────────────────────────────────────────────

func specFuncName(
  base:       in String,
  typeParams: in List[String],
  subst:      in Map[String, TypeExpr]
): String {
  var result = base
  var i = 0
  while i < typeParams.count {
    result = result + "__"
    match mapGet(subst, typeParams[i]) {
      case Some(te) -> result = result + typeExprKey(te)
      case None     -> result = result + "Unknown"
    }
    i = i + 1
  }
  result
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Simplified type inference — expression → TypeExpr option
// ─────────────────────────────────────────────────────────────────────────────

// Returns the declared TypeExpr for an expression when it can be determined
// from the local type environment or literal shape alone.  Returns None for
// complex sub-expressions (calls, field projections, binary ops, etc.).

func inferLitTE(lit: in Literal, span: in Span): Option[TypeExpr] {
  match lit {
    case LInt(_, suffix) -> {
      val name = match suffix {
        case I8          -> "Byte"
        case I16         -> "Short"
        case I32         -> "Int"
        case I64         -> "Long"
        case U8          -> "Byte"
        case U16         -> "UShort"
        case U32         -> "UInt"
        case U64         -> "ULong"
        case NoIntSuffix -> "Int"
      }
      Some(value = TypeExpr(kind = TRef(path = singleSegPath(name)), span = span))
    }
    case LFloat(_, suffix) -> {
      val name = match suffix {
        case F32         -> "Float"
        case F64         -> "Double"
        case NoFloatSuffix -> "Double"
      }
      Some(value = TypeExpr(kind = TRef(path = singleSegPath(name)), span = span))
    }
    case LBool(_) ->
      Some(value = TypeExpr(kind = TRef(path = singleSegPath("Bool")), span = span))
    case LString(_) | LTripleString(_) | LRawString(_) ->
      Some(value = TypeExpr(kind = TRef(path = singleSegPath("String")), span = span))
    case LChar(_) ->
      Some(value = TypeExpr(kind = TRef(path = singleSegPath("Char")), span = span))
    case LUnit ->
      Some(value = TypeExpr(kind = TUnit, span = span))
  }
}

func inferExprTE(env: in Map[String, TypeExpr], expr: in Expr): Option[TypeExpr] {
  match expr.kind {
    case ELiteral(lit)  -> inferLitTE(lit, expr.span)
    case EParen(inner)  -> inferExprTE(env, inner)
    case EPath(path)    -> {
      if path.segments.count == 1 {
        mapGet(env, path.segments[0])
      } else { None }
    }
    case _              -> None
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Substitution completeness check
// ─────────────────────────────────────────────────────────────────────────────

func substIsComplete(typeParams: in List[String], subst: in Map[String, TypeExpr]): Bool {
  var i = 0
  while i < typeParams.count {
    if not subst.containsKey(typeParams[i]) { return false }
    i = i + 1
  }
  true
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. Function specialisation — substitute type vars in decl structure
// ─────────────────────────────────────────────────────────────────────────────

func specializeFunc(
  decl:     in FunctionDecl,
  specName: in String,
  subst:    in Map[String, TypeExpr]
): FunctionDecl {
  val newParams: List[Param] = newList()
  var i = 0
  while i < decl.params.count {
    val p = decl.params[i]
    newParams.add(Param(
      mode = p.mode,
      name = p.name,
      ty   = substTypeExpr(subst, p.ty),
      dflt = p.dflt,
      span = p.span))
    i = i + 1
  }
  val newRet = match decl.ret {
    case None    -> None
    case Some(r) -> Some(value = substTypeExpr(subst, r))
  }
  val emptyDocs: List[DocComment] = newList()
  val emptyAnns: List[Annotation] = newList()
  FunctionDecl(
    docComments = emptyDocs,
    annotations = emptyAnns,
    visibility  = None,
    isAsync     = decl.isAsync,
    name        = specName,
    generics    = None,
    params      = newParams,
    ret         = newRet,
    whereClause = None,
    contracts   = decl.contracts,
    body        = decl.body,
    span        = decl.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §12. AST rewriting — call-site replacement and subtree walk
// ─────────────────────────────────────────────────────────────────────────────

func callArgExpr(arg: in CallArg): Expr {
  match arg {
    case CAPositional(e)    -> e
    case CANamed(_, e, _)   -> e
  }
}

func rewriteCallArgs(
  state: in MonoState,
  env:   in Map[String, TypeExpr],
  args:  in List[CallArg]
): List[CallArg] {
  val result: List[CallArg] = newList()
  var i = 0
  while i < args.count {
    match args[i] {
      case CAPositional(e)      ->
        result.add(CAPositional(expr = rewriteExpr(state, env, e)))
      case CANamed(n, e, span)  ->
        result.add(CANamed(name = n, value = rewriteExpr(state, env, e), span = span))
    }
    i = i + 1
  }
  result
}

func rewriteEOB(
  state: in MonoState,
  env:   in Map[String, TypeExpr],
  eob:   in ExprOrBlock
): ExprOrBlock {
  match eob {
    case EOBExpr(e)  -> EOBExpr(expr = rewriteExpr(state, env, e))
    case EOBBlock(b) -> EOBBlock(block = rewriteBlock(state, env, b))
  }
}

func rewriteMatchArms(
  state: in MonoState,
  env:   in Map[String, TypeExpr],
  arms:  in List[MatchArm]
): List[MatchArm] {
  val result: List[MatchArm] = newList()
  var i = 0
  while i < arms.count {
    val arm = arms[i]
    val newGuard = match arm.guard {
      case None    -> None
      case Some(g) -> Some(value = rewriteExpr(state, env, g))
    }
    result.add(MatchArm(
      pattern = arm.pattern,
      guard   = newGuard,
      body    = rewriteEOB(state, env, arm.body),
      span    = arm.span))
    i = i + 1
  }
  result
}

func rewriteInterpolSegs(
  state: in MonoState,
  env:   in Map[String, TypeExpr],
  segs:  in List[InterpolatedSegment]
): List[InterpolatedSegment] {
  val result: List[InterpolatedSegment] = newList()
  var i = 0
  while i < segs.count {
    match segs[i] {
      case ISText(t, sp) -> result.add(ISText(text = t, span = sp))
      case ISExpr(e)     -> result.add(ISExpr(expr = rewriteExpr(state, env, e)))
    }
    i = i + 1
  }
  result
}

func rewriteExpr(
  state: in MonoState,
  env:   in Map[String, TypeExpr],
  expr:  in Expr
): Expr {
  val s = expr.span
  match expr.kind {

    // ── Generic call sites ────────────────────────────────────────────────
    case ECall(fn, args) -> {
      val newArgs = rewriteCallArgs(state, env, args)
      match fn.kind {
        case EPath(path) -> {
          if path.segments.count == 1 {
            val fname = path.segments[0]
            match mapGet(state.genDecls, fname) {
              case Some(baseDecl) -> {
                val typeParams = extractTypeParamNames(baseDecl.generics)
                if typeParams.count > 0 {
                  val subst: Map[String, TypeExpr] = newMap()
                  var i = 0
                  while i < args.count && i < baseDecl.params.count {
                    match inferExprTE(env, callArgExpr(args[i])) {
                      case Some(argTE) ->
                        unifyTE(typeParams, baseDecl.params[i].ty, argTE, subst)
                      case None -> ()
                    }
                    i = i + 1
                  }
                  if substIsComplete(typeParams, subst) {
                    val name = specFuncName(fname, typeParams, subst)
                    if not state.seenSpecs.containsKey(name) {
                      state.seenSpecs.add(name, true)
                      val specDecl = specializeFunc(baseDecl, name, subst)
                      state.allSpecs.add(SpecRequest(
                        specName = name,
                        baseDecl = specDecl,
                        subst    = subst))
                    }
                    val newFn = singleSegPathExpr(name, fn.span)
                    return Expr(kind = ECall(fn = newFn, args = newArgs), span = s)
                  }
                }
                Expr(kind = ECall(fn = fn, args = newArgs), span = s)
              }
              case None ->
                Expr(kind = ECall(fn = fn, args = newArgs), span = s)
            }
          } else {
            Expr(kind = ECall(fn = fn, args = newArgs), span = s)
          }
        }
        case _ ->
          Expr(kind = ECall(fn = rewriteExpr(state, env, fn), args = newArgs), span = s)
      }
    }

    // ── Recursive sub-expression rewriting ───────────────────────────────
    case EBinop(op, lhs, rhs) ->
      Expr(kind = EBinop(
        op  = op,
        lhs = rewriteExpr(state, env, lhs),
        rhs = rewriteExpr(state, env, rhs)), span = s)

    case EPrefix(op, operand) ->
      Expr(kind = EPrefix(op = op, operand = rewriteExpr(state, env, operand)), span = s)

    case EMember(recv, name) ->
      Expr(kind = EMember(
        receiver   = rewriteExpr(state, env, recv),
        memberName = name), span = s)

    case EIndex(recv, idxs) -> {
      val newIdxs: List[Expr] = newList()
      var i = 0
      while i < idxs.count { newIdxs.add(rewriteExpr(state, env, idxs[i])); i = i + 1 }
      Expr(kind = EIndex(
        receiver = rewriteExpr(state, env, recv),
        indices  = newIdxs), span = s)
    }

    case EIf(cond, thenB, elseB, form) -> {
      val newElse = match elseB {
        case None    -> None
        case Some(e) -> Some(value = rewriteEOB(state, env, e))
      }
      Expr(kind = EIf(
        cond       = rewriteExpr(state, env, cond),
        thenBranch = rewriteEOB(state, env, thenB),
        elseBranch = newElse,
        thenForm   = form), span = s)
    }

    case EMatch(scrut, arms) ->
      Expr(kind = EMatch(
        scrutinee = rewriteExpr(state, env, scrut),
        arms      = rewriteMatchArms(state, env, arms)), span = s)

    case EBlock(blk) ->
      Expr(kind = EBlock(block = rewriteBlock(state, env, blk)), span = s)

    case EUnsafe(blk) ->
      Expr(kind = EUnsafe(block = rewriteBlock(state, env, blk)), span = s)

    case EAwait(inner)     ->
      Expr(kind = EAwait(inner = rewriteExpr(state, env, inner)), span = s)

    case ESpawn(inner)     ->
      Expr(kind = ESpawn(inner = rewriteExpr(state, env, inner)), span = s)

    case ETry(inner)       ->
      Expr(kind = ETry(inner = rewriteExpr(state, env, inner)), span = s)

    case EPropagate(inner) ->
      Expr(kind = EPropagate(inner = rewriteExpr(state, env, inner)), span = s)

    case EParen(inner) ->
      Expr(kind = EParen(inner = rewriteExpr(state, env, inner)), span = s)

    case ETuple(es) -> {
      val newEs: List[Expr] = newList()
      var i = 0
      while i < es.count { newEs.add(rewriteExpr(state, env, es[i])); i = i + 1 }
      Expr(kind = ETuple(exprs = newEs), span = s)
    }

    case EList(es) -> {
      val newEs: List[Expr] = newList()
      var i = 0
      while i < es.count { newEs.add(rewriteExpr(state, env, es[i])); i = i + 1 }
      Expr(kind = EList(exprs = newEs), span = s)
    }

    case EAssign(target, op, value) ->
      Expr(kind = EAssign(
        target = rewriteExpr(state, env, target),
        op     = op,
        value  = rewriteExpr(state, env, value)), span = s)

    case EInterpolated(segs) ->
      Expr(kind = EInterpolated(segments = rewriteInterpolSegs(state, env, segs)), span = s)

    case ELambda(lparams, body) ->
      Expr(kind = ELambda(lambdaParams = lparams, body = rewriteBlock(state, env, body)), span = s)

    case ETypeApp(fn, targs) ->
      Expr(kind = ETypeApp(fn = rewriteExpr(state, env, fn), args = targs), span = s)

    // Leaves: literals, EPath, ESelf, EResult, EOld, EForall, EExists, ERange, EError
    case _ -> expr
  }
}

func rewriteBlock(
  state: in MonoState,
  env:   in Map[String, TypeExpr],
  blk:   in Block
): Block {
  val newStmts: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    newStmts.add(rewriteStmt(state, env, blk.statements[i]))
    i = i + 1
  }
  Block(statements = newStmts, span = blk.span)
}

func rewriteStmt(
  state: in MonoState,
  env:   in Map[String, TypeExpr],
  stmt:  in Statement
): Statement {
  val s = stmt.span
  match stmt.kind {
    case SLocal(binding) ->
      Statement(kind = SLocal(binding = rewriteBinding(state, env, binding)), span = s)

    case SAssign(target, op, value) ->
      Statement(kind = SAssign(
        target = rewriteExpr(state, env, target),
        op     = op,
        value  = rewriteExpr(state, env, value)), span = s)

    case SReturn(opt) -> {
      val newOpt = match opt {
        case None    -> None
        case Some(e) -> Some(value = rewriteExpr(state, env, e))
      }
      Statement(kind = SReturn(value = newOpt), span = s)
    }

    case SThrow(e) ->
      Statement(kind = SThrow(expr = rewriteExpr(state, env, e)), span = s)

    case SExpr(e) ->
      Statement(kind = SExpr(expr = rewriteExpr(state, env, e)), span = s)

    case SWhile(lbl, cond, body) ->
      Statement(kind = SWhile(
        label = lbl,
        cond  = rewriteExpr(state, env, cond),
        body  = rewriteBlock(state, env, body)), span = s)

    case SFor(lbl, pat, iter, body) ->
      Statement(kind = SFor(
        label = lbl,
        pat   = pat,
        iter  = rewriteExpr(state, env, iter),
        body  = rewriteBlock(state, env, body)), span = s)

    case SLoop(lbl, body) ->
      Statement(kind = SLoop(label = lbl, body = rewriteBlock(state, env, body)), span = s)

    case SDefer(body) ->
      Statement(kind = SDefer(body = rewriteBlock(state, env, body)), span = s)

    case SScope(lbl, body) ->
      Statement(kind = SScope(binding = lbl, body = rewriteBlock(state, env, body)), span = s)

    case SInvariant(e) ->
      Statement(kind = SInvariant(expr = rewriteExpr(state, env, e)), span = s)

    case SRule(lhs, rhs) ->
      Statement(kind = SRule(
        lhs = rewriteExpr(state, env, lhs),
        rhs = rewriteExpr(state, env, rhs)), span = s)

    case STry(body, catches) -> {
      val newBody = rewriteBlock(state, env, body)
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val cc = catches[i]
        newCatches.add(CatchClause(
          typeName = cc.typeName,
          bindName = cc.bindName,
          body     = rewriteBlock(state, env, cc.body),
          span     = cc.span))
        i = i + 1
      }
      Statement(kind = STry(body = newBody, catches = newCatches), span = s)
    }

    // SBreak, SContinue, SItem: pass through unchanged
    case _ -> stmt
  }
}

// Track variables bound in this statement into `env`.
func rewriteBinding(
  state:   in MonoState,
  env:     in Map[String, TypeExpr],
  binding: in LocalBinding
): LocalBinding {
  match binding {
    case LBVal(pat, tyOpt, init) -> {
      match tyOpt {
        case Some(te) -> trackPatternEnv(env, pat, te)
        case None     -> ()
      }
      LBVal(pat = pat, ty = tyOpt, init = rewriteExpr(state, env, init))
    }
    case LBVar(name, tyOpt, initOpt) -> {
      match tyOpt {
        case Some(te) -> {
          if env.containsKey(name) {
            // Last-write wins — Map.add would throw on duplicate; for simplicity
            // we leave the old binding in place (type env is best-effort).
            ()
          } else {
            env.add(name, te)
          }
        }
        case None -> ()
      }
      val newInit = match initOpt {
        case None    -> None
        case Some(e) -> Some(value = rewriteExpr(state, env, e))
      }
      LBVar(name = name, ty = tyOpt, init = newInit)
    }
    case LBLet(name, tyOpt, init) -> {
      match tyOpt {
        case Some(te) -> {
          if not env.containsKey(name) { env.add(name, te) }
        }
        case None -> ()
      }
      LBLet(name = name, ty = tyOpt, init = rewriteExpr(state, env, init))
    }
  }
}

func trackPatternEnv(env: in Map[String, TypeExpr], pat: in Pattern, te: in TypeExpr): Unit {
  match pat.kind {
    case PBinding(name, _) -> {
      if not env.containsKey(name) { env.add(name, te) }
    }
    case _ -> ()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §13. Parameter-seeded type environment
// ─────────────────────────────────────────────────────────────────────────────

func seedEnvFromParams(params: in List[Param]): Map[String, TypeExpr] {
  val env: Map[String, TypeExpr] = newMap()
  var i = 0
  while i < params.count {
    env.add(params[i].name, params[i].ty)
    i = i + 1
  }
  env
}

// ─────────────────────────────────────────────────────────────────────────────
// §14. Rewrite a FunctionBody
// ─────────────────────────────────────────────────────────────────────────────

func rewriteFuncBody(
  state:  in MonoState,
  env:    in Map[String, TypeExpr],
  body:   in Option[FunctionBody]
): Option[FunctionBody] {
  match body {
    case None -> None
    case Some(fb) -> Some(value = match fb {
      case FBBlock(blk) -> FBBlock(block = rewriteBlock(state, env, blk))
      case FBExpr(e)    -> FBExpr(expr  = rewriteExpr(state, env, e))
    })
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §15. Main entry point
// ─────────────────────────────────────────────────────────────────────────────

/// Monomorphise all same-package generic functions in `file`.
///
/// Returns a `MonoResult` whose `file` field contains:
///  - All non-generic items (with generic call sites rewritten to specialised
///    names).
///  - Specialised (non-generic) copies of every reachable generic function
///    instantiation, appended at the end of the item list.
///  - Generic IFunc items are *removed* from the output (they have been
///    expanded into one or more specialisations).
///
/// If no same-package generic functions are found, the input file is returned
/// unchanged.
pub func monoFile(file: in SourceFile): MonoResult {
  // ── Phase 1: collect generic function decls ─────────────────────────────
  val genDecls: Map[String, FunctionDecl] = newMap()
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> {
        match decl.generics {
          case Some(_) -> {
            if not genDecls.containsKey(decl.name) {
              genDecls.add(decl.name, decl)
            }
          }
          case None -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }

  // If nothing to monomorphise, return early.
  if genDecls.count == 0 {
    val emptyRewrites: Map[String, String] = newMap()
    return MonoResult(file = file, rewrites = emptyRewrites)
  }

  val state = newMonoState(genDecls)

  // ── Phase 2: rewrite non-generic items ──────────────────────────────────
  val rewrittenItems: List[Item] = newList()
  var j = 0
  while j < file.items.count {
    val item = file.items[j]
    match item.kind {
      case IFunc(decl) -> {
        match decl.generics {
          case Some(_) -> {
            // Generic functions are dropped here; specialisations are added below.
            ()
          }
          case None -> {
            val env  = seedEnvFromParams(decl.params)
            val newBody = rewriteFuncBody(state, env, decl.body)
            val newDecl = FunctionDecl(
              docComments = decl.docComments,
              annotations = decl.annotations,
              visibility  = decl.visibility,
              isAsync     = decl.isAsync,
              name        = decl.name,
              generics    = None,
              params      = decl.params,
              ret         = decl.ret,
              whereClause = decl.whereClause,
              contracts   = decl.contracts,
              body        = newBody,
              span        = decl.span)
            rewrittenItems.add(Item(
              docComments = item.docComments,
              annotations = item.annotations,
              visibility  = item.visibility,
              kind        = IFunc(decl = newDecl),
              span        = item.span))
          }
        }
      }
      case _ -> rewrittenItems.add(item)
    }
    j = j + 1
  }

  // ── Phase 3: process worklist (fixpoint over allSpecs) ──────────────────
  // Each iteration picks up the next SpecRequest.  Rewriting the body may
  // add further requests; the while condition re-evaluates count each round.
  val finalSpecDecls: List[FunctionDecl] = newList()

  var wi = 0
  while wi < state.allSpecs.count {
    val req = state.allSpecs[wi]
    // The baseDecl already has type-var substitution applied to its params/ret.
    // Now rewrite its body to replace nested generic calls.
    val env    = seedEnvFromParams(req.baseDecl.params)
    val newBody = rewriteFuncBody(state, env, req.baseDecl.body)
    val finalDecl = FunctionDecl(
      docComments = req.baseDecl.docComments,
      annotations = req.baseDecl.annotations,
      visibility  = req.baseDecl.visibility,
      isAsync     = req.baseDecl.isAsync,
      name        = req.baseDecl.name,
      generics    = None,
      params      = req.baseDecl.params,
      ret         = req.baseDecl.ret,
      whereClause = req.baseDecl.whereClause,
      contracts   = req.baseDecl.contracts,
      body        = newBody,
      span        = req.baseDecl.span)
    finalSpecDecls.add(finalDecl)
    wi = wi + 1
  }

  // ── Phase 4: build output SourceFile ────────────────────────────────────
  val allItems: List[Item] = newList()

  // Non-generic items (rewritten call sites)
  var ri = 0
  while ri < rewrittenItems.count { allItems.add(rewrittenItems[ri]); ri = ri + 1 }

  // Specialised function items (each gets a fresh empty doc/ann list)
  var si = 0
  while si < finalSpecDecls.count {
    val sd = finalSpecDecls[si]
    val specDocs: List[DocComment] = newList()
    val specAnns: List[Annotation] = newList()
    allItems.add(Item(
      docComments = specDocs,
      annotations = specAnns,
      visibility  = None,
      kind        = IFunc(decl = sd),
      span        = sd.span))
    si = si + 1
  }

  // Build rewrites map (generic name → last specialised name emitted).
  val rewrites: Map[String, String] = newMap()
  var wj = 0
  while wj < state.allSpecs.count {
    val req = state.allSpecs[wj]
    val baseName = extractBaseName(req.specName)
    if rewrites.containsKey(baseName) {
      // Multiple specialisations: just record the last one (best-effort).
    } else {
      rewrites.add(baseName, req.specName)
    }
    wj = wj + 1
  }

  val newFile = SourceFile(
    moduleDoc       = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl     = file.packageDecl,
    imports         = file.imports,
    items           = allItems,
    span            = file.span)

  MonoResult(file = newFile, rewrites = rewrites)
}

// Extract the base function name from a mangled specialisation name.
// e.g. "mapFoo__Int__String" → "mapFoo"
func extractBaseName(specName: in String): String {
  var i = 0
  while i + 1 < specName.length {
    if specName[i] == '_' && specName[i + 1] == '_' {
      return Str.substring(specName, 0, i)
    }
    i = i + 1
  }
  specName
}
