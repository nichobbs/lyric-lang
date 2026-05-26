// lyric/alias_rewriter.l — AST-level rewriter for `import X as A`
// package aliases (#1378 follow-up).
//
// Bootstrap-grade alias semantics (matching D-progress-018):
//
//   import Auth.Kernel.Net as AuthKernelNet
//   val r = AuthKernelNet.verifyJwtImpl(token, secret)
//
// is treated as syntactic sugar for
//
//   import Auth.Kernel.Net
//   val r = verifyJwtImpl(token, secret)
//
// The rewriter runs after parsing and before type-check, walking
// every `Expr`, `TypeExpr`, `Pattern`, and `ConstraintRef` in the
// user's source file.  Selector-level aliases
// (`import X.{foo as bar}`) are NOT handled here — they're cloned
// into the imported-items list by the emitter so the original symbol
// is registered under both names.
//
// Mirrors `bootstrap/src/Lyric.Parser/AliasRewriter.fs` so the
// self-hosted pipeline gets the same alias-collapsing behaviour the
// F# emitter relies on.  Wired into the self-hosted MSIL bridge via
// `Msil.Bridge.compileToMsil*` between parse and typecheck (#1378's
// `AuthKernelNet` symptom).
//
// Out-of-scope (bootstrap):
//   - The rewriter is scope-blind.  A local variable named `Coll`
//     after `import X as Coll` would collide; users should pick
//     alias names that don't shadow locals.
//   - Aliases on non-builtin user packages aren't yet wired through
//     the emitter's package resolver for stdlib-call codegen, so
//     this only meaningfully fires for intra-project aliases and
//     stdlib imports today.

package Lyric.AliasRewriter

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Alias collection.
// ─────────────────────────────────────────────────────────────────────────────

// Helper: extract `asAlias` through an explicit function-typed
// indirection.  Works around the F# emitter's #1140 cross-package
// generic-arg widening bug — `imports[i].asAlias` peeks as
// `System.Object.asAlias` when the list element type widens, but a
// dedicated function with an `ImportDecl` parameter keeps the static
// type stable for codegen.  Self-hosted bridge isn't affected; this
// only matters when the F# stage-0 compiler builds this DLL.
//
// Note (#1451): the same #1140-class widening fires on bare `None`
// match arms — `case None -> None` produces an `Option[obj]` value
// whose stale generic arg poisons downstream type-inference for the
// containing `match` expression.  Every Option-shaped match in this
// file therefore returns the matched expression itself in the None
// arm (e.g. `case None -> ty`) so the arm reuses the input's fully
// resolved `Option[T]` static type instead of synthesising a fresh
// `None`.  Stage-1 (self-hosted) builds aren't affected, but the F#
// stage-0 compiler must produce a working `Lyric.AliasRewriter.dll`,
// and bare `None` in this file breaks `lyric build --manifest
// lyric-stdlib/lyric.toml`.
func asAliasOf(imp: in ImportDecl): Option[String] { imp.asAlias }

// Build a list of single-segment alias names from the source file's
// imports.  Only `import X as A`-style aliases participate; selector
// aliases (`{ foo as bar }`) are handled elsewhere.
//
// A list is used instead of a set because the typechecker isn't a
// hot path for huge alias counts — linear membership is plenty.
func collectAliases(imports: in List[ImportDecl]): List[String] {
  val names: List[String] = newList()
  var i = 0
  while i < imports.count {
    match asAliasOf(imports[i]) {
      case Some(name) -> names.add(name)
      case None       -> ()
    }
    i = i + 1
  }
  names
}

