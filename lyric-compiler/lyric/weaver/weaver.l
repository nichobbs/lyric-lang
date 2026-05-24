// weaver.l — Lyric.Weaver
//
// Self-hosted port of bootstrap/src/Lyric.Emitter/Weaver.fs (A1/A2/A3/A4).
// Transforms a SourceFile's item list before downstream stages:
//
//   1. Collects every IAspect item with an `around` body.
//   2. Matches each IFunc against the aspect's `matches:` predicates,
//      respecting `@no_aspect` and `@no_aspect("Name")` opt-outs.
//   3. For each matched function, renames the original to
//      `<name>__aspect_target`, sorts the matching aspects by `wraps:` /
//      `inside:` clauses (lexical order as the tiebreak), and splices in
//      a chain of wrapper IFuncs — innermost calls the renamed target,
//      outermost keeps the original name. Wrapper contracts are the
//      composed `aspect.contracts ++ original.contracts` per §5 of
//      `docs/26-aspects.md`.
//   4. IAspect items are dropped from the resulting item list.
//
// Feature wiring beyond F# parity (todo/06):
//
//   - `config { }` block values (#683): each `ConfigField` with a literal
//     default is materialised as a synthetic `val __aspect_cfg_<name>`
//     local at the top of the woven body; `config.<name>` member accesses
//     in the aspect body are rewritten to that local.  Fields without a
//     default are skipped (env-var resolution at startup is a follow-up).
//
//   - Ambient `call` value (#682): the woven body sees compile-time-known
//     constants for `call.shortName`, `call.qualifiedName`,
//     `call.modulePath`, `call.sourceLocation`, and `call.annotations`,
//     materialised as `__lyric_call_<name>` locals.  `call.aspect` is
//     also injected (the current aspect's name).  `call.elapsed` and
//     `call.caller` require runtime instrumentation (Std.Time integration
//     and call-site capture) that is deferred to a follow-up.  Any
//     `call.<unknown>` reference — including those two — surfaces as
//     an A0043 diagnostic at weave time so users get a clear message
//     instead of a downstream "undeclared call" type error.
//
//   - `@inline_template` (#681): aspects annotated `@inline_template`
//     have `args.<field>` rewrites applied at weave time; each field
//     name must match a parameter of the matched function (otherwise a
//     diagnostic A0042 is emitted).  Non-template aspects continue to
//     reject `args.<field>` references downstream — this matches the
//     parity contract with the F# weaver.
//
// Used by the verifier driver so `lyric prove` discharges contracts on
// the woven body (not the parsed body). Closes #336.
//
// Glob syntax: `*`, `?`, `[abc]`, `[a-z]`; other chars literal.
package Lyric.Weaver

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Std.Char as Char

// ─────────────────────────────────────────────────────────────────────────────
// §1. Glob matching (POSIX-ish subset).
// ─────────────────────────────────────────────────────────────────────────────

pub func globMatch(glob: in String, name: in String): Bool {
  globMatchAt(glob, 0, name, 0)
}

