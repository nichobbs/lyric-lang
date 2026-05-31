// typechecker_checker.l — public entry point of the type checker.
// Mirrors compiler/src/Lyric.TypeChecker/Checker.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Check result.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record CheckResult {
  file:        SourceFile
  symbols:     SymbolTable
  sigs:        Map[String, ResolvedSignature]
  diagnostics: List[Diagnostic]
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Monotonic type-id source (boxed via List length).
// ─────────────────────────────────────────────────────────────────────────────

record TypeIdCounter {
  ticks: List[Int]
}

func newTypeIdCounter(): TypeIdCounter {
  val ticks: List[Int] = newList()
  TypeIdCounter(ticks = ticks)
}

func freshTypeId(ctr: in TypeIdCounter): TypeId {
  ctr.ticks.add(0)
  TypeId(id = ctr.ticks.count)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Duplicate-name detection helpers.
// ─────────────────────────────────────────────────────────────────────────────

func funcArityExists(tbl: in SymbolTable, name: in String, arity: in Int): Bool {
  var i = 0
  while i < tbl.symbols.count {
    val sym = tbl.symbols[i]
    if sym.name == name and not sym.isImported {
      match sym.kind {
        case DKFunc(fd) -> {
          if fd.params.count == arity { return true }
        }
        case _ -> {}
      }
    }
    i = i + 1
  }
  false
}

func hasPriorUserSym(tbl: in SymbolTable, name: in String): Bool {
  var i = 0
  while i < tbl.symbols.count {
    val sym = tbl.symbols[i]
    if sym.name == name and not sym.isImported { return true }
    i = i + 1
  }
  false
}

func checkDuplicate(
  tbl:   in SymbolTable,
  diag:  in List[Diagnostic],
  name:  in String,
  kind:  in DeclKind,
  span:  in Span
): Unit {
  val isDup =
    match kind {
      case DKFunc(fd) -> funcArityExists(tbl, name, fd.params.count)
      case _          -> hasPriorUserSym(tbl, name)
    }
  if isDup {
    diag.add(errorDiagnostic("T0001", "duplicate name '" + name + "'", span))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Item registration.
// ─────────────────────────────────────────────────────────────────────────────

func addSym(
  tbl:        in SymbolTable,
  diag:       in List[Diagnostic],
  isImported: in Bool,
  name:       in String,
  kind:       in DeclKind,
  vis:        in Option[Visibility],
  span:       in Span
): Symbol {
  if not isImported {
    checkDuplicate(tbl, diag, name, kind, span)
  }
  val sym = Symbol(
    name       = name,
    kind       = kind,
    declSpan   = span,
    visibility = vis,
    isImported = isImported)
  symTableAdd(tbl, sym)
  sym
}

func registerItem(
  tbl:        in SymbolTable,
  ctr:        in TypeIdCounter,
  diag:       in List[Diagnostic],
  isImported: in Bool,
  it:         in Item
): Unit {
  val vis  = it.visibility
  val span = it.span
  match it.kind {
    case IRecord(decl) -> {
      val tid = freshTypeId(ctr)
      val _ = addSym(tbl, diag, isImported, decl.name, DKRecord(id = tid, decl = decl), vis, span)
    }
    case IExposedRec(decl) -> {
      val tid = freshTypeId(ctr)
      val _ = addSym(tbl, diag, isImported, decl.name, DKExposedRec(id = tid, decl = decl), vis, span)
    }
    case IUnion(decl) -> {
      val tid = freshTypeId(ctr)
      val _ = addSym(tbl, diag, isImported, decl.name, DKUnion(id = tid, decl = decl), vis, span)
      var i = 0
      while i < decl.cases.count {
        val c = decl.cases[i]
        val _ = addSym(tbl, diag, isImported, c.name, DKUnionCase(parentId = tid, uc = c), vis, c.span)
        i = i + 1
      }
    }
    case IEnum(decl) -> {
      val tid = freshTypeId(ctr)
      val _ = addSym(tbl, diag, isImported, decl.name, DKEnum(id = tid, decl = decl), vis, span)
      var i = 0
      while i < decl.cases.count {
        val c = decl.cases[i]
        val _ = addSym(tbl, diag, isImported, c.name, DKEnumCase(parentId = tid, ec = c), vis, c.span)
        i = i + 1
      }
    }
    case IOpaque(decl) -> {
      val tid = freshTypeId(ctr)
      val _ = addSym(tbl, diag, isImported, decl.name, DKOpaque(id = tid, decl = decl), vis, span)
    }
    case IProtected(decl) -> {
      val tid = freshTypeId(ctr)
      val _ = addSym(tbl, diag, isImported, decl.name, DKProtected(id = tid, decl = decl), vis, span)
    }
    case IDistinctType(decl) -> {
      val tid = freshTypeId(ctr)
      val _ = addSym(tbl, diag, isImported, decl.name, DKDistinctType(id = tid, decl = decl), vis, span)
    }
    case ITypeAlias(decl) -> {
      val _ = addSym(tbl, diag, isImported, decl.name, DKTypeAlias(decl = decl), vis, span)
    }
    case IInterface(decl) -> {
      val tid = freshTypeId(ctr)
      val _ = addSym(tbl, diag, isImported, decl.name, DKInterface(id = tid, decl = decl), vis, span)
    }
    case IExternType(decl) -> {
      val tid = freshTypeId(ctr)
      val _ = addSym(tbl, diag, isImported, decl.name, DKExternType(id = tid, decl = decl), vis, span)
    }
    case IFunc(decl) -> {
      val _ = addSym(tbl, diag, isImported, decl.name, DKFunc(decl = decl), vis, span)
    }
    case IConst(decl) -> {
      val _ = addSym(tbl, diag, isImported, decl.name, DKConst(decl = decl), vis, span)
    }
    case IVal(decl) -> {
      match decl.pattern.kind {
        case PBinding(name, None) -> {
          val _ = addSym(tbl, diag, isImported, name, DKVal(decl = decl), vis, span)
        }
        case _ -> {}
      }
    }
    case IWire(decl) -> {
      val _ = addSym(tbl, diag, isImported, decl.name, DKWire(decl = decl), vis, span)
    }
    case IScopeKind(decl) -> {
      val _ = addSym(tbl, diag, isImported, decl.name, DKScopeKind(decl = decl), vis, span)
    }
    case ITest(decl) -> {
      val _ = addSym(tbl, diag, isImported, decl.title, DKTest(decl = decl), vis, span)
    }
    case IProperty(decl) -> {
      val _ = addSym(tbl, diag, isImported, decl.title, DKProperty(decl = decl), vis, span)
    }
    case IFixture(decl) -> {
      val _ = addSym(tbl, diag, isImported, decl.name, DKFixture(decl = decl), vis, span)
    }
    case IConfig(decl) -> {
      val _ = addSym(tbl, diag, isImported, decl.name, DKConfig(decl = decl), vis, span)
    }
    case IAspect(decl) -> {
      val _ = addSym(tbl, diag, isImported, decl.name, DKAspect(decl = decl), vis, span)
    }
    case IExtern(_) -> {}
    case IImpl(_)   -> {}
    case IError     -> {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Range subtype validation (T2.5).
// ─────────────────────────────────────────────────────────────────────────────

func isNumericPrimitiveName(name: in String): Bool {
  name == "Int"   or name == "Long"  or name == "Short" or name == "Byte" or
  name == "UInt"  or name == "ULong" or name == "UShort" or name == "UByte" or
  name == "Float" or name == "Double"
}

func describeFoldError(fe: in FoldError): String {
  match fe {
    case FENotConstant  -> "expression is not a compile-time integer constant"
    case FECycle(name)  -> "constant '" + name + "' references itself transitively"
    case FEOverflow     -> "integer overflow during constant evaluation"
    case FEDivByZero    -> "division by zero in constant expression"
  }
}

func foldOrErr(
  tbl:  in SymbolTable,
  diag: in List[Diagnostic],
  name: in String,
  e:    in Expr
): Option[Long] {
  match tryFoldInt(tbl, e) {
    case FoldOk(v)  -> Some(value = v)
    case FoldErr(fe) -> {
      diag.add(errorDiagnostic("T0093",
        "range subtype '" + name + "' has a symbolic bound that cannot be folded: " +
        describeFoldError(fe), e.span))
      None
    }
  }
}

func checkClosed(
  tbl:  in SymbolTable,
  diag: in List[Diagnostic],
  name: in String,
  lo:   in Expr,
  hi:   in Expr,
  sym:  in String,
  span: in Span
): Unit {
  match foldOrErr(tbl, diag, name, lo) {
    case None       -> {}
    case Some(loV)  ->
      match foldOrErr(tbl, diag, name, hi) {
        case None      -> {}
        case Some(hiV) -> {
          val invalid =
            if sym == "..=" { loV > hiV }
            else if sym == "..<" { loV >= hiV }
            else { false }
          if invalid {
            diag.add(errorDiagnostic("T0090",
              "range subtype '" + name + "' has empty bounds: " +
              toString(loV) + " " + sym + " " + toString(hiV), span))
          }
        }
      }
  }
}

func checkDistinctType(
  tbl:  in SymbolTable,
  diag: in List[Diagnostic],
  dt:   in DistinctTypeDecl
): Unit {
  match dt.rangeClause {
    case None -> {}
    case Some(_) -> {
      match dt.underlying.kind {
        case TRef(path) -> {
          if path.segments.count == 1 {
            val uname = path.segments[0]
            if not isNumericPrimitiveName(uname) {
              diag.add(errorDiagnostic("T0091",
                "range subtype '" + dt.name +
                "' requires a numeric underlying type, got '" + uname + "'", dt.span))
            }
          }
        }
        case _ -> {}
      }
      match dt.rangeClause {
        case None -> {}
        case Some(rb) ->
          match rb {
            case RBClosed(lo, hi)   -> checkClosed(tbl, diag, dt.name, lo, hi, "..=", dt.span)
            case RBHalfOpen(lo, hi) -> checkClosed(tbl, diag, dt.name, lo, hi, "..<", dt.span)
            case _                  -> {}
          }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Where-clause validation (T3 pre-step).
// ─────────────────────────────────────────────────────────────────────────────

func isKnownDeriveMarker(name: in String): Bool {
  name == "Add" or name == "Sub" or name == "Mul" or name == "Div" or
  name == "Mod" or name == "Compare" or name == "Hash" or
  name == "Equals" or name == "Default"
}

func isInterfaceSym(tbl: in SymbolTable, name: in String): Bool {
  match symTableTryFindOne(tbl, name) {
    case None     -> false
    case Some(sym) ->
      match sym.kind {
        case DKInterface(_, _) -> true
        case _                 -> false
      }
  }
}

func genericNamesContains(names: in List[String], name: in String): Bool {
  var i = 0
  while i < names.count {
    if names[i] == name { return true }
    i = i + 1
  }
  false
}

func checkWhereClause(
  tbl:          in SymbolTable,
  diag:         in List[Diagnostic],
  genericNames: in List[String],
  wc:           in Option[WhereClause]
): Unit {
  match wc {
    case None -> {}
    case Some(clause) -> {
      var i = 0
      while i < clause.bounds.count {
        val bound = clause.bounds[i]
        if not genericNamesContains(genericNames, bound.name) {
          diag.add(errorDiagnostic("T0050",
            "'where' clause references unknown type parameter '" + bound.name + "'",
            bound.span))
        }
        var j = 0
        while j < bound.constraints.count {
          val cr = bound.constraints[j]
          if cr.head.segments.count == 1 {
            val cname = cr.head.segments[0]
            if not isKnownDeriveMarker(cname) and not isInterfaceSym(tbl, cname) {
              diag.add(errorDiagnostic("T0051",
                "unknown constraint '" + cname + "' in 'where' clause", cr.span))
            }
          } else {
            diag.add(errorDiagnostic("T0051",
              "qualified constraint paths not yet supported in 'where' clause", cr.span))
          }
          j = j + 1
        }
        i = i + 1
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Function signature resolution (T3).
// ─────────────────────────────────────────────────────────────────────────────

func extractGenericNames(gps: in Option[GenericParams]): List[String] {
  val names: List[String] = newList()
  match gps {
    case None -> {}
    case Some(g) -> {
      var i = 0
      while i < g.params.count {
        match g.params[i] {
          case GPType(name, _)      -> names.add(name)
          case GPValue(name, _, _)  -> names.add(name)
        }
        i = i + 1
      }
    }
  }
  names
}

func resolveBounds(wc: in Option[WhereClause]): List[ResolvedBound] {
  val result: List[ResolvedBound] = newList()
  match wc {
    case None -> {}
    case Some(clause) -> {
      var i = 0
      while i < clause.bounds.count {
        val b = clause.bounds[i]
        val constraints: List[String] = newList()
        var j = 0
        while j < b.constraints.count {
          val cr = b.constraints[j]
          if cr.head.segments.count == 1 {
            constraints.add(cr.head.segments[0])
          }
          j = j + 1
        }
        result.add(ResolvedBound(name = b.name, constraints = constraints))
        i = i + 1
      }
    }
  }
  result
}

// Return true if any annotation on the function has the single-segment name `name`.
func fnHasAnnotation(fn: in FunctionDecl, name: in String): Bool {
  var i = 0
  while i < fn.annotations.count {
    val ann = fn.annotations[i]
    if ann.name.segments.count == 1 and ann.name.segments[0] == name {
      return true
    }
    i = i + 1
  }
  false
}

// Return true if any expression in the block/statement/expr tree is EYield,
// without descending into nested ELambda bodies.
// Mirror of AsyncStateMachine.bodyContainsYield; kept here because
// Lyric.TypeChecker cannot depend on Lyric.Emitter.  Keep both in sync.
func exprContainsYield(e: in Expr): Bool {
  match e.kind {
    case EYield(_)              -> true
    case ELambda(_, _)          -> false   // yield inside a lambda is not a generator yield
    case ELiteral(_)            -> false
    case EPath(_)               -> false
    case ESelf                  -> false
    case EResult                -> false
    case EError                 -> false
    case EParen(inner)          -> exprContainsYield(inner)
    case EAwait(inner)          -> exprContainsYield(inner)
    case ESpawn(inner)          -> exprContainsYield(inner)
    case EOld(inner)            -> exprContainsYield(inner)
    case EPropagate(inner)      -> exprContainsYield(inner)
    case ETry(inner)            -> exprContainsYield(inner)
    case EPrefix(_, inner)      -> exprContainsYield(inner)
    case ETuple(elems)          -> listAnyExprContainsYield(elems)
    case EList(elems)           -> listAnyExprContainsYield(elems)
    case EInterpolated(segs) -> {
      var found = false
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(se) -> { if exprContainsYield(se) { found = true } }
          case ISText(_)  -> {}
        }
        i = i + 1
      }
      found
    }
    case EBinop(_, l, r)        -> exprContainsYield(l) or exprContainsYield(r)
    case EAssign(t, _, v)       -> exprContainsYield(t) or exprContainsYield(v)
    case EMember(recv, _)       -> exprContainsYield(recv)
    case ETypeApp(f, _)         -> exprContainsYield(f)
    case EIndex(recv, idxs)     -> exprContainsYield(recv) or listAnyExprContainsYield(idxs)
    case ECall(f, args) -> {
      if exprContainsYield(f) { return true }
      var i = 0
      while i < args.count {
        val found = match args[i] {
          case CAPositional(v)   -> exprContainsYield(v)
          case CANamed(_, v, _)  -> exprContainsYield(v)
        }
        if found { return true }
        i = i + 1
      }
      false
    }
    case ERange(rb) ->
      match rb {
        case RBClosed(a, b)   -> exprContainsYield(a) or exprContainsYield(b)
        case RBHalfOpen(a, b) -> exprContainsYield(a) or exprContainsYield(b)
        case RBLowerOpen(a)   -> exprContainsYield(a)
        case RBUpperOpen(a)   -> exprContainsYield(a)
      }
    case EIf(c, t, eOpt, _) -> {
      if exprContainsYield(c) { return true }
      val inT = match t {
        case EOBExpr(te)  -> exprContainsYield(te)
        case EOBBlock(tb) -> blockContainsYield(tb)
      }
      if inT { return true }
      match eOpt {
        case None    -> false
        case Some(b) ->
          match b {
            case EOBExpr(ee)  -> exprContainsYield(ee)
            case EOBBlock(eb) -> blockContainsYield(eb)
          }
      }
    }
    case EMatch(subj, arms) -> {
      if exprContainsYield(subj) { return true }
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        val inGuard = match arm.guard {
          case None    -> false
          case Some(g) -> exprContainsYield(g)
        }
        if inGuard { return true }
        val inBody = match arm.body {
          case EOBExpr(ae)  -> exprContainsYield(ae)
          case EOBBlock(ab) -> blockContainsYield(ab)
        }
        if inBody { return true }
        i = i + 1
      }
      false
    }
    case EBlock(blk)   -> blockContainsYield(blk)
    case EUnsafe(blk)  -> blockContainsYield(blk)
    case EForall(_, w, body) -> {
      val inW = match w { case None -> false; case Some(we) -> exprContainsYield(we) }
      inW or exprContainsYield(body)
    }
    case EExists(_, w, body) -> {
      val inW = match w { case None -> false; case Some(we) -> exprContainsYield(we) }
      inW or exprContainsYield(body)
    }
  }
}

func listAnyExprContainsYield(es: in List[Expr]): Bool {
  var i = 0
  while i < es.count {
    if exprContainsYield(es[i]) { return true }
    i = i + 1
  }
  false
}

func blockContainsYield(blk: in Block): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtContainsYield(blk.statements[i]) { return true }
    i = i + 1
  }
  false
}

func stmtContainsYield(stmt: in Statement): Bool {
  match stmt.kind {
    case SExpr(e)             -> exprContainsYield(e)
    case SThrow(e)            -> exprContainsYield(e)
    case SReturn(Some(e))     -> exprContainsYield(e)
    case SReturn(None)        -> false
    case SBreak(_)            -> false
    case SContinue(_)         -> false
    case SInvariant(_)        -> false
    case SItem(_)             -> false
    case SAssign(t, _, v)     -> exprContainsYield(t) or exprContainsYield(v)
    case SLocal(binding) ->
      match binding {
        case LBVal(_, _, e)     -> exprContainsYield(e)
        case LBLet(_, _, e)     -> exprContainsYield(e)
        case LBVar(_, _, Some(e)) -> exprContainsYield(e)
        case LBVar(_, _, None)  -> false
      }
    case STry(body, catches, finally_) -> {
      if blockContainsYield(body) { return true }
      var i = 0
      while i < catches.count {
        if blockContainsYield(catches[i].body) { return true }
        i = i + 1
      }
      match finally_ {
        case None     -> false
        case Some(fb) -> blockContainsYield(fb)
      }
    }
    case SDefer(b)         -> blockContainsYield(b)
    case SScope(_, b)      -> blockContainsYield(b)
    case SLoop(_, b)       -> blockContainsYield(b)
    case SFor(_, _, iter, body) -> exprContainsYield(iter) or blockContainsYield(body)
    case SWhile(_, cond, body)  -> exprContainsYield(cond) or blockContainsYield(body)
    case SRule(l, r)       -> exprContainsYield(l) or exprContainsYield(r)
  }
}

func funcBodyContainsYield(fn: in FunctionDecl): Bool {
  match fn.body {
    case None -> false
    case Some(body) ->
      match body {
        case FBExpr(e)  -> exprContainsYield(e)
        case FBBlock(b) -> blockContainsYield(b)
      }
  }
}

func resolveFunctionSig(
  tbl:  in SymbolTable,
  diag: in List[Diagnostic],
  fn:   in FunctionDecl
): ResolvedSignature {
  val genericNames = extractGenericNames(fn.generics)
  val ctx = newGenericContext()
  if genericNames.count > 0 { gctxPush(ctx, genericNames) }

  checkWhereClause(tbl, diag, genericNames, fn.whereClause)

  val bounds = resolveBounds(fn.whereClause)

  val params: List[ResolvedParam] = newList()
  var i = 0
  while i < fn.params.count {
    val p = fn.params[i]
    val resolvedTy = resolveType(tbl, ctx, diag, p.ty)
    params.add(ResolvedParam(
      name       = p.name,
      ty         = resolvedTy,
      mode       = p.mode,
      hasDefault = match p.dflt { case None -> false; case Some(_) -> true },
      span       = p.span))
    i = i + 1
  }

  val returnTy =
    match fn.ret {
      case None     -> TyPrim(pt = PtUnit)
      case Some(te) -> resolveType(tbl, ctx, diag, te)
    }

  val isHot  = fnHasAnnotation(fn, "hot")
  val isGen  = funcBodyContainsYield(fn)

  if isGen and not fn.isAsync {
    diag.add(errorDiagnostic("T0094",
      "yield is only valid inside an async function",
      fn.span))
  }
  if isHot and fn.isAsync and isGen {
    diag.add(warningDiagnostic("T0096",
      "@hot on an async generator has no effect: the synthesised generator class uses AsyncTaskMethodBuilder, not AsyncValueTaskMethodBuilder; @hot is ignored",
      fn.span))
  }

  ResolvedSignature(
    generics    = genericNames,
    bounds      = bounds,
    params      = params,
    returnTy    = returnTy,
    isAsync     = fn.isAsync,
    isHot       = isHot,
    isGenerator = fn.isAsync and isGen,
    span        = fn.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Build signatures map for a list of items.
// ─────────────────────────────────────────────────────────────────────────────

func addSigsFromItems(
  tbl:        in SymbolTable,
  diag:       in List[Diagnostic],
  sigs:       in Map[String, ResolvedSignature],
  items:      in List[Item],
  isImported: in Bool
): Unit {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IFunc(decl) -> {
        // Imported stdlib functions don't get to shadow the codegen builtins.
        // `println`, `toString`, `panic`, `assert`, `expect`, `default`,
        // `format1`, `format2` are wired in `codegenBuiltinType` with
        // intentionally polymorphic `TyError` parameter types so that
        // ergonomic forms like `println(11)` typecheck.  The stdlib's
        // concrete `pub func println(s: in String): Unit` would, once it's
        // in the `sigs` map, win the `findDirectSig` lookup and reject the
        // Int argument with T0043.  Skipping these names for imports
        // preserves the historical advisory semantics; user code that
        // explicitly defines its own `println` still wins via the user
        // pass that follows.
        if isImported and isCodegenBuiltinName(decl.name) {
          i = i + 1
          continue
        }
        val sg = resolveFunctionSig(tbl, diag, decl)
        val arityKey = decl.name + "/" + toString(decl.params.count)
        // Sig-map insertion policy.  Imported items use first-in-wins
        // because bare-name collisions across stdlib files (e.g.
        // `toString`, `tryGet` defined in multiple modules) would
        // otherwise crash via `Dictionary.Add`'s duplicate-key throw.
        // User items run after imports and unconditionally overwrite —
        // a user-defined `pub func foo` in the same file MUST win over
        // any imported `foo` so the user's intent shadows the dep,
        // matching the standard import-shadowing semantics every other
        // languages's typechecker gives.  Once #1378's stdlib-IFunc
        // collection follow-up lands, this lets user code safely
        // redefine names that happen to overlap with the stdlib
        // (#1383).
        if isImported {
          if not sigs.containsKey(decl.name) {
            sigs.add(decl.name, sg)
          }
          if not sigs.containsKey(arityKey) {
            sigs.add(arityKey, sg)
          }
        } else {
          if sigs.containsKey(decl.name) { sigs.remove(decl.name) }
          sigs.add(decl.name, sg)
          if sigs.containsKey(arityKey) { sigs.remove(arityKey) }
          sigs.add(arityKey, sg)
        }
      }
      case _ -> {}
    }
    i = i + 1
  }
}

// Names whose typecheck behaviour is owned by `codegenBuiltinType` (see
// `typechecker_exprs.l`).  Stdlib imports must not register signatures
// under these names because their codegen path expects the polymorphic
// `TyError`-typed surface.
//
// IMPORTANT: keep this list in lock-step with `codegenBuiltinType`'s
// `name == "<...>" { ... return Some(...) }` arms in
// `typechecker_exprs.l`.  The two functions form an implicit contract —
// every name that `codegenBuiltinType` returns a polymorphic signature
// for must appear here, otherwise an imported stdlib `pub func` with
// the same simple name will shadow the builtin and tighten the call's
// argument type from `TyError` (any) to the stdlib's concrete shape
// (#1384).
func isCodegenBuiltinName(name: in String): Bool {
  name == "println"
    or name == "toString"
    or name == "panic"
    or name == "default"
    or name == "expect"
    or name == "assert"
    or name == "format1"
    or name == "format2"
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Public entry points.
// ─────────────────────────────────────────────────────────────────────────────

pub func checkWithImports(
  file:          in SourceFile,
  importedItems: in List[Item]
): CheckResult {
  val diag: List[Diagnostic] = newList()
  val tbl  = newSymbolTable()
  val ctr  = newTypeIdCounter()

  // T1: register imported items first (shadow without error).
  var i = 0
  while i < importedItems.count {
    registerItem(tbl, ctr, diag, true, importedItems[i])
    i = i + 1
  }
  var j = 0
  while j < file.items.count {
    registerItem(tbl, ctr, diag, false, file.items[j])
    j = j + 1
  }

  // T2.5: validate range subtypes.
  var k = 0
  while k < file.items.count {
    match file.items[k].kind {
      case IDistinctType(decl) -> checkDistinctType(tbl, diag, decl)
      case _                   -> {}
    }
    k = k + 1
  }

  // T3: resolve signatures (imported + user).
  //
  // Imported-item signature resolution runs against a *scratch* diagnostic
  // list so that internal stdlib type references the bridge can't satisfy
  // (e.g. obscure kernel-internal types like `Scope`, or wire-shape gaps
  // the self-hosted typechecker hasn't grown coverage for yet) don't pollute
  // the user package's diagnostics and trip `reportAndAbort` on a build the
  // user authored cleanly.  The signatures are still recorded in `sigs`
  // (with `TyError` for any unresolved type refs); the user's typecheck
  // can still call any stdlib function whose signature *does* resolve, and
  // codegen tolerates residual `TyError` via the existing fallback paths.
  val sigs: Map[String, ResolvedSignature] = newMap()
  val importedDiag: List[Diagnostic] = newList()
  addSigsFromItems(tbl, importedDiag, sigs, importedItems, true)
  addSigsFromItems(tbl, diag, sigs, file.items, false)

  // T5: check user function bodies.
  var m = 0
  while m < file.items.count {
    match file.items[m].kind {
      case IFunc(decl) -> {
        val arityKey = decl.name + "/" + toString(decl.params.count)
        match mapGet(sigs, arityKey) {
          case Some(sig) -> checkFunctionBody(tbl, sigs, diag, decl, sig)
          case None      ->
            match mapGet(sigs, decl.name) {
              case Some(sig) -> checkFunctionBody(tbl, sigs, diag, decl, sig)
              case None      -> {}
            }
        }
      }
      case _ -> {}
    }
    m = m + 1
  }

  CheckResult(
    file        = file,
    symbols     = tbl,
    sigs        = sigs,
    diagnostics = diag)
}

pub func check(file: in SourceFile): CheckResult {
  val empty: List[Item] = newList()
  checkWithImports(file, empty)
}
