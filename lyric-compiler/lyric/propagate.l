// propagate.l — Lyric.Propagate
//
// Band 2 (docs/41 §9, issue #1475): error-propagation lowering for the `?`
// operator.  Until this pass existed the MSIL backend lowered `EPropagate`
// as a pass-through (`x?` compiled as `x`), a silent miscompile of every
// program using `?`.
//
// This pass runs in the middle-end (after the contract elaborator, before
// derive/mono/weave) and rewrites every `e?` into a `match` that unwraps the
// success value and early-returns the failure from the enclosing function.
// The monad is keyed off the enclosing function's declared return type, per
// the language-reference §4.5 rule that "the signature must declare a
// compatible return type, or the compiler rejects the use":
//
//   * Function returns `Result[T, E]` — `e?` becomes
//         match e { case Ok(v)  -> v
//                   case Err(x) -> { return Err(x) } }
//
//   * Function returns `Option[T]` — `e?` becomes
//         match e { case Some(v) -> v
//                   case None    -> { return None } }
//
// The synthesised AST mirrors exactly what the parser produces for a
// hand-written `match` / `return`, so codegen lowers it through the same
// (well-tested) machinery: `lowerMatchExprMsil` already reconciles an
// early-return arm with a value-producing fall-through arm, and the
// reconstructed `Err(x)` / `None` constructors pick up their concrete type
// arguments from `fctx.declaredRetTy` exactly as a user-written
// `return Err(x)` / `return None` does.
//
// Running after the elaborator (not before) keeps the `?` error path out of
// the `ensures:` rewrite: a propagated `Err` / `None` is a short-circuit, not
// the function's intended result, so it must not be asserted against the
// success-shaped post-condition.
//
// When `?` appears in a function whose return type is neither `Result` nor
// `Option` (or inside a lambda, whose return monad the backend cannot yet
// determine), the pass emits a hard `F0020` diagnostic instead of a silent
// pass-through.  Nullable (`T?`) propagation is not yet lowered and takes the
// same diagnostic; it is tracked as a follow-up.
//
// Public surface:
//
//   pub func lowerPropagateFile(file: in SourceFile): PropagateResult
//
//     Returns a new SourceFile with every `?` desugared, plus any F0020
//     diagnostics.  The input is not mutated.

package Lyric.Propagate

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser


// ─────────────────────────────────────────────────────────────────────────────
// §1. Result type + threaded state.
// ─────────────────────────────────────────────────────────────────────────────

pub record PropagateResult {
  file:        SourceFile
  diagnostics: List[Diagnostic]
}

// Which propagation monad the enclosing function declares.
union PropKind {
  case PropResult
  case PropOption
  case PropOther
  // Lambda body — the lambda's own return monad is unknown; `?` here gets a lambda-specific F0020.
  case PropInLambda
}

// Mutable state threaded through the walk by reference.  `counter` is a
// growable cell: its `.count` is the next fresh-name index (the same idiom
// codegen uses for `slotTicker`), so a plain `in` reference suffices to
// mutate it — no `inout` plumbing through the recursion.
record PropState {
  counter:     List[Int]
  diagnostics: List[Diagnostic]
}

func newPropState(diags: in List[Diagnostic]): PropState {
  PropState(counter = newList(), diagnostics = diags)
}

func freshSuffix(st: in PropState): String {
  val n = st.counter.count
  st.counter.add(0)
  toString(n)
}


// ─────────────────────────────────────────────────────────────────────────────
// §2. AST builders.  Every fragment is stamped at the `?` operator's span so
//     downstream diagnostics keep pointing at user code.
// ─────────────────────────────────────────────────────────────────────────────

func mkPath(name: in String, sp: in Span): ModulePath {
  val segs: List[String] = newList()
  segs.add(name)
  ModulePath(segments = segs, span = sp)
}

func pathExpr(name: in String, sp: in Span): Expr {
  mkExpr(EPath(path = mkPath(name, sp)), sp)
}

// A single-binding pattern argument list, e.g. the `v` in `Ok(v)`.
func bindArg(name: in String, sp: in Span): List[Pattern] {
  val noInner: Option[Pattern] = None
  val args: List[Pattern] = newList()
  args.add(mkPat(PBinding(name = name, inner = noInner), sp))
  args
}