func globMatchAt(glob: in String, gi: in Int, name: in String, ni: in Int): Bool {
  if gi == glob.length and ni == name.length { return true }
  if gi == glob.length { return false }
  val g = glob[gi]
  if g == '*' {
    var k = ni
    while k <= name.length {
      if globMatchAt(glob, gi + 1, name, k) { return true }
      k = k + 1
    }
    return false
  }
  if g == '?' {
    if ni >= name.length { return false }
    return globMatchAt(glob, gi + 1, name, ni + 1)
  }
  if g == '[' {
    var j = gi + 1
    var found = false
    var closed = false
    while j < glob.length and not closed {
      val c = glob[j]
      if c == ']' {
        closed = true
      } else if j + 2 < glob.length and glob[j + 1] == '-' and glob[j + 2] != ']' {
        if ni < name.length {
          val nc = name[ni]
          val ncI = Char.toInt(nc)
          if ncI >= Char.toInt(c) and ncI <= Char.toInt(glob[j + 2]) { found = true }
        }
        j = j + 3
      } else {
        if ni < name.length and c == name[ni] { found = true }
        j = j + 1
      }
    }
    if found and closed { return globMatchAt(glob, j + 1, name, ni + 1) }
    return false
  }
  if ni >= name.length { return false }
  if g != name[ni] { return false }
  globMatchAt(glob, gi + 1, name, ni + 1)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Synthetic AST nodes built at a zero span.
// ─────────────────────────────────────────────────────────────────────────────

func synSpan(): Span {
  makeSpan(initialPosition(), initialPosition())
}

func makePathExpr(segments: in List[String]): Expr {
  val sp = synSpan()
  val mp = ModulePath(segments = segments, span = sp)
  Expr(kind = EPath(path = mp), span = sp)
}

func singleSegPathExpr(name: in String): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  makePathExpr(segs)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Rewrite the aspect `around` body for one weave site.
//
//     The rewriter performs four orthogonal substitutions in a single
//     bottom-up pass, threading state through `RewriteCtx`:
//
//       proceed(args)        → callTargetName(p1, p2, ...)
//       config.<field>       → __aspect_cfg_<field>     (#683)
//       call.<field>         → __lyric_call_<field>     (#682)
//       args.<field>         → <field>                  (#681, @inline_template)
//
//     Mirrors Weaver.fs rewriteProceeds plus the todo/06 extensions.
// ─────────────────────────────────────────────────────────────────────────────

/// Per-weave-site rewrite state.  All four substitutions consult this
/// record; unused features are signalled by empty lists.
record RewriteCtx {
  /// Name of the renamed `__aspect_target` (or the next-inner wrapper)
  /// that `proceed(args)` substitutes to.
  targetName:       String
  /// Parameter names of the matched function, forwarded as positional
  /// args by `proceed(args)`.
  paramNames:       List[String]
  /// Config field names that have a literal default in the aspect's
  /// `config { }` block.  `config.<n>` member accesses for these names
  /// are rewritten to `__aspect_cfg_<n>` paths (#683).
  configFields:     Map[String, Bool]
  /// Call-context field names that the weaver materialises into
  /// `__lyric_call_<n>` locals.  `call.<n>` for these names rewrites
  /// to the local; other `call.<n>` accesses pass through unchanged
  /// (the type checker will flag them) (#682).
  callFields:       Map[String, Bool]
  /// True when the matching aspect carries `@inline_template`.  In that
  /// mode `args.<n>` is rewritten to `<n>` (parameter name) when `<n>`
  /// is in `paramNames`; missing names accumulate as diagnostics in
  /// `argsErrors` (#681).
  isInlineTemplate: Bool
  /// Short name of the aspect being woven (for diagnostic messages).
  aspectName:       String
  /// Short name of the matched function (for diagnostic messages).
  funcName:         String
  /// Accumulator for weave-time diagnostics:
  ///   - A0042 — `@inline_template` `args.<n>` does not match a
  ///             parameter of the matched function (#681).
  ///   - A0043 — `call.<n>` references an unknown context field
  ///             (e.g. `call.elapsed` before runtime instrumentation
  ///             lands; #682 follow-up).
  argsErrors:       List[WeaveDiagEntry]
}

/// Discriminator + payload for a weave-time diagnostic.  Two kinds
/// today; new kinds can be added without changing the rewriter's
/// signature.
union WeaveDiagKind {
  case WDArgsMismatch  // A0042
  case WDCallUnknown   // A0043
}

record WeaveDiagEntry {
  kind:       WeaveDiagKind
  aspectName: String
  funcName:   String
  fieldName:  String
  span:       Span
}

func newRewriteCtx(
  targetName:       in String,
  paramNames:       in List[String],
  configFields:     in Map[String, Bool],
  callFields:       in Map[String, Bool],
  isInlineTemplate: in Bool,
  aspectName:       in String,
  funcName:         in String,
  argsErrors:       in List[WeaveDiagEntry]
): RewriteCtx {
  RewriteCtx(
    targetName       = targetName,
    paramNames       = paramNames,
    configFields     = configFields,
    callFields       = callFields,
    isInlineTemplate = isInlineTemplate,
    aspectName       = aspectName,
    funcName         = funcName,
    argsErrors       = argsErrors)
}

/// Build an empty context that only performs proceed substitution.
/// Used by callers that don't need the new wiring (kept for
/// backwards-compatible call sites and the verifier-driver default).
func emptyRewriteCtx(targetName: in String, paramNames: in List[String]): RewriteCtx {
  val noConfig: Map[String, Bool] = newMap()
  val noCall:   Map[String, Bool] = newMap()
  val noErrs:   List[WeaveDiagEntry]   = newList()
  newRewriteCtx(targetName, paramNames, noConfig, noCall, false, "", "", noErrs)
}

func isProceedCall(expr: in Expr): Bool {
  match expr.kind {
    case ECall(f, _) -> {
      match f.kind {
        case EPath(path) ->
          path.segments.count == 1 and path.segments[0] == "proceed"
        case _ -> false
      }
    }
    case _ -> false
  }
}

func proceedSubstitution(targetName: in String, paramNames: in List[String]): Expr {
  val argExprs: List[CallArg] = newList()
  var i = 0
  while i < paramNames.count {
    argExprs.add(CAPositional(expr = singleSegPathExpr(paramNames[i])))
    i = i + 1
  }
  Expr(
    kind = ECall(fn = singleSegPathExpr(targetName), args = argExprs),
    span = synSpan())
}

/// Detect `receiver.<member>` where `receiver` is a bare `name`
/// path (single-segment, no module prefix).  Returns Some(memberName)
/// when the receiver matches; None otherwise.  Used to recognise the
/// special `config.<f>` / `call.<f>` / `args.<f>` patterns.
func matchBareMemberAccess(expr: in Expr, receiverName: in String): Option[String] {
  match expr.kind {
    case EMember(recv, member) -> {
      match recv.kind {
        case EPath(path) -> {
          if path.segments.count == 1 and path.segments[0] == receiverName {
            Some(value = member)
          } else { None }
        }
        case _ -> None
      }
    }
    case _ -> None
  }
}

/// True if a `config`, `call`, or `args` rewrite applies to this expr
/// at the top level.  Lets `rewriteExpr` bail out early before
/// recursing into receivers we are about to replace.
func tryMemberRewrite(ctx: in RewriteCtx, expr: in Expr): Option[Expr] {
  // config.<field> → __aspect_cfg_<field>
  match matchBareMemberAccess(expr, "config") {
    case Some(name) -> {
      if ctx.configFields.containsKey(name) {
        return Some(value = Expr(
          kind = EPath(path = ModulePath(
            segments = singleSeg("__aspect_cfg_" + name),
            span     = expr.span)),
          span = expr.span))
      }
    }
    case None -> ()
  }
  // call.<field> → __lyric_call_<field>
  match matchBareMemberAccess(expr, "call") {
    case Some(name) -> {
      if ctx.callFields.containsKey(name) {
        return Some(value = Expr(
          kind = EPath(path = ModulePath(
            segments = singleSeg("__lyric_call_" + name),
            span     = expr.span)),
          span = expr.span))
      } else {
        // Unknown call.<field> — surface as A0043 so the user sees a
        // weaver-targeted message instead of a downstream "call is not
        // declared" type error (#682 / review #1193).
        ctx.argsErrors.add(WeaveDiagEntry(
          kind       = WDCallUnknown,
          aspectName = ctx.aspectName,
          funcName   = ctx.funcName,
          fieldName  = name,
          span       = expr.span))
      }
    }
    case None -> ()
  }
  // args.<field> → <field>  (only under @inline_template).  When the
  // field name doesn't match a parameter we record an A0042 entry and
  // leave the expression intact so the downstream type-checker can
  // surface a position too (#681).
  if ctx.isInlineTemplate {
    match matchBareMemberAccess(expr, "args") {
      case Some(name) -> {
        if paramListContains(ctx.paramNames, name) {
          return Some(value = Expr(
            kind = EPath(path = ModulePath(
              segments = singleSeg(name),
              span     = expr.span)),
            span = expr.span))
        } else {
          ctx.argsErrors.add(WeaveDiagEntry(
            kind       = WDArgsMismatch,
            aspectName = ctx.aspectName,
            funcName   = ctx.funcName,
            fieldName  = name,
            span       = expr.span))
        }
      }
      case None -> ()
    }
  }
  None
}

func singleSeg(name: in String): List[String] {
  val segs: List[String] = newList()
  segs.add(name)
  segs
}

func paramListContains(paramNames: in List[String], name: in String): Bool {
  var i = 0
  while i < paramNames.count {
    if paramNames[i] == name { return true }
    i = i + 1
  }
  false
}

func rewriteExpr(ctx: in RewriteCtx, expr: in Expr): Expr {
  if isProceedCall(expr) {
    return proceedSubstitution(ctx.targetName, ctx.paramNames)
  }
  match tryMemberRewrite(ctx, expr) {
    case Some(replaced) -> return replaced
    case None           -> ()
  }
  val s = expr.span
  match expr.kind {
    case ECall(f, args) -> {
      val newArgs: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        newArgs.add(rewriteCallArg(ctx, args[i]))
        i = i + 1
      }
      Expr(kind = ECall(fn = rewriteExpr(ctx, f), args = newArgs), span = s)
    }
    case EParen(inner) ->
      Expr(kind = EParen(inner = rewriteExpr(ctx, inner)), span = s)
    case ETuple(xs) -> {
      val newXs: List[Expr] = newList()
      var i = 0
      while i < xs.count { newXs.add(rewriteExpr(ctx, xs[i])); i = i + 1 }
      Expr(kind = ETuple(exprs = newXs), span = s)
    }
    case EList(xs) -> {
      val newXs: List[Expr] = newList()
      var i = 0
      while i < xs.count { newXs.add(rewriteExpr(ctx, xs[i])); i = i + 1 }
      Expr(kind = EList(exprs = newXs), span = s)
    }
    case EAwait(inner) ->
      Expr(kind = EAwait(inner = rewriteExpr(ctx, inner)), span = s)
    case EYield(inner) ->
      Expr(kind = EYield(inner = rewriteExpr(ctx, inner)), span = s)
    case ESpawn(inner) ->
      Expr(kind = ESpawn(inner = rewriteExpr(ctx, inner)), span = s)
    case ETry(inner) ->
      Expr(kind = ETry(inner = rewriteExpr(ctx, inner)), span = s)
    case EOld(inner) ->
      Expr(kind = EOld(inner = rewriteExpr(ctx, inner)), span = s)
    case EPropagate(inner) ->
      Expr(kind = EPropagate(inner = rewriteExpr(ctx, inner)), span = s)
    case EPrefix(op, operand) ->
      Expr(kind = EPrefix(op = op, operand = rewriteExpr(ctx, operand)), span = s)
    case EBinop(op, l, r) ->
      Expr(kind = EBinop(
        op  = op,
        lhs = rewriteExpr(ctx, l),
        rhs = rewriteExpr(ctx, r)), span = s)
    case EAssign(t, op, v) ->
      Expr(kind = EAssign(
        target = rewriteExpr(ctx, t),
        op     = op,
        value  = rewriteExpr(ctx, v)), span = s)
    case EMember(recv, n) ->
      Expr(kind = EMember(receiver = rewriteExpr(ctx, recv), memberName = n), span = s)
    case EIndex(recv, idxs) -> {
      val newIdxs: List[Expr] = newList()
      var i = 0
      while i < idxs.count {
        newIdxs.add(rewriteExpr(ctx, idxs[i]))
        i = i + 1
      }
      Expr(kind = EIndex(
        receiver = rewriteExpr(ctx, recv),
        indices  = newIdxs), span = s)
    }
    case ETypeApp(f, targs) ->
      Expr(kind = ETypeApp(fn = rewriteExpr(ctx, f), args = targs), span = s)
    case EIf(cond, thenB, elseB, form) -> {
      val newElse = match elseB {
        case None    -> None
        case Some(e) -> Some(value = rewriteEOB(ctx, e))
      }
      Expr(kind = EIf(
        cond       = rewriteExpr(ctx, cond),
        thenBranch = rewriteEOB(ctx, thenB),
        elseBranch = newElse,
        thenForm   = form), span = s)
    }
    case EMatch(scrut, arms) ->
      Expr(kind = EMatch(
        scrutinee = rewriteExpr(ctx, scrut),
        arms      = rewriteMatchArms(ctx, arms)), span = s)
    case ELambda(lparams, body) ->
      Expr(kind = ELambda(lambdaParams = lparams, body = rewriteBlock(ctx, body)), span = s)
    case EBlock(blk) ->
      Expr(kind = EBlock(block = rewriteBlock(ctx, blk)), span = s)
    case EUnsafe(blk) ->
      Expr(kind = EUnsafe(block = rewriteBlock(ctx, blk)), span = s)
    case EInterpolated(segs) -> {
      val newSegs: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(t, sp) -> newSegs.add(ISText(text = t, span = sp))
          case ISExpr(e)     -> newSegs.add(ISExpr(expr = rewriteExpr(ctx, e)))
        }
        i = i + 1
      }
      Expr(kind = EInterpolated(segments = newSegs), span = s)
    }
    // Leaves: ELiteral, EPath, ESelf, EResult, EForall, EExists, ERange, EError
    case _ -> expr
  }
}

