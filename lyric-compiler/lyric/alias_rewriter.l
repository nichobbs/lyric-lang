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
  val kind = match e.kind {
    case EPath(path) -> EPath(path = rewritePath(aliases, path))
    case EMember(receiver, memberName) -> {
      // `Alias.foo` (where the receiver is a single-segment EPath
      // whose head is a known alias) collapses to bare `foo`.  Any
      // deeper member-chain still gets rewritten through the
      // receiver so `Alias.foo.bar` becomes `foo.bar` (the bar
      // lookup falls through to BCL / generic-method dispatch like
      // any other user-written `.member`).
      match receiver.kind {
        case EPath(p) -> {
          if p.segments.count == 1 and aliasContains(aliases, p.segments[0]) {
            val segs: List[String] = newList()
            segs.add(memberName)
            EPath(path = ModulePath(segments = segs, span = p.span))
          } else {
            EMember(receiver = rewriteExpr(aliases, receiver),
                    memberName = memberName)
          }
        }
        case _ -> EMember(receiver = rewriteExpr(aliases, receiver),
                          memberName = memberName)
      }
    }
    case ELiteral(lit) -> ELiteral(lit = lit)
    case ESelf         -> ESelf
    case EResult       -> EResult
    case EInterpolated(segments) -> {
      val ss: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segments.count {
        ss.add(match segments[i] {
          case ISText(text, span) -> ISText(text = text, span = span)
          case ISExpr(expr)       -> ISExpr(expr = rewriteExpr(aliases, expr))
        })
        i = i + 1
      }
      EInterpolated(segments = ss)
    }
    case EParen(inner) -> EParen(inner = rewriteExpr(aliases, inner))
    case ETuple(exprs) -> {
      val xs: List[Expr] = newList()
      var i = 0
      while i < exprs.count {
        xs.add(rewriteExpr(aliases, exprs[i]))
        i = i + 1
      }
      ETuple(exprs = xs)
    }
    case EList(exprs) -> {
      val xs: List[Expr] = newList()
      var i = 0
      while i < exprs.count {
        xs.add(rewriteExpr(aliases, exprs[i]))
        i = i + 1
      }
      EList(exprs = xs)
    }
    case EIf(cond, thenBranch, elseBranch, thenForm) -> {
      val el = match elseBranch {
        case Some(eob) -> Some(value = rewriteExprOrBlock(aliases, eob))
        case None      -> None
      }
      EIf(cond = rewriteExpr(aliases, cond),
          thenBranch = rewriteExprOrBlock(aliases, thenBranch),
          elseBranch = el,
          thenForm = thenForm)
    }
    case EMatch(scrutinee, arms) -> {
      val arms2: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        arms2.add(rewriteMatchArm(aliases, arms[i]))
        i = i + 1
      }
      EMatch(scrutinee = rewriteExpr(aliases, scrutinee), arms = arms2)
    }
    case EAwait(inner) -> EAwait(inner = rewriteExpr(aliases, inner))
    case EYield(inner) -> EYield(inner = rewriteExpr(aliases, inner))
    case ESpawn(inner) -> ESpawn(inner = rewriteExpr(aliases, inner))
    case ETry(inner)   -> ETry(inner = rewriteExpr(aliases, inner))
    case EOld(inner)   -> EOld(inner = rewriteExpr(aliases, inner))
    case EForall(binders, whereExpr, body) -> {
      val w = match whereExpr {
        case Some(x) -> Some(value = rewriteExpr(aliases, x))
        case None    -> None
      }
      EForall(binders = binders, whereExpr = w, body = rewriteExpr(aliases, body))
    }
    case EExists(binders, whereExpr, body) -> {
      val w = match whereExpr {
        case Some(x) -> Some(value = rewriteExpr(aliases, x))
        case None    -> None
      }
      EExists(binders = binders, whereExpr = w, body = rewriteExpr(aliases, body))
    }
    case ELambda(lambdaParams, body) ->
      ELambda(lambdaParams = lambdaParams, body = rewriteBlock(aliases, body))
    case ECall(fn, args) -> {
      val args2: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        args2.add(rewriteCallArg(aliases, args[i]))
        i = i + 1
      }
      ECall(fn = rewriteExpr(aliases, fn), args = args2)
    }
    case ETypeApp(fn, args) -> {
      val args2: List[TypeArg] = newList()
      var i = 0
      while i < args.count {
        args2.add(rewriteTypeArg(aliases, args[i]))
        i = i + 1
      }
      ETypeApp(fn = rewriteExpr(aliases, fn), args = args2)
    }
    case EIndex(receiver, indices) -> {
      val idxs: List[Expr] = newList()
      var i = 0
      while i < indices.count {
        idxs.add(rewriteExpr(aliases, indices[i]))
        i = i + 1
      }
      EIndex(receiver = rewriteExpr(aliases, receiver), indices = idxs)
    }
    case EPropagate(inner) -> EPropagate(inner = rewriteExpr(aliases, inner))
    case EPrefix(op, operand) ->
      EPrefix(op = op, operand = rewriteExpr(aliases, operand))
    case EBinop(op, lhs, rhs) ->
      EBinop(op = op, lhs = rewriteExpr(aliases, lhs),
             rhs = rewriteExpr(aliases, rhs))
    case ERange(bound) -> ERange(bound = rewriteRangeBound(aliases, bound))
    case EAssign(target, op, value) ->
      EAssign(target = rewriteExpr(aliases, target), op = op,
              value = rewriteExpr(aliases, value))
    case EBlock(block)  -> EBlock(block = rewriteBlock(aliases, block))
    case EUnsafe(block) -> EUnsafe(block = rewriteBlock(aliases, block))
  }
  Expr(kind = kind, span = e.span)
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
    case None    -> None
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
        case None     -> None
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
  val kind = match s.kind {
    case SLocal(binding) -> SLocal(binding = rewriteLocalBinding(aliases, binding))
    case SAssign(target, op, value) ->
      SAssign(target = rewriteExpr(aliases, target),
              op     = op,
              value  = rewriteExpr(aliases, value))
    case SReturn(value) -> {
      val v = match value {
        case Some(e) -> Some(value = rewriteExpr(aliases, e))
        case None    -> None
      }
      SReturn(value = v)
    }
    case SBreak(label)    -> SBreak(label = label)
    case SContinue(label) -> SContinue(label = label)
    case SThrow(expr)     -> SThrow(expr = rewriteExpr(aliases, expr))
    case STry(body, catches, finally_) -> {
      val cs: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        cs.add(rewriteCatch(aliases, catches[i]))
        i = i + 1
      }
      val fn = match finally_ {
        case Some(blk) -> Some(value = rewriteBlock(aliases, blk))
        case None      -> None
      }
      STry(body = rewriteBlock(aliases, body), catches = cs, finally_ = fn)
    }
    case SDefer(body) -> SDefer(body = rewriteBlock(aliases, body))
    case SScope(binding, body) ->
      SScope(binding = binding, body = rewriteBlock(aliases, body))
    case SFor(label, pat, iter, body) ->
      SFor(label = label,
           pat   = rewritePattern(aliases, pat),
           iter  = rewriteExpr(aliases, iter),
           body  = rewriteBlock(aliases, body))
    case SWhile(label, cond, body) ->
      SWhile(label = label,
             cond  = rewriteExpr(aliases, cond),
             body  = rewriteBlock(aliases, body))
    case SLoop(label, body) ->
      SLoop(label = label, body = rewriteBlock(aliases, body))
    case SInvariant(expr) -> SInvariant(expr = rewriteExpr(aliases, expr))
    case SExpr(expr)      -> SExpr(expr = rewriteExpr(aliases, expr))
    case SRule(lhs, rhs)  ->
      SRule(lhs = rewriteExpr(aliases, lhs), rhs = rewriteExpr(aliases, rhs))
    case SItem(item)      -> SItem(item = item)
  }
  Statement(kind = kind, span = s.span)
}