func posArg(e: in Expr): List[CallArg] {
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = e))
  args
}

func singleStmtBlock(s: in Statement, sp: in Span): Block {
  val stmts: List[Statement] = newList()
  stmts.add(s)
  Block(statements = stmts, span = sp)
}

// `match inner { case Ok(v) -> v; case Err(x) -> { return Err(x) } }`
func buildResultMatch(inner: in Expr, sp: in Span, st: in PropState): Expr {
  val vName = "__lyric_prop_v" + freshSuffix(st)
  val eName = "__lyric_prop_e" + freshSuffix(st)

  val okPat  = mkPat(PConstructor(head = mkPath("Ok", sp), args = bindArg(vName, sp)), sp)
  val okBody: ExprOrBlock = EOBExpr(expr = pathExpr(vName, sp))
  val okArm  = MatchArm(pattern = okPat, guard = None, body = okBody, span = sp)

  val errPat  = mkPat(PConstructor(head = mkPath("Err", sp), args = bindArg(eName, sp)), sp)
  val errCall = mkExpr(ECall(fn = pathExpr("Err", sp), args = posArg(pathExpr(eName, sp))), sp)
  val errRet  = mkStmt(SReturn(value = Some(value = errCall)), sp)
  val errBody: ExprOrBlock = EOBBlock(block = singleStmtBlock(errRet, sp))
  val errArm  = MatchArm(pattern = errPat, guard = None, body = errBody, span = sp)

  val arms: List[MatchArm] = newList()
  arms.add(okArm)
  arms.add(errArm)
  mkExpr(EMatch(scrutinee = inner, arms = arms), sp)
}

// `match inner { case Some(v) -> v; case None -> { return None } }`
func buildOptionMatch(inner: in Expr, sp: in Span, st: in PropState): Expr {
  val vName = "__lyric_prop_v" + freshSuffix(st)

  val somePat  = mkPat(PConstructor(head = mkPath("Some", sp), args = bindArg(vName, sp)), sp)
  val someBody: ExprOrBlock = EOBExpr(expr = pathExpr(vName, sp))
  val someArm  = MatchArm(pattern = somePat, guard = None, body = someBody, span = sp)

  // A bare `case None` parses as a PBinding the codegen recognises as the
  // nullary union case (see `lowerPatternTestMsil`); mirror that exactly.
  val noneInner: Option[Pattern] = None
  val nonePat  = mkPat(PBinding(name = "None", inner = noneInner), sp)
  val noneRet  = mkStmt(SReturn(value = Some(value = pathExpr("None", sp))), sp)
  val noneBody: ExprOrBlock = EOBBlock(block = singleStmtBlock(noneRet, sp))
  val noneArm  = MatchArm(pattern = nonePat, guard = None, body = noneBody, span = sp)

  val arms: List[MatchArm] = newList()
  arms.add(someArm)
  arms.add(noneArm)
  mkExpr(EMatch(scrutinee = inner, arms = arms), sp)
}


// ─────────────────────────────────────────────────────────────────────────────
// §3. Monad classification from a declared return type.
// ─────────────────────────────────────────────────────────────────────────────

func lastSegment(path: in ModulePath): String {
  if path.segments.count == 0 { "" }
  else { path.segments[path.segments.count - 1] }
}