func rewriteCallArg(ctx: in RewriteCtx, arg: in CallArg): CallArg {
  match arg {
    case CAPositional(v)     -> CAPositional(expr = rewriteExpr(ctx, v))
    case CANamed(n, v, span) -> CANamed(name = n, value = rewriteExpr(ctx, v), span = span)
  }
}

func rewriteEOB(ctx: in RewriteCtx, eob: in ExprOrBlock): ExprOrBlock {
  match eob {
    case EOBBlock(blk)  -> EOBBlock(block = rewriteBlock(ctx, blk))
    case EOBExpr(expr)  -> EOBExpr(expr = rewriteExpr(ctx, expr))
  }
}

func rewriteMatchArms(ctx: in RewriteCtx, arms: in List[MatchArm]): List[MatchArm] {
  val newArms: List[MatchArm] = newList()
  var i = 0
  while i < arms.count {
    val a = arms[i]
    val newGuard = match a.guard {
      case Some(g) -> Some(value = rewriteExpr(ctx, g))
      case None    -> None
    }
    newArms.add(MatchArm(
      pattern = a.pattern,
      guard   = newGuard,
      body    = rewriteEOB(ctx, a.body),
      span    = a.span))
    i = i + 1
  }
  newArms
}

func rewriteBlock(ctx: in RewriteCtx, blk: in Block): Block {
  val newStmts: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    newStmts.add(rewriteStmt(ctx, blk.statements[i]))
    i = i + 1
  }
  Block(statements = newStmts, span = blk.span)
}

func rewriteStmt(ctx: in RewriteCtx, stmt: in Statement): Statement {
  val s = stmt.span
  match stmt.kind {
    case SExpr(e) ->
      Statement(kind = SExpr(expr = rewriteExpr(ctx, e)), span = s)
    case SReturn(opt) -> {
      val newOpt = match opt {
        case None    -> None
        case Some(e) -> Some(value = rewriteExpr(ctx, e))
      }
      Statement(kind = SReturn(value = newOpt), span = s)
    }
    case SLocal(binding) ->
      Statement(kind = SLocal(binding = rewriteBinding(ctx, binding)), span = s)
    case SAssign(t, op, v) ->
      Statement(kind = SAssign(
        target = rewriteExpr(ctx, t),
        op     = op,
        value  = rewriteExpr(ctx, v)), span = s)
    case SThrow(e) ->
      Statement(kind = SThrow(expr = rewriteExpr(ctx, e)), span = s)
    case SFor(lbl, pat, iter, body) ->
      Statement(kind = SFor(
        label = lbl,
        pat   = pat,
        iter  = rewriteExpr(ctx, iter),
        body  = rewriteBlock(ctx, body)), span = s)
    case SWhile(lbl, cond, body) ->
      Statement(kind = SWhile(
        label = lbl,
        cond  = rewriteExpr(ctx, cond),
        body  = rewriteBlock(ctx, body)), span = s)
    case SLoop(lbl, body) ->
      Statement(kind = SLoop(label = lbl, body = rewriteBlock(ctx, body)), span = s)
    case SScope(b, body) ->
      Statement(kind = SScope(binding = b, body = rewriteBlock(ctx, body)), span = s)
    case STry(body, catches, finally_) -> {
      val newBody = rewriteBlock(ctx, body)
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val cc = catches[i]
        newCatches.add(CatchClause(
          typeName = cc.typeName,
          bindName = cc.bindName,
          body     = rewriteBlock(ctx, cc.body),
          span     = cc.span))
        i = i + 1
      }
      val newFinally = match finally_ {
        case None     -> None
        case Some(fb) -> Some(rewriteBlock(ctx, fb))
      }
      Statement(kind = STry(body = newBody, catches = newCatches, finally_ = newFinally), span = s)
    }
    case SDefer(body) ->
      Statement(kind = SDefer(body = rewriteBlock(ctx, body)), span = s)
    // SBreak, SContinue, SInvariant, SRule, SItem: pass through
    case _ -> stmt
  }
}