func aliasContains(aliases: in List[String], name: in String): Bool {
  var i = 0
  while i < aliases.count {
    if aliases[i] == name { return true }
    i = i + 1
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. ModulePath rewriting.
// ─────────────────────────────────────────────────────────────────────────────

// `Coll.List` (segments = ["Coll", "List"]) where `Coll` is a known
// alias collapses to `List` (segments = ["List"]).  Single-segment
// paths and paths whose head isn't an alias pass through unchanged.
func rewritePath(aliases: in List[String], p: in ModulePath): ModulePath {
  if p.segments.count < 2 { return p }
  if not aliasContains(aliases, p.segments[0]) { return p }
  val rest: List[String] = newList()
  var i = 1
  while i < p.segments.count {
    rest.add(p.segments[i])
    i = i + 1
  }
  ModulePath(segments = rest, span = p.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. TypeExpr / TypeArg / RangeBound / ConstraintRef.
// ─────────────────────────────────────────────────────────────────────────────

func rewriteTypeExpr(aliases: in List[String], te: in TypeExpr): TypeExpr {
  val kind = match te.kind {
    case TRef(path) -> TRef(path = rewritePath(aliases, path))
    case TGenericApp(head, args) -> {
      val args2: List[TypeArg] = newList()
      var i = 0
      while i < args.count {
        args2.add(rewriteTypeArg(aliases, args[i]))
        i = i + 1
      }
      TGenericApp(head = rewritePath(aliases, head), args = args2)
    }
    case TArray(size, element) ->
      TArray(size = rewriteTypeArg(aliases, size),
             element = rewriteTypeExpr(aliases, element))
    case TSlice(element) ->
      TSlice(element = rewriteTypeExpr(aliases, element))
    case TRefined(underlying, range) ->
      TRefined(underlying = rewritePath(aliases, underlying),
               range = rewriteRangeBound(aliases, range))
    case TTuple(types) -> {
      val xs: List[TypeExpr] = newList()
      var i = 0
      while i < types.count {
        xs.add(rewriteTypeExpr(aliases, types[i]))
        i = i + 1
      }
      TTuple(types = xs)
    }
    case TNullable(inner) -> TNullable(inner = rewriteTypeExpr(aliases, inner))
    case TFunction(parameters, retTy) -> {
      val ps: List[TypeExpr] = newList()
      var i = 0
      while i < parameters.count {
        ps.add(rewriteTypeExpr(aliases, parameters[i]))
        i = i + 1
      }
      TFunction(parameters = ps, retTy = rewriteTypeExpr(aliases, retTy))
    }
    case TParen(inner) -> TParen(inner = rewriteTypeExpr(aliases, inner))
    case TUnit  -> TUnit
    case TSelf  -> TSelf
    case TNever -> TNever
    case TError -> TError
  }
  TypeExpr(kind = kind, span = te.span)
}

func rewriteTypeArg(aliases: in List[String], a: in TypeArg): TypeArg {
  match a {
    case TAType(ty)    -> TAType(ty = rewriteTypeExpr(aliases, ty))
    case TAValue(expr) -> TAValue(expr = rewriteExpr(aliases, expr))
  }
}

func rewriteRangeBound(aliases: in List[String], rb: in RangeBound): RangeBound {
  match rb {
    case RBClosed(lo, hi)   -> RBClosed(lo = rewriteExpr(aliases, lo),
                                        hi = rewriteExpr(aliases, hi))
    case RBHalfOpen(lo, hi) -> RBHalfOpen(lo = rewriteExpr(aliases, lo),
                                          hi = rewriteExpr(aliases, hi))
    case RBLowerOpen(hi)    -> RBLowerOpen(hi = rewriteExpr(aliases, hi))
    case RBUpperOpen(lo)    -> RBUpperOpen(lo = rewriteExpr(aliases, lo))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Expr rewriting.
// ─────────────────────────────────────────────────────────────────────────────

pub func rewriteExpr(aliases: in List[String], e: in Expr): Expr {
  // Each arm uses an early `return Expr(kind = ..., span = e.span)`
  // rather than the more idiomatic `val kind = match e.kind { ... }`
  // form because the bootstrap-stage emitter mis-infers the result
  // kind when a match-as-expression's arms return different union
  // variants — every arm gets an empty inferred type and downstream
  // typechecks of the produced value cascade into T0030/T0033/T0063
  // "got [empty]" diagnostics on otherwise trivially-typed code.
  // The split-out helpers below keep each arm's reconstruction
  // pinned to the single ExprKind variant it actually produces.
  match e.kind {
    case EPath(path) ->
      return Expr(kind = EPath(path = rewritePath(aliases, path)), span = e.span)
    case EMember(receiver, memberName) -> {
      // `Alias.foo` collapse: when the receiver is a single-segment
      // `EPath` whose head is a known alias, drop the alias and
      // surface the member as a bare path so the post-rewrite
      // typechecker resolves it against the imported package's
      // top-level symbols.
      match receiver.kind {
        case EPath(p) -> {
          if p.segments.count == 1 and aliasContains(aliases, p.segments[0]) {
            val segs: List[String] = newList()
            segs.add(memberName)
            return Expr(kind = EPath(path = ModulePath(segments = segs, span = p.span)),
                        span = e.span)
          }
        }
        case _ -> ()
      }
      return Expr(kind = EMember(receiver = rewriteExpr(aliases, receiver),
                                 memberName = memberName),
                  span = e.span)
    }
    case ELiteral(lit) -> return Expr(kind = ELiteral(lit = lit), span = e.span)
    case ESelf         -> return Expr(kind = ESelf, span = e.span)
    case EResult       -> return Expr(kind = EResult, span = e.span)
    case EInterpolated(segments) -> {
      val ss: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISText(text, span) -> ss.add(ISText(text = text, span = span))
          case ISExpr(expr)       -> ss.add(ISExpr(expr = rewriteExpr(aliases, expr)))
        }
        i = i + 1
      }
      return Expr(kind = EInterpolated(segments = ss), span = e.span)
    }
    case EParen(inner) ->
      return Expr(kind = EParen(inner = rewriteExpr(aliases, inner)), span = e.span)
    case ETuple(exprs) -> {
      val xs: List[Expr] = newList()
      var i = 0
      while i < exprs.count {
        xs.add(rewriteExpr(aliases, exprs[i]))
        i = i + 1
      }
      return Expr(kind = ETuple(exprs = xs), span = e.span)
    }
    case EList(exprs) -> {
      val xs: List[Expr] = newList()
      var i = 0
      while i < exprs.count {
        xs.add(rewriteExpr(aliases, exprs[i]))
        i = i + 1
      }
      return Expr(kind = EList(exprs = xs), span = e.span)
    }
    case EIf(cond, thenBranch, elseBranch, thenForm) -> {
      val el = match elseBranch {
        case Some(eob) -> Some(value = rewriteExprOrBlock(aliases, eob))
        case None      -> elseBranch
      }
      return Expr(kind = EIf(cond = rewriteExpr(aliases, cond),
                             thenBranch = rewriteExprOrBlock(aliases, thenBranch),
                             elseBranch = el,
                             thenForm = thenForm),
                  span = e.span)
    }
    case EMatch(scrutinee, arms) -> {
      val arms2: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        arms2.add(rewriteMatchArm(aliases, arms[i]))
        i = i + 1
      }
      return Expr(kind = EMatch(scrutinee = rewriteExpr(aliases, scrutinee),
                                arms = arms2),
                  span = e.span)
    }
    case EAwait(inner) -> return Expr(kind = EAwait(inner = rewriteExpr(aliases, inner)), span = e.span)
    case EYield(inner) -> return Expr(kind = EYield(inner = rewriteExpr(aliases, inner)), span = e.span)
    case ESpawn(inner) -> return Expr(kind = ESpawn(inner = rewriteExpr(aliases, inner)), span = e.span)
    case ETry(inner)   -> return Expr(kind = ETry(inner = rewriteExpr(aliases, inner)), span = e.span)
    case EOld(inner)   -> return Expr(kind = EOld(inner = rewriteExpr(aliases, inner)), span = e.span)
    case EForall(binders, whereExpr, body) -> {
      val w = match whereExpr {
        case Some(x) -> Some(value = rewriteExpr(aliases, x))
        case None    -> whereExpr
      }
      return Expr(kind = EForall(binders = binders, whereExpr = w,
                                 body = rewriteExpr(aliases, body)),
                  span = e.span)
    }
    case EExists(binders, whereExpr, body) -> {
      val w = match whereExpr {
        case Some(x) -> Some(value = rewriteExpr(aliases, x))
        case None    -> whereExpr
      }
      return Expr(kind = EExists(binders = binders, whereExpr = w,
                                 body = rewriteExpr(aliases, body)),
                  span = e.span)
    }
    case ELambda(lambdaParams, body) ->
      return Expr(kind = ELambda(lambdaParams = lambdaParams,
                                 body = rewriteBlock(aliases, body)),
                  span = e.span)
    case ECall(fn, args) -> {
      val args2: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        args2.add(rewriteCallArg(aliases, args[i]))
        i = i + 1
      }
      return Expr(kind = ECall(fn = rewriteExpr(aliases, fn), args = args2),
                  span = e.span)
    }
    case ETypeApp(fn, args) -> {
      val args2: List[TypeArg] = newList()
      var i = 0
      while i < args.count {
        args2.add(rewriteTypeArg(aliases, args[i]))
        i = i + 1
      }
      return Expr(kind = ETypeApp(fn = rewriteExpr(aliases, fn), args = args2),
                  span = e.span)
    }
    case EIndex(receiver, indices) -> {
      val idxs: List[Expr] = newList()
      var i = 0
      while i < indices.count {
        idxs.add(rewriteExpr(aliases, indices[i]))
        i = i + 1
      }
      return Expr(kind = EIndex(receiver = rewriteExpr(aliases, receiver),
                                indices = idxs),
                  span = e.span)
    }
    case EPropagate(inner) ->
      return Expr(kind = EPropagate(inner = rewriteExpr(aliases, inner)), span = e.span)
    case EPrefix(op, operand) ->
      return Expr(kind = EPrefix(op = op, operand = rewriteExpr(aliases, operand)),
                  span = e.span)
    case EBinop(op, lhs, rhs) ->
      return Expr(kind = EBinop(op = op,
                                lhs = rewriteExpr(aliases, lhs),
                                rhs = rewriteExpr(aliases, rhs)),
                  span = e.span)
    case ERange(bound) ->
      return Expr(kind = ERange(bound = rewriteRangeBound(aliases, bound)), span = e.span)
    case EAssign(target, op, value) ->
      return Expr(kind = EAssign(target = rewriteExpr(aliases, target), op = op,
                                 value = rewriteExpr(aliases, value)),
                  span = e.span)
    case EBlock(block)  -> return Expr(kind = EBlock(block = rewriteBlock(aliases, block)), span = e.span)
    case EUnsafe(block) -> return Expr(kind = EUnsafe(block = rewriteBlock(aliases, block)), span = e.span)
  }
  // Unreachable — every ExprKind variant returns above.  The trailing
  // `return e` keeps the typechecker satisfied that the function has
  // a Expr-typed exit on every path.
  return e
}

func rewriteCallArg(aliases: in List[String], a: in CallArg): CallArg {
  match a {
    case CANamed(name, value, span) ->
      CANamed(name = name, value = rewriteExpr(aliases, value), span = span)
    case CAPositional(expr) ->
      CAPositional(expr = rewriteExpr(aliases, expr))
  }
}

func rewriteExprOrBlock(aliases: in List[String], eob: in ExprOrBlock): ExprOrBlock {
  match eob {
    case EOBExpr(expr)  -> EOBExpr(expr = rewriteExpr(aliases, expr))
    case EOBBlock(block) -> EOBBlock(block = rewriteBlock(aliases, block))
  }
}

func rewriteMatchArm(aliases: in List[String], arm: in MatchArm): MatchArm {
  val g = match arm.guard {
    case Some(x) -> Some(value = rewriteExpr(aliases, x))
    case None    -> arm.guard
  }
  MatchArm(pattern = rewritePattern(aliases, arm.pattern),
           guard   = g,
           body    = rewriteExprOrBlock(aliases, arm.body),
           span    = arm.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Pattern rewriting.
// ─────────────────────────────────────────────────────────────────────────────

func rewritePattern(aliases: in List[String], p: in Pattern): Pattern {
  val kind = match p.kind {
    case PConstructor(head, args) -> {
      val ps: List[Pattern] = newList()
      var i = 0
      while i < args.count {
        ps.add(rewritePattern(aliases, args[i]))
        i = i + 1
      }
      PConstructor(head = rewritePath(aliases, head), args = ps)
    }
    case PRecord(head, fields, ignoreRest) -> {
      val fs: List[RecordPatternField] = newList()
      var i = 0
      while i < fields.count {
        fs.add(match fields[i] {
          case RPFNamed(name, pattern, span) ->
            RPFNamed(name = name, pattern = rewritePattern(aliases, pattern), span = span)
          case RPFShort(name, span) -> RPFShort(name = name, span = span)
        })
        i = i + 1
      }
      PRecord(head = rewritePath(aliases, head), fields = fs, ignoreRest = ignoreRest)
    }
    case PTuple(patterns) -> {
      val ps: List[Pattern] = newList()
      var i = 0
      while i < patterns.count {
        ps.add(rewritePattern(aliases, patterns[i]))
        i = i + 1
      }
      PTuple(patterns = ps)
    }
    case PParen(inner) -> PParen(inner = rewritePattern(aliases, inner))
    case PTypeTest(inner, ty) ->
      PTypeTest(inner = rewritePattern(aliases, inner),
                ty    = rewriteTypeExpr(aliases, ty))
    case POr(patterns) -> {
      val ps: List[Pattern] = newList()
      var i = 0
      while i < patterns.count {
        ps.add(rewritePattern(aliases, patterns[i]))
        i = i + 1
      }
      POr(patterns = ps)
    }
    case PBinding(name, inner) -> {
      val inner2 = match inner {
        case Some(p2) -> Some(value = rewritePattern(aliases, p2))
        case None     -> inner
      }
      PBinding(name = name, inner = inner2)
    }
    case PRange(lo, inclusive, hi) ->
      PRange(lo = rewriteExpr(aliases, lo),
             inclusive = inclusive,
             hi = rewriteExpr(aliases, hi))
    case PWildcard  -> PWildcard
    case PLiteral(lit) -> PLiteral(lit = lit)
    case PError     -> PError
  }
  Pattern(kind = kind, span = p.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Block / Statement rewriting.
// ─────────────────────────────────────────────────────────────────────────────

func rewriteBlock(aliases: in List[String], b: in Block): Block {
  val ss: List[Statement] = newList()
  var i = 0
  while i < b.statements.count {
    ss.add(rewriteStatement(aliases, b.statements[i]))
    i = i + 1
  }
  Block(statements = ss, span = b.span)
}

func rewriteStatement(aliases: in List[String], s: in Statement): Statement {
  // Each arm uses an early `return` rather than the more idiomatic
  // `val kind = match s.kind { ... }` form because the bootstrap-stage
  // emitter mis-infers the result kind when a match-as-expression's
  // arms return different union variants — every arm gets an empty
  // inferred type and downstream typechecks of the produced value
  // cascade into T0030/T0033/T0063 "got [empty]" diagnostics.
  match s.kind {
    case SLocal(binding) ->
      return Statement(kind = SLocal(binding = rewriteLocalBinding(aliases, binding)),
                       span = s.span)
    case SAssign(target, op, value) ->
      return Statement(kind = SAssign(target = rewriteExpr(aliases, target),
                                      op     = op,
                                      value  = rewriteExpr(aliases, value)),
                       span = s.span)
    case SReturn(value) -> {
      val v = match value {
        case Some(e) -> Some(value = rewriteExpr(aliases, e))
        case None    -> value
      }
      return Statement(kind = SReturn(value = v), span = s.span)
    }
    case SBreak(label)    -> return Statement(kind = SBreak(label = label), span = s.span)
    case SContinue(label) -> return Statement(kind = SContinue(label = label), span = s.span)
    case SThrow(expr)     -> return Statement(kind = SThrow(expr = rewriteExpr(aliases, expr)), span = s.span)
    case STry(body, catches, finally_) -> {
      val cs: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        cs.add(rewriteCatch(aliases, catches[i]))
        i = i + 1
      }
      val fn = match finally_ {
        case Some(blk) -> Some(value = rewriteBlock(aliases, blk))
        case None      -> finally_
      }
      return Statement(kind = STry(body = rewriteBlock(aliases, body),
                                   catches = cs, finally_ = fn),
                       span = s.span)
    }
    case SDefer(body) ->
      return Statement(kind = SDefer(body = rewriteBlock(aliases, body)), span = s.span)
    case SScope(binding, body) ->
      return Statement(kind = SScope(binding = binding, body = rewriteBlock(aliases, body)),
                       span = s.span)
    case SFor(label, pat, iter, body) ->
      return Statement(kind = SFor(label = label,
                                   pat   = rewritePattern(aliases, pat),
                                   iter  = rewriteExpr(aliases, iter),
                                   body  = rewriteBlock(aliases, body)),
                       span = s.span)
    case SWhile(label, cond, body) ->
      return Statement(kind = SWhile(label = label,
                                     cond  = rewriteExpr(aliases, cond),
                                     body  = rewriteBlock(aliases, body)),
                       span = s.span)
    case SLoop(label, body) ->
      return Statement(kind = SLoop(label = label, body = rewriteBlock(aliases, body)),
                       span = s.span)
    case SInvariant(expr) ->
      return Statement(kind = SInvariant(expr = rewriteExpr(aliases, expr)), span = s.span)
    case SExpr(expr) ->
      return Statement(kind = SExpr(expr = rewriteExpr(aliases, expr)), span = s.span)
    case SRule(lhs, rhs) ->
      return Statement(kind = SRule(lhs = rewriteExpr(aliases, lhs),
                                    rhs = rewriteExpr(aliases, rhs)),
                       span = s.span)
    case SItem(item) -> return Statement(kind = SItem(item = item), span = s.span)
  }
  return s
}

func rewriteCatch(aliases: in List[String], c: in CatchClause): CatchClause {
  CatchClause(typeName = c.typeName,
              bindName = c.bindName,
              body     = rewriteBlock(aliases, c.body),
              span     = c.span)
}

func rewriteLocalBinding(aliases: in List[String], lb: in LocalBinding): LocalBinding {
  // Each arm uses an early `return` rather than match-expression
  // form because the self-hosted typechecker mis-infers the union
  // result type when arms return different variants of the same
  // union from inside a match-as-expression (#1170 ecosystem suite
  // surfaced this as an empty-type T0030/T0033/T0063 cascade on
  // basic `var i = pos; while i < n { i = i + 1 }` shapes the moment
  // the file carried any `import X as Y` declaration).  Splitting
  // each case into an early-returning statement keeps the inferred
  // result type pinned to the variant the case actually built.
  match lb {
    case LBVal(pat, ty, init) -> {
      val t = match ty {
        case Some(te) -> Some(value = rewriteTypeExpr(aliases, te))
        case None     -> ty
      }
      return LBVal(pat = rewritePattern(aliases, pat), ty = t,
                   init = rewriteExpr(aliases, init))
    }
    case LBVar(name, ty, init) -> {
      val t = match ty {
        case Some(te) -> Some(value = rewriteTypeExpr(aliases, te))
        case None     -> ty
      }
      val v = match init {
        case Some(e) -> Some(value = rewriteExpr(aliases, e))
        case None    -> init
      }
      return LBVar(name = name, ty = t, init = v)
    }
    case LBLet(name, ty, init) -> {
      val t = match ty {
        case Some(te) -> Some(value = rewriteTypeExpr(aliases, te))
        case None     -> ty
      }
      return LBLet(name = name, ty = t, init = rewriteExpr(aliases, init))
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Item-level rewriting.
// ─────────────────────────────────────────────────────────────────────────────

func rewriteParam(aliases: in List[String], p: in Param): Param {
  val d = match p.dflt {
    case Some(e) -> Some(value = rewriteExpr(aliases, e))
    case None    -> p.dflt
  }
  Param(mode = p.mode, name = p.name,
        ty = rewriteTypeExpr(aliases, p.ty),
        dflt = d, span = p.span)
}

func rewriteFunctionBody(aliases: in List[String], b: in FunctionBody): FunctionBody {
  // Early returns for the same bootstrap-emitter match-as-expression
  // bug documented on rewriteExpr — the result inferred from a
  // single match expression whose arms return different union
  // variants ends up empty-typed.
  match b {
    case FBExpr(expr)   -> return FBExpr(expr = rewriteExpr(aliases, expr))
    case FBBlock(block) -> return FBBlock(block = rewriteBlock(aliases, block))
  }
  return b
}

func rewriteFunctionDecl(aliases: in List[String], fn: in FunctionDecl): FunctionDecl {
  val ps: List[Param] = newList()
  var i = 0
  while i < fn.params.count {
    ps.add(rewriteParam(aliases, fn.params[i]))
    i = i + 1
  }
  val ret = match fn.ret {
    case Some(te) -> Some(value = rewriteTypeExpr(aliases, te))
    case None     -> fn.ret
  }
  val body = match fn.body {
    case Some(b) -> Some(value = rewriteFunctionBody(aliases, b))
    case None    -> fn.body
  }
  FunctionDecl(docComments = fn.docComments,
               annotations = fn.annotations,
               visibility  = fn.visibility,
               isAsync     = fn.isAsync,
               name        = fn.name,
               generics    = fn.generics,
               params      = ps,
               ret         = ret,
               whereClause = fn.whereClause,
               contracts   = fn.contracts,
               body        = body,
               span        = fn.span)
}

func rewriteFieldDecl(aliases: in List[String], f: in FieldDecl): FieldDecl {
  val d = match f.dflt {
    case Some(e) -> Some(value = rewriteExpr(aliases, e))
    case None    -> f.dflt
  }
  FieldDecl(docComments = f.docComments,
            annotations = f.annotations,
            visibility  = f.visibility,
            name        = f.name,
            ty          = rewriteTypeExpr(aliases, f.ty),
            dflt        = d,
            span        = f.span)
}

func rewriteRecordDecl(aliases: in List[String], rd: in RecordDecl): RecordDecl {
  val ms: List[RecordMember] = newList()
  var i = 0
  while i < rd.members.count {
    ms.add(match rd.members[i] {
      case RMField(field) -> RMField(field = rewriteFieldDecl(aliases, field))
      case RMInvariant(inv) ->
        RMInvariant(inv = InvariantClause(expr = rewriteExpr(aliases, inv.expr),
                                          span = inv.span))
      case RMFunc(fn) -> RMFunc(fn = rewriteFunctionDecl(aliases, fn))
    })
    i = i + 1
  }
  RecordDecl(name        = rd.name,
             generics    = rd.generics,
             whereClause = rd.whereClause,
             members     = ms,
             span        = rd.span)
}

func rewriteItem(aliases: in List[String], it: in Item): Item {
  val kind = match it.kind {
    case IFunc(decl)       -> IFunc(decl = rewriteFunctionDecl(aliases, decl))
    case IRecord(decl)     -> IRecord(decl = rewriteRecordDecl(aliases, decl))
    case IExposedRec(decl) -> IExposedRec(decl = rewriteRecordDecl(aliases, decl))
    case IConst(decl) ->
      IConst(decl = ConstDecl(name = decl.name,
                              ty   = rewriteTypeExpr(aliases, decl.ty),
                              init = rewriteExpr(aliases, decl.init),
                              span = decl.span))
    case IVal(decl) -> {
      val t = match decl.ty {
        case Some(te) -> Some(value = rewriteTypeExpr(aliases, te))
        case None     -> decl.ty
      }
      IVal(decl = ValDecl(pattern = decl.pattern,
                          ty      = t,
                          init    = rewriteExpr(aliases, decl.init),
                          span    = decl.span))
    }
    // The remaining item kinds either have no alias-rewriteable bodies
    // (extern declarations, scope-kind decls, interfaces / impl bodies,
    // tests, properties, fixtures, wires, configs, aspects) or are
    // handled by the parser's earlier passes.  Leave them untouched.
    case _ -> it.kind
  }
  Item(docComments = it.docComments,
       annotations = it.annotations,
       visibility  = it.visibility,
       kind        = kind,
       span        = it.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Public entry point.
// ─────────────────────────────────────────────────────────────────────────────

/// Apply package-alias rewriting to every `Item` in `file`.  No-op when
/// the file has no `import X as Y` declarations.
pub func rewriteFile(file: in SourceFile): SourceFile {
  val aliases = collectAliases(file.imports)
  if aliases.count == 0 { return file }
  val items: List[Item] = newList()
  var i = 0
  while i < file.items.count {
    items.add(rewriteItem(aliases, file.items[i]))
    i = i + 1
  }
  SourceFile(moduleDoc       = file.moduleDoc,
             fileAnnotations = file.fileAnnotations,
             packageDecl     = file.packageDecl,
             imports         = file.imports,
             items           = items,
             span            = file.span)
}