// Known limitation (#1814): matches terminal segment only — type aliases for `Result`/`Option`
// (e.g. `alias ParseResult[T] = Result[T, ParseError]`) yield `PropOther` and trip a
// false F0020.  Workaround until an alias-resolution pass lands: write `Result[T, E]` directly.
func monadOfRet(ret: in Option[TypeExpr]): PropKind {
  match ret {
    case None -> PropOther
    case Some(te) -> match te.kind {
      case TGenericApp(head, args) -> {
        val h = lastSegment(head)
        if h == "Result" and args.count == 2 { PropResult }
        else if h == "Option" and args.count == 1 { PropOption }
        else { PropOther }
      }
      case TParen(inner) -> monadOfRet(Some(value = inner))
      case _ -> PropOther
    }
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// §4. Expression / statement / block rewriters.
//
//     Every form is reconstructed with its children rewritten so a `?` at
//     any depth is found.  Lambda bodies switch to `PropOther` because the
//     lambda's return monad is independent of the enclosing function (and the
//     backend does not yet type lambda returns); a `?` inside one therefore
//     produces the F0020 diagnostic rather than a wrong rewrite.
// ─────────────────────────────────────────────────────────────────────────────

func rewriteEob(eob: in ExprOrBlock, kind: in PropKind, st: in PropState): ExprOrBlock {
  match eob {
    case EOBExpr(e)    -> EOBExpr(expr = rewriteExpr(e, kind, st))
    case EOBBlock(blk) -> EOBBlock(block = rewriteBlock(blk, kind, st))
  }
}

func rewriteExprList(es: in List[Expr], kind: in PropKind, st: in PropState): List[Expr] {
  val acc: List[Expr] = newList()
  var i = 0
  while i < es.count {
    acc.add(rewriteExpr(es[i], kind, st))
    i = i + 1
  }
  acc
}

func rewriteExpr(e: in Expr, kind: in PropKind, st: in PropState): Expr {
  match e.kind {
    case EPropagate(inner) -> {
      val inner2 = rewriteExpr(inner, kind, st)
      match kind {
        case PropResult   -> buildResultMatch(inner2, e.span, st)
        case PropOption   -> buildOptionMatch(inner2, e.span, st)
        case PropInLambda -> {
          st.diagnostics.add(errorDiagnostic("F0020",
            "the `?` operator is not yet supported inside a lambda body (the lambda's return type cannot be inferred; use an explicit `match` instead)",
            e.span))
          inner2
        }
        case PropOther    -> {
          st.diagnostics.add(errorDiagnostic("F0020",
            "the `?` operator requires the enclosing function to return Result[T, E] or Option[T]",
            e.span))
          inner2
        }
      }
    }

    // ── Leaves — nothing to rewrite ──────────────────────────────────────────
    case ELiteral(_) -> e
    case EPath(_)    -> e
    case ESelf       -> e
    case EResult     -> e
    case EError      -> e

    // ── Recurse into children ────────────────────────────────────────────────
    case EParen(inner) -> mkExpr(EParen(inner = rewriteExpr(inner, kind, st)), e.span)
    case ETuple(exprs) -> mkExpr(ETuple(exprs = rewriteExprList(exprs, kind, st)), e.span)
    case EList(exprs)  -> mkExpr(EList(exprs = rewriteExprList(exprs, kind, st)), e.span)

    case EIf(cond, thenBranch, elseOpt, thenForm) -> {
      val newElse: Option[ExprOrBlock] = match elseOpt {
        case Some(eb) -> Some(value = rewriteEob(eb, kind, st))
        case None     -> None
      }
      mkExpr(EIf(
        cond       = rewriteExpr(cond, kind, st),
        thenBranch = rewriteEob(thenBranch, kind, st),
        elseBranch = newElse,
        thenForm   = thenForm), e.span)
    }

    case EMatch(scrutinee, arms) -> {
      val newArms: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        val newGuard: Option[Expr] = match arm.guard {
          case Some(g) -> Some(value = rewriteExpr(g, kind, st))
          case None    -> None
        }
        newArms.add(MatchArm(
          pattern = arm.pattern,
          guard   = newGuard,
          body    = rewriteEob(arm.body, kind, st),
          span    = arm.span))
        i = i + 1
      }
      mkExpr(EMatch(scrutinee = rewriteExpr(scrutinee, kind, st), arms = newArms), e.span)
    }

    case EAwait(inner) -> mkExpr(EAwait(inner = rewriteExpr(inner, kind, st)), e.span)
    case EYield(inner) -> mkExpr(EYield(inner = rewriteExpr(inner, kind, st)), e.span)
    case ESpawn(inner) -> mkExpr(ESpawn(inner = rewriteExpr(inner, kind, st)), e.span)
    case ETry(inner)   -> mkExpr(ETry(inner = rewriteExpr(inner, kind, st)), e.span)
    case EOld(inner)   -> mkExpr(EOld(inner = rewriteExpr(inner, kind, st)), e.span)

    case EForall(binders, whereOpt, body) -> {
      val newWhere: Option[Expr] = match whereOpt {
        case Some(w) -> Some(value = rewriteExpr(w, kind, st))
        case None    -> None
      }
      mkExpr(EForall(binders = binders, whereExpr = newWhere,
                     body = rewriteExpr(body, kind, st)), e.span)
    }
    case EExists(binders, whereOpt, body) -> {
      val newWhere: Option[Expr] = match whereOpt {
        case Some(w) -> Some(value = rewriteExpr(w, kind, st))
        case None    -> None
      }
      mkExpr(EExists(binders = binders, whereExpr = newWhere,
                     body = rewriteExpr(body, kind, st)), e.span)
    }

    // Lambdas carry their own return monad — switch to PropInLambda so a `?` inside surfaces the lambda-specific F0020 instead of the enclosing function's.
    case ELambda(lambdaParams, body) ->
      mkExpr(ELambda(lambdaParams = lambdaParams,
                     body = rewriteBlock(body, PropInLambda, st)), e.span)

    case ECall(fn, args) -> {
      val newArgs: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(v)     -> newArgs.add(CAPositional(expr = rewriteExpr(v, kind, st)))
          case CANamed(n, v, asp)  -> newArgs.add(CANamed(name = n, value = rewriteExpr(v, kind, st), span = asp))
        }
        i = i + 1
      }
      mkExpr(ECall(fn = rewriteExpr(fn, kind, st), args = newArgs), e.span)
    }

    case ETypeApp(fn, args) -> mkExpr(ETypeApp(fn = rewriteExpr(fn, kind, st), args = args), e.span)

    case EIndex(receiver, indices) ->
      mkExpr(EIndex(receiver = rewriteExpr(receiver, kind, st),
                    indices = rewriteExprList(indices, kind, st)), e.span)

    case EMember(receiver, memberName) ->
      mkExpr(EMember(receiver = rewriteExpr(receiver, kind, st), memberName = memberName), e.span)

    case EPrefix(op, operand) ->
      mkExpr(EPrefix(op = op, operand = rewriteExpr(operand, kind, st)), e.span)

    case EBinop(op, lhs, rhs) ->
      mkExpr(EBinop(op = op, lhs = rewriteExpr(lhs, kind, st), rhs = rewriteExpr(rhs, kind, st)), e.span)

    case ERange(bound) -> mkExpr(ERange(bound = rewriteRangeBound(bound, kind, st)), e.span)

    case EAssign(target, op, value) ->
      mkExpr(EAssign(target = rewriteExpr(target, kind, st), op = op,
                     value = rewriteExpr(value, kind, st)), e.span)

    case EBlock(block)  -> mkExpr(EBlock(block = rewriteBlock(block, kind, st)), e.span)
    case EUnsafe(block) -> mkExpr(EUnsafe(block = rewriteBlock(block, kind, st)), e.span)

    case EInterpolated(segments) -> {
      val newSegs: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISText(t, sp) -> newSegs.add(ISText(text = t, span = sp))
          case ISExpr(ex)    -> newSegs.add(ISExpr(expr = rewriteExpr(ex, kind, st)))
        }
        i = i + 1
      }
      mkExpr(EInterpolated(segments = newSegs), e.span)
    }
  }
}

