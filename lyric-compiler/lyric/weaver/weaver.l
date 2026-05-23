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
// Used by the verifier driver so `lyric prove` discharges contracts on
// the woven body (not the parsed body). Closes #336.
//
// Bootstrap-grade scope (mirrors F# parity):
//   - Only the bare `proceed(args)` call is rewritten; `args.field` is
//     not supported.
//   - The ambient `call` value is not injected.
//   - Glob syntax: `*`, `?`, `[abc]`, `[a-z]`; other chars literal.
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
// §3. Rewrite `proceed(args)` → `targetName(p1, p2, ...)` in an expression
//     tree.  Mirrors Weaver.fs rewriteProceeds.
// ─────────────────────────────────────────────────────────────────────────────

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

func rewriteExpr(targetName: in String, paramNames: in List[String], expr: in Expr): Expr {
  if isProceedCall(expr) {
    return proceedSubstitution(targetName, paramNames)
  }
  val s = expr.span
  match expr.kind {
    case ECall(f, args) -> {
      val newArgs: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        newArgs.add(rewriteCallArg(targetName, paramNames, args[i]))
        i = i + 1
      }
      Expr(kind = ECall(fn = rewriteExpr(targetName, paramNames, f), args = newArgs), span = s)
    }
    case EParen(inner) ->
      Expr(kind = EParen(inner = rewriteExpr(targetName, paramNames, inner)), span = s)
    case ETuple(xs) -> {
      val newXs: List[Expr] = newList()
      var i = 0
      while i < xs.count { newXs.add(rewriteExpr(targetName, paramNames, xs[i])); i = i + 1 }
      Expr(kind = ETuple(exprs = newXs), span = s)
    }
    case EList(xs) -> {
      val newXs: List[Expr] = newList()
      var i = 0
      while i < xs.count { newXs.add(rewriteExpr(targetName, paramNames, xs[i])); i = i + 1 }
      Expr(kind = EList(exprs = newXs), span = s)
    }
    case EAwait(inner) ->
      Expr(kind = EAwait(inner = rewriteExpr(targetName, paramNames, inner)), span = s)
    case EYield(inner) ->
      Expr(kind = EYield(inner = rewriteExpr(targetName, paramNames, inner)), span = s)
    case ESpawn(inner) ->
      Expr(kind = ESpawn(inner = rewriteExpr(targetName, paramNames, inner)), span = s)
    case ETry(inner) ->
      Expr(kind = ETry(inner = rewriteExpr(targetName, paramNames, inner)), span = s)
    case EOld(inner) ->
      Expr(kind = EOld(inner = rewriteExpr(targetName, paramNames, inner)), span = s)
    case EPropagate(inner) ->
      Expr(kind = EPropagate(inner = rewriteExpr(targetName, paramNames, inner)), span = s)
    case EPrefix(op, operand) ->
      Expr(kind = EPrefix(op = op, operand = rewriteExpr(targetName, paramNames, operand)), span = s)
    case EBinop(op, l, r) ->
      Expr(kind = EBinop(
        op  = op,
        lhs = rewriteExpr(targetName, paramNames, l),
        rhs = rewriteExpr(targetName, paramNames, r)), span = s)
    case EAssign(t, op, v) ->
      Expr(kind = EAssign(
        target = rewriteExpr(targetName, paramNames, t),
        op     = op,
        value  = rewriteExpr(targetName, paramNames, v)), span = s)
    case EMember(recv, n) ->
      Expr(kind = EMember(receiver = rewriteExpr(targetName, paramNames, recv), memberName = n), span = s)
    case EIndex(recv, idxs) -> {
      val newIdxs: List[Expr] = newList()
      var i = 0
      while i < idxs.count {
        newIdxs.add(rewriteExpr(targetName, paramNames, idxs[i]))
        i = i + 1
      }
      Expr(kind = EIndex(
        receiver = rewriteExpr(targetName, paramNames, recv),
        indices  = newIdxs), span = s)
    }
    case ETypeApp(f, targs) ->
      Expr(kind = ETypeApp(fn = rewriteExpr(targetName, paramNames, f), args = targs), span = s)
    case EIf(cond, thenB, elseB, form) -> {
      val newElse = match elseB {
        case None    -> None
        case Some(e) -> Some(value = rewriteEOB(targetName, paramNames, e))
      }
      Expr(kind = EIf(
        cond       = rewriteExpr(targetName, paramNames, cond),
        thenBranch = rewriteEOB(targetName, paramNames, thenB),
        elseBranch = newElse,
        thenForm   = form), span = s)
    }
    case EMatch(scrut, arms) ->
      Expr(kind = EMatch(
        scrutinee = rewriteExpr(targetName, paramNames, scrut),
        arms      = rewriteMatchArms(targetName, paramNames, arms)), span = s)
    case ELambda(lparams, body) ->
      Expr(kind = ELambda(lambdaParams = lparams, body = rewriteBlock(targetName, paramNames, body)), span = s)
    case EBlock(blk) ->
      Expr(kind = EBlock(block = rewriteBlock(targetName, paramNames, blk)), span = s)
    case EUnsafe(blk) ->
      Expr(kind = EUnsafe(block = rewriteBlock(targetName, paramNames, blk)), span = s)
    case EInterpolated(segs) -> {
      val newSegs: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(t, sp) -> newSegs.add(ISText(text = t, span = sp))
          case ISExpr(e)     -> newSegs.add(ISExpr(expr = rewriteExpr(targetName, paramNames, e)))
        }
        i = i + 1
      }
      Expr(kind = EInterpolated(segments = newSegs), span = s)
    }
    // Leaves: ELiteral, EPath, ESelf, EResult, EForall, EExists, ERange, EError
    case _ -> expr
  }
}