func rewriteBinding(ctx: in RewriteCtx, b: in LocalBinding): LocalBinding {
  match b {
    case LBVal(pat, ty, init) ->
      LBVal(pat = pat, ty = ty, init = rewriteExpr(ctx, init))
    case LBVar(name, ty, optInit) -> {
      val newInit = match optInit {
        case None    -> None
        case Some(e) -> Some(value = rewriteExpr(ctx, e))
      }
      LBVar(name = name, ty = ty, init = newInit)
    }
    case LBLet(name, ty, init) ->
      LBLet(name = name, ty = ty, init = rewriteExpr(ctx, init))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Build a wrapper FunctionDecl for `originalFn` carrying `aspect`'s
//     around body, with proceed(args) → callTargetName(p1, p2, ...).
//     The wrapper keeps the original's params/return/contracts (composed
//     with the aspect's contracts).  Caller assigns the wrapper's name.
//
//     The wrapper body is built as `<prelude>` ++ `<rewritten body>`,
//     where the prelude materialises any `config { }` defaults the body
//     refers to (#683) and the compile-time call-context fields the
//     body refers to (#682).  Nothing is injected when no references
//     are present, so aspects that ignore `config` and `call` produce
//     byte-identical wrappers to the pre-todo-06 weaver.
// ─────────────────────────────────────────────────────────────────────────────

/// Bundle of weave-site information consumed by buildWrapper.
record WeaveSite {
  /// Package containing the matched function (used for
  /// `call.qualifiedName` / `call.modulePath`).
  packagePath:      String
  /// True iff the matched aspect carries `@inline_template` (#681).
  isInlineTemplate: Bool
  /// Accumulator for `args.<n>` validation errors (#681).  Same
  /// reference is passed to every `buildWrapper` invocation in a
  /// `weaveItems` run; entries surface as A0042 diagnostics.
  argsErrors:       List[WeaveDiagEntry]
}

func makeWeaveSite(
  packagePath:      in String,
  isInlineTemplate: in Bool,
  argsErrors:       in List[WeaveDiagEntry]
): WeaveSite {
  WeaveSite(
    packagePath      = packagePath,
    isInlineTemplate = isInlineTemplate,
    argsErrors       = argsErrors)
}

/// Build a synthetic `val <name>: <ty> = <init>` statement at a zero
/// span.  Used by both the config-field prelude (#683) and the
/// call-context prelude (#682).
func mkValStmt(name: in String, ty: in Option[TypeExpr], init: in Expr): Statement {
  val pat = Pattern(kind = PBinding(name = name, inner = None), span = synSpan())
  Statement(
    kind = SLocal(binding = LBVal(pat = pat, ty = ty, init = init)),
    span = synSpan())
}

/// `ELiteral(LString(text))` at a zero span.
func mkStringLit(text: in String): Expr {
  Expr(kind = ELiteral(lit = LString(text = text)), span = synSpan())
}

/// `EList(["a", "b", ...])` at a zero span.
func mkStringSliceLit(items: in List[String]): Expr {
  val exprs: List[Expr] = newList()
  var i = 0
  while i < items.count {
    exprs.add(mkStringLit(items[i]))
    i = i + 1
  }
  Expr(kind = EList(exprs = exprs), span = synSpan())
}

/// Build the `config { }` prelude for an aspect.  Emits one
/// `val __aspect_cfg_<field>: <ty> = <default>` per field that has a
/// literal default.  Fields without a default are skipped — runtime
/// env-var resolution is a follow-up (see todo/06 #683).  Returns the
/// names of fields that produced a prelude entry, so the rewriter only
/// substitutes those.
func buildConfigPrelude(aspect: in AspectDecl): (List[Statement], Map[String, Bool]) {
  val stmts: List[Statement] = newList()
  val present: Map[String, Bool] = newMap()
  var i = 0
  while i < aspect.config.count {
    val f = aspect.config[i]
    match f.default {
      case Some(init) -> {
        stmts.add(mkValStmt("__aspect_cfg_" + f.name, Some(value = f.ty), init))
        present.add(f.name, true)
      }
      case None -> ()
    }
    i = i + 1
  }
  return (stmts, present)
}

/// Walk an Expr (and any nested Block / EOB) collecting the set of
/// `call.<field>` member-access names that appear anywhere inside.
/// Used by `buildCallPrelude` to skip materialising `__lyric_call_*`
/// locals the body never reads (review #1196).
func collectCallRefsBlock(blk: in Block, into: in Map[String, Bool]): Unit {
  var i = 0
  while i < blk.statements.count {
    collectCallRefsStmt(blk.statements[i], into)
    i = i + 1
  }
}

func collectCallRefsStmt(s: in Statement, into: in Map[String, Bool]): Unit {
  match s.kind {
    case SExpr(e)     -> collectCallRefsExpr(e, into)
    case SReturn(o)   -> match o {
                          case Some(e) -> collectCallRefsExpr(e, into)
                          case None    -> ()
                        }
    case SLocal(b)    -> {
      match b {
        case LBVal(_, _, init) -> collectCallRefsExpr(init, into)
        case LBLet(_, _, init) -> collectCallRefsExpr(init, into)
        case LBVar(_, _, init) -> match init {
                                    case Some(e) -> collectCallRefsExpr(e, into)
                                    case None    -> ()
                                  }
      }
    }
    case SAssign(t, _, v) -> {
      collectCallRefsExpr(t, into)
      collectCallRefsExpr(v, into)
    }
    case SThrow(e) -> collectCallRefsExpr(e, into)
    case SFor(_, _, iter, body) -> {
      collectCallRefsExpr(iter, into)
      collectCallRefsBlock(body, into)
    }
    case SWhile(_, cond, body) -> {
      collectCallRefsExpr(cond, into)
      collectCallRefsBlock(body, into)
    }
    case SLoop(_, body)   -> collectCallRefsBlock(body, into)
    case SScope(_, body)  -> collectCallRefsBlock(body, into)
    case STry(body, catches, finally_) -> {
      collectCallRefsBlock(body, into)
      var i = 0
      while i < catches.count {
        collectCallRefsBlock(catches[i].body, into)
        i = i + 1
      }
      match finally_ {
        case Some(fb) -> collectCallRefsBlock(fb, into)
        case None     -> ()
      }
    }
    case SDefer(body) -> collectCallRefsBlock(body, into)
    case _ -> ()
  }
}

func collectCallRefsExpr(e: in Expr, into: in Map[String, Bool]): Unit {
  // Top-level: `call.<field>` member access.
  match matchBareMemberAccess(e, "call") {
    case Some(name) -> into.add(name, true)
    case None       -> ()
  }
  // Recurse into sub-expressions.
  match e.kind {
    case ECall(f, args) -> {
      collectCallRefsExpr(f, into)
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(v)   -> collectCallRefsExpr(v, into)
          case CANamed(_, v, _)  -> collectCallRefsExpr(v, into)
        }
        i = i + 1
      }
    }
    case EParen(inner)        -> collectCallRefsExpr(inner, into)
    case ETuple(xs)           -> {
      var i = 0
      while i < xs.count { collectCallRefsExpr(xs[i], into); i = i + 1 }
    }
    case EList(xs)            -> {
      var i = 0
      while i < xs.count { collectCallRefsExpr(xs[i], into); i = i + 1 }
    }
    case EAwait(inner)        -> collectCallRefsExpr(inner, into)
    case EYield(inner)        -> collectCallRefsExpr(inner, into)
    case ESpawn(inner)        -> collectCallRefsExpr(inner, into)
    case ETry(inner)          -> collectCallRefsExpr(inner, into)
    case EOld(inner)          -> collectCallRefsExpr(inner, into)
    case EPropagate(inner)    -> collectCallRefsExpr(inner, into)
    case EPrefix(_, op)       -> collectCallRefsExpr(op, into)
    case EBinop(_, l, r)      -> { collectCallRefsExpr(l, into); collectCallRefsExpr(r, into) }
    case EAssign(t, _, v)     -> { collectCallRefsExpr(t, into); collectCallRefsExpr(v, into) }
    case EMember(recv, _)     -> collectCallRefsExpr(recv, into)
    case EIndex(recv, idxs)   -> {
      collectCallRefsExpr(recv, into)
      var i = 0
      while i < idxs.count { collectCallRefsExpr(idxs[i], into); i = i + 1 }
    }
    case ETypeApp(f, _)       -> collectCallRefsExpr(f, into)
    case EIf(c, t, el, _)     -> {
      collectCallRefsExpr(c, into)
      collectCallRefsEOB(t, into)
      match el {
        case Some(e2) -> collectCallRefsEOB(e2, into)
        case None     -> ()
      }
    }
    case EMatch(scrut, arms)  -> {
      collectCallRefsExpr(scrut, into)
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(g) -> collectCallRefsExpr(g, into)
          case None    -> ()
        }
        collectCallRefsEOB(arms[i].body, into)
        i = i + 1
      }
    }
    case ELambda(_, body)     -> collectCallRefsBlock(body, into)
    case EBlock(blk)          -> collectCallRefsBlock(blk, into)
    case EUnsafe(blk)         -> collectCallRefsBlock(blk, into)
    case EInterpolated(segs)  -> {
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(_, _)  -> ()
          case ISExpr(inner) -> collectCallRefsExpr(inner, into)
        }
        i = i + 1
      }
    }
    case _ -> ()
  }
}