func rewriteRangeBound(b: in RangeBound, kind: in PropKind, st: in PropState): RangeBound {
  match b {
    case RBClosed(lo, hi)   -> RBClosed(lo = rewriteExpr(lo, kind, st), hi = rewriteExpr(hi, kind, st))
    case RBHalfOpen(lo, hi) -> RBHalfOpen(lo = rewriteExpr(lo, kind, st), hi = rewriteExpr(hi, kind, st))
    case RBLowerOpen(hi)    -> RBLowerOpen(hi = rewriteExpr(hi, kind, st))
    case RBUpperOpen(lo)    -> RBUpperOpen(lo = rewriteExpr(lo, kind, st))
  }
}

func rewriteBinding(b: in LocalBinding, kind: in PropKind, st: in PropState): LocalBinding {
  match b {
    case LBVal(pat, ty, init) -> LBVal(pat = pat, ty = ty, init = rewriteExpr(init, kind, st))
    case LBLet(name, ty, init) -> LBLet(name = name, ty = ty, init = rewriteExpr(init, kind, st))
    case LBVar(name, ty, initOpt) -> {
      val newInit: Option[Expr] = match initOpt {
        case Some(e) -> Some(value = rewriteExpr(e, kind, st))
        case None    -> None
      }
      LBVar(name = name, ty = ty, init = newInit)
    }
  }
}