func rewriteCatch(aliases: in List[String], c: in CatchClause): CatchClause {
  CatchClause(typeName = c.typeName,
              bindName = c.bindName,
              body     = rewriteBlock(aliases, c.body),
              span     = c.span)
}

func rewriteLocalBinding(aliases: in List[String], lb: in LocalBinding): LocalBinding {
  match lb {
    case LBVal(pat, ty, init) -> {
      val t = match ty {
        case Some(te) -> Some(value = rewriteTypeExpr(aliases, te))
        case None     -> None
      }
      LBVal(pat = rewritePattern(aliases, pat), ty = t,
            init = rewriteExpr(aliases, init))
    }
    case LBVar(name, ty, init) -> {
      val t = match ty {
        case Some(te) -> Some(value = rewriteTypeExpr(aliases, te))
        case None     -> None
      }
      val v = match init {
        case Some(e) -> Some(value = rewriteExpr(aliases, e))
        case None    -> None
      }
      LBVar(name = name, ty = t, init = v)
    }
    case LBLet(name, ty, init) -> {
      val t = match ty {
        case Some(te) -> Some(value = rewriteTypeExpr(aliases, te))
        case None     -> None
      }
      LBLet(name = name, ty = t, init = rewriteExpr(aliases, init))
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Item-level rewriting.
// ─────────────────────────────────────────────────────────────────────────────

func rewriteParam(aliases: in List[String], p: in Param): Param {
  val d = match p.dflt {
    case Some(e) -> Some(value = rewriteExpr(aliases, e))
    case None    -> None
  }
  Param(mode = p.mode, name = p.name,
        ty = rewriteTypeExpr(aliases, p.ty),
        dflt = d, span = p.span)
}

func rewriteFunctionBody(aliases: in List[String], b: in FunctionBody): FunctionBody {
  match b {
    case FBExpr(expr)   -> FBExpr(expr = rewriteExpr(aliases, expr))
    case FBBlock(block) -> FBBlock(block = rewriteBlock(aliases, block))
  }
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
    case None     -> None
  }
  val body = match fn.body {
    case Some(b) -> Some(value = rewriteFunctionBody(aliases, b))
    case None    -> None
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
    case None    -> None
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
        case None     -> None
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