func collectCallRefsEOB(eob: in ExprOrBlock, into: in Map[String, Bool]): Unit {
  match eob {
    case EOBExpr(e)   -> collectCallRefsExpr(e, into)
    case EOBBlock(b)  -> collectCallRefsBlock(b, into)
  }
}

/// Build the `call` ambient prelude for an aspect.  Only emits a
/// `val __lyric_call_<field>` local for fields the aspect body
/// actually references; aspects that don't touch `call.*` produce
/// byte-identical wrappers to the pre-todo-06 weaver (review #1196).
/// Compile-time-known fields: `shortName`, `qualifiedName`,
/// `modulePath`, `sourceLocation`, `annotations`, `aspect`.  `elapsed`
/// and `caller` are not yet wired — references surface as A0043
/// diagnostics handled by the rewriter.
func buildCallPrelude(
  originalFn: in FunctionDecl,
  aspect:     in AspectDecl,
  site:       in WeaveSite,
  body:       in Block
): (List[Statement], Map[String, Bool]) {
  val stmts: List[Statement] = newList()
  val present: Map[String, Bool] = newMap()

  // Pre-scan: which call.<field> names does the body reference?
  val refs: Map[String, Bool] = newMap()
  collectCallRefsBlock(body, refs)
  if refs.count == 0 {
    return (stmts, present)
  }

  // shortName : String
  if refs.containsKey("shortName") {
    stmts.add(mkValStmt("__lyric_call_shortName", None, mkStringLit(originalFn.name)))
    present.add("shortName", true)
  }

  // qualifiedName : String
  if refs.containsKey("qualifiedName") {
    val qualified =
      if site.packagePath.length > 0 { site.packagePath + "." + originalFn.name }
      else                           { originalFn.name }
    stmts.add(mkValStmt("__lyric_call_qualifiedName", None, mkStringLit(qualified)))
    present.add("qualifiedName", true)
  }

  // modulePath : String
  if refs.containsKey("modulePath") {
    stmts.add(mkValStmt("__lyric_call_modulePath", None, mkStringLit(site.packagePath)))
    present.add("modulePath", true)
  }

  // sourceLocation : String  (formatted as "<package>:<line>")
  if refs.containsKey("sourceLocation") {
    val locText =
      if site.packagePath.length > 0 {
        site.packagePath + ":" + toString(originalFn.span.startPos.line)
      } else {
        "<unknown>:" + toString(originalFn.span.startPos.line)
      }
    stmts.add(mkValStmt("__lyric_call_sourceLocation", None, mkStringLit(locText)))
    present.add("sourceLocation", true)
  }

  // annotations : slice[String]
  if refs.containsKey("annotations") {
    val annNames: List[String] = newList()
    var ai = 0
    while ai < originalFn.annotations.count {
      annNames.add(annotationShortName(originalFn.annotations[ai]))
      ai = ai + 1
    }
    stmts.add(mkValStmt("__lyric_call_annotations", None, mkStringSliceLit(annNames)))
    present.add("annotations", true)
  }

  // aspect : String  (the current aspect's name)
  if refs.containsKey("aspect") {
    stmts.add(mkValStmt("__lyric_call_aspect", None, mkStringLit(aspect.name)))
    present.add("aspect", true)
  }

  return (stmts, present)
}