func rewriteCallArg(targetName: in String, paramNames: in List[String], arg: in CallArg): CallArg {
  match arg {
    case CAPositional(v)     -> CAPositional(expr = rewriteExpr(targetName, paramNames, v))
    case CANamed(n, v, span) -> CANamed(name = n, value = rewriteExpr(targetName, paramNames, v), span = span)
  }
}

func rewriteEOB(targetName: in String, paramNames: in List[String], eob: in ExprOrBlock): ExprOrBlock {
  match eob {
    case EOBBlock(blk)  -> EOBBlock(block = rewriteBlock(targetName, paramNames, blk))
    case EOBExpr(expr)  -> EOBExpr(expr = rewriteExpr(targetName, paramNames, expr))
  }
}

func rewriteMatchArms(targetName: in String, paramNames: in List[String], arms: in List[MatchArm]): List[MatchArm] {
  val newArms: List[MatchArm] = newList()
  var i = 0
  while i < arms.count {
    val a = arms[i]
    val newGuard = match a.guard {
      case Some(g) -> Some(value = rewriteExpr(targetName, paramNames, g))
      case None    -> None
    }
    newArms.add(MatchArm(
      pattern = a.pattern,
      guard   = newGuard,
      body    = rewriteEOB(targetName, paramNames, a.body),
      span    = a.span))
    i = i + 1
  }
  newArms
}

func rewriteBlock(targetName: in String, paramNames: in List[String], blk: in Block): Block {
  val newStmts: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    newStmts.add(rewriteStmt(targetName, paramNames, blk.statements[i]))
    i = i + 1
  }
  Block(statements = newStmts, span = blk.span)
}