func rewriteCatch(c: in CatchClause, kind: in PropKind, st: in PropState): CatchClause {
  CatchClause(typeName = c.typeName, bindName = c.bindName,
              body = rewriteBlock(c.body, kind, st), span = c.span)
}

func rewriteStmt(s: in Statement, kind: in PropKind, st: in PropState): Statement {
  match s.kind {
    case SLocal(binding) -> mkStmt(SLocal(binding = rewriteBinding(binding, kind, st)), s.span)
    case SAssign(target, op, value) ->
      mkStmt(SAssign(target = rewriteExpr(target, kind, st), op = op,
                     value = rewriteExpr(value, kind, st)), s.span)
    case SReturn(valOpt) -> {
      val newVal: Option[Expr] = match valOpt {
        case Some(e) -> Some(value = rewriteExpr(e, kind, st))
        case None    -> None
      }
      mkStmt(SReturn(value = newVal), s.span)
    }
    case SBreak(_)    -> s
    case SContinue(_) -> s
    case SThrow(ex)   -> mkStmt(SThrow(expr = rewriteExpr(ex, kind, st)), s.span)
    case STry(body, catches, finallyOpt) -> {
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        newCatches.add(rewriteCatch(catches[i], kind, st))
        i = i + 1
      }
      val newFinally: Option[Block] = match finallyOpt {
        case Some(fb) -> Some(value = rewriteBlock(fb, kind, st))
        case None     -> None
      }
      mkStmt(STry(body = rewriteBlock(body, kind, st), catches = newCatches, finally_ = newFinally), s.span)
    }
    case SDefer(body)        -> mkStmt(SDefer(body = rewriteBlock(body, kind, st)), s.span)
    case SScope(binding, body) -> mkStmt(SScope(binding = binding, body = rewriteBlock(body, kind, st)), s.span)
    case SFor(label, pat, iter, body) ->
      mkStmt(SFor(label = label, pat = pat, iter = rewriteExpr(iter, kind, st),
                  body = rewriteBlock(body, kind, st)), s.span)
    case SWhile(label, cond, body) ->
      mkStmt(SWhile(label = label, cond = rewriteExpr(cond, kind, st),
                    body = rewriteBlock(body, kind, st)), s.span)
    case SLoop(label, body) -> mkStmt(SLoop(label = label, body = rewriteBlock(body, kind, st)), s.span)
    case SInvariant(ex)     -> mkStmt(SInvariant(expr = rewriteExpr(ex, kind, st)), s.span)
    case SExpr(ex)          -> mkStmt(SExpr(expr = rewriteExpr(ex, kind, st)), s.span)
    case SRule(lhs, rhs)    -> mkStmt(SRule(lhs = rewriteExpr(lhs, kind, st), rhs = rewriteExpr(rhs, kind, st)), s.span)
    // A nested item re-derives its own monad context.
    case SItem(item)        -> mkStmt(SItem(item = rewriteItem(item, st)), s.span)
  }
}

func rewriteBlock(blk: in Block, kind: in PropKind, st: in PropState): Block {
  val acc: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    acc.add(rewriteStmt(blk.statements[i], kind, st))
    i = i + 1
  }
  Block(statements = acc, span = blk.span)
}


// ─────────────────────────────────────────────────────────────────────────────
// §5. Function / item drivers.
// ─────────────────────────────────────────────────────────────────────────────

func rewriteFunctionBody(body: in FunctionBody, kind: in PropKind, st: in PropState): FunctionBody {
  match body {
    case FBExpr(e)    -> FBExpr(expr = rewriteExpr(e, kind, st))
    case FBBlock(blk) -> FBBlock(block = rewriteBlock(blk, kind, st))
  }
}