func buildWrapper(
  originalFn: in FunctionDecl,
  aspect:     in AspectDecl,
  callTargetName: in String,
  site:       in WeaveSite
): FunctionDecl {
  // `around` presence is verified by the caller.
  val around = match aspect.around {
    case Some(a) -> a
    case None    -> AspectAround(
      argsName = "args",
      retName  = None,
      body     = Block(statements = newList(), span = synSpan()),
      span     = synSpan())
  }
  val paramNames: List[String] = newList()
  var pi = 0
  while pi < originalFn.params.count {
    paramNames.add(originalFn.params[pi].name)
    pi = pi + 1
  }

  // Build preludes.  Each helper returns a (statements, present-field set)
  // pair; the present sets feed the rewriter so only materialised fields
  // are rewritten — out-of-scope references like `config.<unknown>` stay
  // as member accesses and surface as type errors at the use site.  The
  // call prelude is lazy: it pre-scans `around.body` for `call.<x>` refs
  // and emits only the locals the body actually reads.
  val (cfgStmts, cfgPresent) = buildConfigPrelude(aspect)
  val (callStmts, callPresent) = buildCallPrelude(originalFn, aspect, site, around.body)

  val ctx = newRewriteCtx(
    callTargetName,
    paramNames,
    cfgPresent,
    callPresent,
    site.isInlineTemplate,
    aspect.name,
    originalFn.name,
    site.argsErrors)

  val rewiredBody = rewriteBlock(ctx, around.body)

  // Compose: <config prelude> ++ <call prelude> ++ <rewritten body>.
  val finalStmts: List[Statement] = newList()
  var i = 0
  while i < cfgStmts.count  { finalStmts.add(cfgStmts[i]);  i = i + 1 }
  i = 0
  while i < callStmts.count { finalStmts.add(callStmts[i]); i = i + 1 }
  i = 0
  while i < rewiredBody.statements.count {
    finalStmts.add(rewiredBody.statements[i])
    i = i + 1
  }
  val finalBody = Block(statements = finalStmts, span = rewiredBody.span)

  // Composed contract: aspect.contracts ++ original.contracts (§5).
  val composed: List[ContractClause] = newList()
  var ci = 0
  while ci < aspect.contracts.count { composed.add(aspect.contracts[ci]); ci = ci + 1 }
  ci = 0
  while ci < originalFn.contracts.count { composed.add(originalFn.contracts[ci]); ci = ci + 1 }

  // Strip @no_aspect / aspect-routing annotations from the wrapper.
  val noAnnotations: List[Annotation] = newList()

  FunctionDecl(
    docComments = originalFn.docComments,
    annotations = noAnnotations,
    visibility  = originalFn.visibility,
    isAsync     = originalFn.isAsync,
    name        = originalFn.name,
    generics    = originalFn.generics,
    params      = originalFn.params,
    ret         = originalFn.ret,
    whereClause = originalFn.whereClause,
    contracts   = composed,
    body        = Some(value = FBBlock(block = finalBody)),
    span        = originalFn.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Topological sort of aspects by wraps:/inside: clauses.
//     "A wraps B" → A is outer, B is inner (A before B).
//     "A inside B" → B is outer, A is inner (B before A = A after B).
//     Lexical order is the tiebreak; cycles fall back to lexical order.
//     Returns aspects sorted outermost → innermost.
// ─────────────────────────────────────────────────────────────────────────────

// Increment `inDegree[inner]` for every inner name in `edges[from]`.
// Extracted as a helper because the bootstrap emitter mis-resolves
// nested `match Some(inners) -> while inners.count { ... }` when the
// enclosing function returns a `List` of an imported type.
func bumpInDegrees(
  edges:    in Map[String, List[String]],
  inDegree: in Map[String, Int],
  from:     in String,
  delta:    in Int,
  queue:    in List[String]
): Unit {
  match mapGet(edges, from) {
    case Some(inners) -> {
      var ii = 0
      while ii < inners.count {
        val inner = inners[ii]
        if inDegree.containsKey(inner) {
          val d = match mapGet(inDegree, inner) {
            case Some(v) -> v
            case None    -> 0
          }
          val nd = d + delta
          inDegree.add(inner, nd)
          if delta < 0 and nd == 0 { queue.add(inner) }
        }
        ii = ii + 1
      }
    }
    case None -> ()
  }
}

func sortAspects(aspects: in List[AspectDecl]): List[AspectDecl] {
  if aspects.count <= 1 {
    val result: List[AspectDecl] = newList()
    var i = 0
    while i < aspects.count { result.add(aspects[i]); i = i + 1 }
    return result
  }

  // Adjacency: outer -> set of inner names (as list, dedup via map).
  val edges: Map[String, List[String]] = newMap()
  val edgeSeen: Map[String, Map[String, Bool]] = newMap()
  var i = 0
  while i < aspects.count {
    val a = aspects[i]
    if not edges.containsKey(a.name) {
      val empty: List[String] = newList()
      edges.add(a.name, empty)
      val emptySeen: Map[String, Bool] = newMap()
      edgeSeen.add(a.name, emptySeen)
    }
    i = i + 1
  }
  i = 0
  while i < aspects.count {
    val a = aspects[i]
    var wi = 0
    while wi < a.wraps.count {
      val inner = a.wraps[wi]
      addEdge(edges, edgeSeen, a.name, inner)
      wi = wi + 1
    }
    var ii2 = 0
    while ii2 < a.inside.count {
      val outer = a.inside[ii2]
      if edges.containsKey(outer) {
        addEdge(edges, edgeSeen, outer, a.name)
      }
      ii2 = ii2 + 1
    }
    i = i + 1
  }

  // In-degrees.
  val inDegree: Map[String, Int] = newMap()
  i = 0
  while i < aspects.count {
    inDegree.add(aspects[i].name, 0)
    i = i + 1
  }
  val unusedQueue: List[String] = newList()
  i = 0
  while i < aspects.count {
    bumpInDegrees(edges, inDegree, aspects[i].name, 1, unusedQueue)
    i = i + 1
  }

  // Kahn's algorithm: queue starts with zero in-degree (lexical order).
  val queue: List[String] = newList()
  i = 0
  while i < aspects.count {
    val n = aspects[i].name
    val d = lookupIntOr0(inDegree, n)
    if d == 0 { queue.add(n) }
    i = i + 1
  }
  val sortedNames: List[String] = newList()
  val sortedSeen: Map[String, Bool] = newMap()
  var head = 0
  while head < queue.count {
    val n = queue[head]
    head = head + 1
    sortedNames.add(n)
    sortedSeen.add(n, true)
    bumpInDegrees(edges, inDegree, n, -1, queue)
  }
  // Any remaining (cycle) — append in lexical order.
  i = 0
  while i < aspects.count {
    val n = aspects[i].name
    if not sortedSeen.containsKey(n) {
      sortedNames.add(n)
      sortedSeen.add(n, true)
    }
    i = i + 1
  }

  // Look up AspectDecl by name in lexical-order map.
  buildSortedResult(aspects, sortedNames)
}

func lookupIntOr0(m: in Map[String, Int], k: in String): Int {
  match mapGet(m, k) {
    case Some(v) -> v
    case None    -> 0
  }
}

func buildSortedResult(aspects: in List[AspectDecl], sortedNames: in List[String]): List[AspectDecl] {
  val byName: Map[String, AspectDecl] = newMap()
  var i = 0
  while i < aspects.count {
    byName.add(aspects[i].name, aspects[i])
    i = i + 1
  }
  val result: List[AspectDecl] = newList()
  i = 0
  while i < sortedNames.count {
    val nm = sortedNames[i]
    if byName.containsKey(nm) {
      match mapGet(byName, nm) {
        case Some(a) -> result.add(a)
        case None    -> ()
      }
    }
    i = i + 1
  }
  result
}

func addEdge(
  edges:    in Map[String, List[String]],
  edgeSeen: in Map[String, Map[String, Bool]],
  from:     in String,
  to:       in String
): Unit {
  match mapGet(edgeSeen, from) {
    case Some(seen) -> {
      if not seen.containsKey(to) {
        seen.add(to, true)
        match mapGet(edges, from) {
          case Some(inners) -> inners.add(to)
          case None         -> ()
        }
      }
    }
    case None -> ()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. TypeExpr → string for `signature: returns` matching.  Mirrors
//     Weaver.fs typeExprToString.
// ─────────────────────────────────────────────────────────────────────────────

func typeExprToString(te: in TypeExpr): String {
  match te.kind {
    case TRef(mp) -> segmentsJoin(mp.segments)
    case TUnit    -> "Unit"
    case TNever   -> "Never"
    case TSelf    -> "Self"
    case TError   -> "<error>"
    case TGenericApp(head, args) -> {
      val h = segmentsJoin(head.segments)
      val parts: List[String] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case TAType(inner) -> parts.add(typeExprToString(inner))
          case _             -> parts.add("_")
        }
        i = i + 1
      }
      h + "[" + commaJoin(parts) + "]"
    }
    case TSlice(inner)      -> "slice[" + typeExprToString(inner) + "]"
    case TArray(_, inner)   -> "array[" + typeExprToString(inner) + "]"
    case TNullable(inner)   -> typeExprToString(inner) + "?"
    case TTuple(items) -> {
      val parts: List[String] = newList()
      var i = 0
      while i < items.count { parts.add(typeExprToString(items[i])); i = i + 1 }
      "(" + commaJoin(parts) + ")"
    }
    case TFunction(ps, ret) -> {
      val parts: List[String] = newList()
      var i = 0
      while i < ps.count { parts.add(typeExprToString(ps[i])); i = i + 1 }
      "(" + commaJoin(parts) + ") -> " + typeExprToString(ret)
    }
    case TRefined(mp, _)    -> segmentsJoin(mp.segments)
    case TParen(inner)      -> typeExprToString(inner)
  }
}

func segmentsJoin(segs: in List[String]): String {
  var acc = ""
  var i = 0
  while i < segs.count {
    if i > 0 { acc = acc + "." }
    acc = acc + segs[i]
    i = i + 1
  }
  acc
}

func commaJoin(parts: in List[String]): String {
  var acc = ""
  var i = 0
  while i < parts.count {
    if i > 0 { acc = acc + ", " }
    acc = acc + parts[i]
    i = i + 1
  }
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Predicate matching (AND semantics; empty matchers ⇒ no match).
// ─────────────────────────────────────────────────────────────────────────────

func annotationShortName(ann: in Annotation): String {
  val segs = ann.name.segments
  if segs.count == 0 { return "" }
  segs[segs.count - 1]
}

func annotationHasName(fn: in FunctionDecl, name: in String): Bool {
  var i = 0
  while i < fn.annotations.count {
    if annotationShortName(fn.annotations[i]) == name { return true }
    i = i + 1
  }
  false
}

func matchesPredicate(m: in AspectMatcher, fn: in FunctionDecl): Bool {
  match m {
    case AMNameLike(glob, _) -> globMatch(glob, fn.name)
    case AMAnnotated(annName, _) -> annotationHasName(fn, annName)
    case AMVisibility(vis, _) -> {
      if vis == "pub" {
        match fn.visibility {
          case Some(v) -> match v { case VisPub(_) -> true; case _ -> false }
          case None    -> false
        }
      } else if vis == "internal" {
        match fn.visibility {
          case Some(v) -> match v { case VisInternal(_) -> true; case _ -> false }
          case None    -> false
        }
      } else if vis == "priv" {
        match fn.visibility {
          case Some(_) -> false
          case None    -> true
        }
      } else { false }
    }
    case AMSignatureReturns(typeGlob, _) -> {
      val retStr = match fn.ret {
        case None     -> "Unit"
        case Some(te) -> typeExprToString(te)
      }
      globMatch(typeGlob, retStr)
    }
  }
}

func matchesPredicates(matchers: in List[AspectMatcher], fn: in FunctionDecl): Bool {
  // Empty matchers ⇒ library-template aspect with no local match: clause.
  if matchers.count == 0 { return false }
  var i = 0
  while i < matchers.count {
    if not matchesPredicate(matchers[i], fn) { return false }
    i = i + 1
  }
  true
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. @no_aspect opt-out.  `@no_aspect` opts out of all; `@no_aspect("Name")`
//     opts out of just the named aspect.
// ─────────────────────────────────────────────────────────────────────────────

func annotationIsNoAspect(ann: in Annotation): Bool {
  ann.name.segments.count == 1 and ann.name.segments[0] == "no_aspect"
}

func annotationArgsTargetAspect(args: in List[AnnotationArg], aspectName: in String): Bool {
  if args.count == 0 { return true }    // bare @no_aspect → all
  var i = 0
  while i < args.count {
    match args[i] {
      case ALiteral(value, _) -> {
        match value {
          case AVString(s, _) -> if s == aspectName { return true }
          case _ -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

func isOptedOut(fn: in FunctionDecl, aspectName: in String): Bool {
  var i = 0
  while i < fn.annotations.count {
    val a = fn.annotations[i]
    if annotationIsNoAspect(a) {
      if annotationArgsTargetAspect(a.args, aspectName) { return true }
    }
    i = i + 1
  }
  false
}

func exceptListContains(except: in List[String], name: in String): Bool {
  var i = 0
  while i < except.count {
    if except[i] == name { return true }
    i = i + 1
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Public entry: weave items.  Mirrors Weaver.fs weaveItems plus the
//     todo/06 extensions (config wiring, call-context prelude,
//     @inline_template `args.<field>` rewriting + A0042 diagnostics).
// ─────────────────────────────────────────────────────────────────────────────

/// One aspect collected by `collectActiveAspects`, paired with whether
/// the enclosing item carried `@inline_template` (#681).  The annotation
/// lives on the `Item.annotations` list because `AspectDecl` itself has
/// no annotations field — the parser attaches them at item granularity.
record CollectedAspect {
  decl:             AspectDecl
  isInlineTemplate: Bool
}

func itemHasInlineTemplate(item: in Item): Bool {
  var i = 0
  while i < item.annotations.count {
    if annotationShortName(item.annotations[i]) == "inline_template" {
      return true
    }
    i = i + 1
  }
  false
}

func collectActiveAspects(items: in List[Item]): List[CollectedAspect] {
  val aspects: List[CollectedAspect] = newList()
  var i = 0
  while i < items.count {
    val it = items[i]
    match it.kind {
      case IAspect(decl) -> {
        match decl.around {
          case Some(_) ->
            aspects.add(CollectedAspect(
              decl             = decl,
              isInlineTemplate = itemHasInlineTemplate(it)))
          case None -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  aspects
}

/// Result of a weave pass: the rewritten item list plus any
/// weave-time diagnostics (currently only A0042 for `@inline_template`
/// `args.<field>` mismatches).
pub record WeaveResult {
  items:       List[Item]
  diagnostics: List[Diagnostic]
}

/// Compute the package path string from a SourceFile's package decl,
/// e.g. ["Std", "Time"] → "Std.Time".  Empty string when the package
/// is at the root (unusual for real code).
func packagePathString(file: in SourceFile): String {
  segmentsJoin(file.packageDecl.path.segments)
}

/// Convert weave-time diagnostic entries (A0042 args mismatches and
/// A0043 unknown `call.<field>` accesses) to user-facing Diagnostic
/// objects.
func weaveDiagsToDiagnostics(errs: in List[WeaveDiagEntry]): List[Diagnostic] {
  val diags: List[Diagnostic] = newList()
  var i = 0
  while i < errs.count {
    val e = errs[i]
    match e.kind {
      case WDArgsMismatch -> {
        val msg =
          "@inline_template aspect '" + e.aspectName +
          "' references args." + e.fieldName +
          " but matched function '" + e.funcName +
          "' has no parameter named '" + e.fieldName + "'"
        diags.add(errorDiagnostic("A0042", msg, e.span))
      }
      case WDCallUnknown -> {
        val msg =
          "aspect '" + e.aspectName +
          "' references call." + e.fieldName +
          " on matched function '" + e.funcName +
          "' but the weaver does not (yet) inject a value for that " +
          "field (recognised fields: shortName, qualifiedName, " +
          "modulePath, sourceLocation, annotations, aspect)"
        diags.add(errorDiagnostic("A0043", msg, e.span))
      }
    }
    i = i + 1
  }
  diags
}

/// Core weave loop.  Used by both `weaveItems` (drops diagnostics, for
/// back-compat) and `weaveItemsWithDiags` / `weaveFileWithDiags`.
func weaveItemsCore(
  items:       in List[Item],
  packagePath: in String
): WeaveResult {
  val argsErrors: List[WeaveDiagEntry] = newList()
  val collected = collectActiveAspects(items)
  if collected.count == 0 {
    val noAspectItems: List[Item] = newList()
    var i = 0
    while i < items.count {
      match items[i].kind {
        case IAspect(_) -> ()
        case _          -> noAspectItems.add(items[i])
      }
      i = i + 1
    }
    val noDiags: List[Diagnostic] = newList()
    return WeaveResult(items = noAspectItems, diagnostics = noDiags)
  }

  // Build a `name -> isInlineTemplate` lookup so the sorted aspect list
  // (which goes through name-only Kahn ordering) can recover the
  // per-aspect template flag at weave time.
  val templateByName: Map[String, Bool] = newMap()
  val declsForSort: List[AspectDecl]    = newList()
  var ci = 0
  while ci < collected.count {
    templateByName.add(collected[ci].decl.name, collected[ci].isInlineTemplate)
    declsForSort.add(collected[ci].decl)
    ci = ci + 1
  }

  val result: List[Item] = newList()
  var idx = 0
  while idx < items.count {
    val item = items[idx]
    match item.kind {
      case IAspect(_) -> ()
      case IFunc(fn)  -> {
        val matched: List[AspectDecl] = newList()
        var ai = 0
        while ai < declsForSort.count {
          val a = declsForSort[ai]
          if not isOptedOut(fn, a.name)
              and not exceptListContains(a.exceptNames, fn.name)
              and matchesPredicates(a.matches, fn) {
            matched.add(a)
          }
          ai = ai + 1
        }
        if matched.count == 0 {
          result.add(item)
        } else {
          val ordered = sortAspects(matched)
          val targetName = fn.name + "__aspect_target"
          // Rename original target; strip visibility so only the wrapper is public.
          val renamedFn = FunctionDecl(
            docComments = fn.docComments,
            annotations = fn.annotations,
            visibility  = None,
            isAsync     = fn.isAsync,
            name        = targetName,
            generics    = fn.generics,
            params      = fn.params,
            ret         = fn.ret,
            whereClause = fn.whereClause,
            contracts   = fn.contracts,
            body        = fn.body,
            span        = fn.span)
          result.add(Item(
            docComments = item.docComments,
            annotations = item.annotations,
            visibility  = item.visibility,
            kind        = IFunc(decl = renamedFn),
            span        = item.span))
          // Build wrappers from innermost to outermost; outermost keeps the
          // public name, intermediates get __aspect_<AspectName>.
          val n = ordered.count
          var callTarget = targetName
          var i = 0
          while i < n {
            val aspect = ordered[n - 1 - i]
            val isOutermost = (i == n - 1)
            val wrapperName = if isOutermost { fn.name } else { fn.name + "__aspect_" + aspect.name }
            val isTpl = match mapGet(templateByName, aspect.name) {
              case Some(b) -> b
              case None    -> false
            }
            val site = makeWeaveSite(packagePath, isTpl, argsErrors)
            val wrapper0 = buildWrapper(fn, aspect, callTarget, site)
            val wrapper = FunctionDecl(
              docComments = wrapper0.docComments,
              annotations = wrapper0.annotations,
              visibility  = wrapper0.visibility,
              isAsync     = wrapper0.isAsync,
              name        = wrapperName,
              generics    = wrapper0.generics,
              params      = wrapper0.params,
              ret         = wrapper0.ret,
              whereClause = wrapper0.whereClause,
              contracts   = wrapper0.contracts,
              body        = wrapper0.body,
              span        = wrapper0.span)
            result.add(Item(
              docComments = item.docComments,
              annotations = item.annotations,
              visibility  = item.visibility,
              kind        = IFunc(decl = wrapper),
              span        = item.span))
            callTarget = wrapperName
            i = i + 1
          }
        }
      }
      case _ -> result.add(item)
    }
    idx = idx + 1
  }
  WeaveResult(items = result, diagnostics = weaveDiagsToDiagnostics(argsErrors))
}

pub func weaveItems(items: in List[Item]): List[Item] {
  weaveItemsCore(items, "").items
}

pub func weaveItemsWithDiags(items: in List[Item], packagePath: in String): WeaveResult {
  weaveItemsCore(items, packagePath)
}

pub func weaveFile(file: in SourceFile): SourceFile {
  val newItems = weaveItemsCore(file.items, packagePathString(file)).items
  SourceFile(
    moduleDoc       = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl     = file.packageDecl,
    imports         = file.imports,
    items           = newItems,
    span            = file.span)
}

/// Result of `weaveFileWithDiags`: the rewritten file plus any
/// weave-time diagnostics.
pub record WeaveFileResult {
  file:        SourceFile
  diagnostics: List[Diagnostic]
}

/// Weave a SourceFile and return any diagnostics raised during the
/// weave (#681 A0042 — `@inline_template` args.<field> mismatches).
/// Callers that want plain back-compat behaviour can continue using
/// `weaveFile`, which drops the diagnostic list.
pub func weaveFileWithDiags(file: in SourceFile): WeaveFileResult {
  val wr = weaveItemsCore(file.items, packagePathString(file))
  val newFile = SourceFile(
    moduleDoc       = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl     = file.packageDecl,
    imports         = file.imports,
    items           = wr.items,
    span            = file.span)
  WeaveFileResult(file = newFile, diagnostics = wr.diagnostics)
}