func rewriteStmt(targetName: in String, paramNames: in List[String], stmt: in Statement): Statement {
  val s = stmt.span
  match stmt.kind {
    case SExpr(e) ->
      Statement(kind = SExpr(expr = rewriteExpr(targetName, paramNames, e)), span = s)
    case SReturn(opt) -> {
      val newOpt = match opt {
        case None    -> None
        case Some(e) -> Some(value = rewriteExpr(targetName, paramNames, e))
      }
      Statement(kind = SReturn(value = newOpt), span = s)
    }
    case SLocal(binding) ->
      Statement(kind = SLocal(binding = rewriteBinding(targetName, paramNames, binding)), span = s)
    case SAssign(t, op, v) ->
      Statement(kind = SAssign(
        target = rewriteExpr(targetName, paramNames, t),
        op     = op,
        value  = rewriteExpr(targetName, paramNames, v)), span = s)
    case SThrow(e) ->
      Statement(kind = SThrow(expr = rewriteExpr(targetName, paramNames, e)), span = s)
    case SFor(lbl, pat, iter, body) ->
      Statement(kind = SFor(
        label = lbl,
        pat   = pat,
        iter  = rewriteExpr(targetName, paramNames, iter),
        body  = rewriteBlock(targetName, paramNames, body)), span = s)
    case SWhile(lbl, cond, body) ->
      Statement(kind = SWhile(
        label = lbl,
        cond  = rewriteExpr(targetName, paramNames, cond),
        body  = rewriteBlock(targetName, paramNames, body)), span = s)
    case SLoop(lbl, body) ->
      Statement(kind = SLoop(label = lbl, body = rewriteBlock(targetName, paramNames, body)), span = s)
    case SScope(b, body) ->
      Statement(kind = SScope(binding = b, body = rewriteBlock(targetName, paramNames, body)), span = s)
    case STry(body, catches, finally_) -> {
      val newBody = rewriteBlock(targetName, paramNames, body)
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val cc = catches[i]
        newCatches.add(CatchClause(
          typeName = cc.typeName,
          bindName = cc.bindName,
          body     = rewriteBlock(targetName, paramNames, cc.body),
          span     = cc.span))
        i = i + 1
      }
      val newFinally = match finally_ {
        case None     -> None
        case Some(fb) -> Some(rewriteBlock(targetName, paramNames, fb))
      }
      Statement(kind = STry(body = newBody, catches = newCatches, finally_ = newFinally), span = s)
    }
    case SDefer(body) ->
      Statement(kind = SDefer(body = rewriteBlock(targetName, paramNames, body)), span = s)
    // SBreak, SContinue, SInvariant, SRule, SItem: pass through
    case _ -> stmt
  }
}

func rewriteBinding(targetName: in String, paramNames: in List[String], b: in LocalBinding): LocalBinding {
  match b {
    case LBVal(pat, ty, init) ->
      LBVal(pat = pat, ty = ty, init = rewriteExpr(targetName, paramNames, init))
    case LBVar(name, ty, optInit) -> {
      val newInit = match optInit {
        case None    -> None
        case Some(e) -> Some(value = rewriteExpr(targetName, paramNames, e))
      }
      LBVar(name = name, ty = ty, init = newInit)
    }
    case LBLet(name, ty, init) ->
      LBLet(name = name, ty = ty, init = rewriteExpr(targetName, paramNames, init))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Build a wrapper FunctionDecl for `originalFn` carrying `aspect`'s
//     around body, with proceed(args) → callTargetName(p1, p2, ...).
//     The wrapper keeps the original's params/return/contracts (composed
//     with the aspect's contracts).  Caller assigns the wrapper's name.
// ─────────────────────────────────────────────────────────────────────────────

func buildWrapper(originalFn: in FunctionDecl, aspect: in AspectDecl, callTargetName: in String): FunctionDecl {
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
  val rewiredBody = rewriteBlock(callTargetName, paramNames, around.body)

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
    body        = Some(value = FBBlock(block = rewiredBody)),
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
// §9. Public entry: weave items.  Mirrors Weaver.fs weaveItems.
// ─────────────────────────────────────────────────────────────────────────────

func collectActiveAspects(items: in List[Item]): List[AspectDecl] {
  val aspects: List[AspectDecl] = newList()
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IAspect(decl) -> {
        match decl.around {
          case Some(_) -> aspects.add(decl)
          case None    -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  aspects
}

pub func weaveItems(items: in List[Item]): List[Item] {
  val aspects = collectActiveAspects(items)
  if aspects.count == 0 {
    val noAspectItems: List[Item] = newList()
    var i = 0
    while i < items.count {
      match items[i].kind {
        case IAspect(_) -> ()
        case _          -> noAspectItems.add(items[i])
      }
      i = i + 1
    }
    return noAspectItems
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
        while ai < aspects.count {
          val a = aspects[ai]
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
            val wrapper0 = buildWrapper(fn, aspect, callTarget)
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
  result
}

pub func weaveFile(file: in SourceFile): SourceFile {
  val newItems = weaveItems(file.items)
  SourceFile(
    moduleDoc       = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl     = file.packageDecl,
    imports         = file.imports,
    items           = newItems,
    span            = file.span)
}