func rewriteFunction(fn: in FunctionDecl, st: in PropState): FunctionDecl {
  match fn.body {
    case None -> fn
    case Some(body) -> {
      val kind = monadOfRet(fn.ret)
      FunctionDecl(
        docComments = fn.docComments,
        annotations = fn.annotations,
        visibility  = fn.visibility,
        isAsync     = fn.isAsync,
        name        = fn.name,
        generics    = fn.generics,
        params      = fn.params,
        ret         = fn.ret,
        whereClause = fn.whereClause,
        contracts   = fn.contracts,
        body        = Some(value = rewriteFunctionBody(body, kind, st)),
        span        = fn.span)
    }
  }
}

func rewriteEntry(ed: in EntryDecl, st: in PropState): EntryDecl {
  val kind = monadOfRet(ed.ret)
  EntryDecl(
    docComments = ed.docComments,
    annotations = ed.annotations,
    visibility  = ed.visibility,
    name        = ed.name,
    params      = ed.params,
    ret         = ed.ret,
    contracts   = ed.contracts,
    body        = rewriteFunctionBody(ed.body, kind, st),
    span        = ed.span)
}

func rewriteItem(it: in Item, st: in PropState): Item {
  val newKind: ItemKind = match it.kind {
    case IFunc(fn) -> IFunc(decl = rewriteFunction(fn, st))

    case IImpl(decl) -> {
      val newMembers: List[ImplMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMplFunc(fn)    -> newMembers.add(IMplFunc(fn = rewriteFunction(fn, st)))
          case IMplAssoc(asc)  -> newMembers.add(IMplAssoc(assoc = asc))
        }
        i = i + 1
      }
      IImpl(decl = ImplDecl(
        generics    = decl.generics,
        iface       = decl.iface,
        target      = decl.target,
        whereClause = decl.whereClause,
        members     = newMembers,
        span        = decl.span))
    }

    case IInterface(decl) -> {
      val newMembers: List[InterfaceMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMFunc(fn)  -> newMembers.add(IMFunc(fn = rewriteFunction(fn, st)))
          case IMSig(sig)  -> newMembers.add(IMSig(sig = sig))
          case IMAssoc(a)  -> newMembers.add(IMAssoc(assoc = a))
        }
        i = i + 1
      }
      IInterface(decl = InterfaceDecl(
        name        = decl.name,
        generics    = decl.generics,
        whereClause = decl.whereClause,
        members     = newMembers,
        span        = decl.span))
    }

    case IProtected(decl) -> {
      val newMembers: List[ProtectedMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case PMFunc(fn)     -> newMembers.add(PMFunc(fn = rewriteFunction(fn, st)))
          case PMEntry(ed)    -> newMembers.add(PMEntry(entryDecl = rewriteEntry(ed, st)))
          case PMField(f)     -> newMembers.add(PMField(field = f))
          case PMInvariant(v) -> newMembers.add(PMInvariant(inv = v))
        }
        i = i + 1
      }
      IProtected(decl = ProtectedTypeDecl(
        name        = decl.name,
        generics    = decl.generics,
        whereClause = decl.whereClause,
        members     = newMembers,
        span        = decl.span))
    }

    case _ -> it.kind
  }
  Item(
    docComments = it.docComments,
    annotations = it.annotations,
    visibility  = it.visibility,
    kind        = newKind,
    span        = it.span)
}


// ─────────────────────────────────────────────────────────────────────────────
// §6. Public entry point.
// ─────────────────────────────────────────────────────────────────────────────

pub func lowerPropagateFile(file: in SourceFile): PropagateResult {
  val diags: List[Diagnostic] = newList()
  val st = newPropState(diags)
  val newItems: List[Item] = newList()
  var i = 0
  while i < file.items.count {
    newItems.add(rewriteItem(file.items[i], st))
    i = i + 1
  }
  val newFile = SourceFile(
    moduleDoc       = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl     = file.packageDecl,
    imports         = file.imports,
    items           = newItems,
    span            = file.span)
  PropagateResult(file = newFile, diagnostics = diags)
}
