//! build_expr.l - Lyric.Tir.Build: the expression builder (docs/70 §6.3, D366).
//!
//! Turns a type-checked function body into `Lyric.Tir` expressions and
//! statements, reading the types and callees the checker recorded per `NodeId`
//! (`exprTypes`, `calleeByNode`, ...) and numbering the locals itself.  This
//! first slice covers the kinds that need nothing beyond a node's type and the
//! local scope: literals, locals, tuples, lists, interpolation, primitive
//! operators, short-circuit operators, `if`, blocks and the structural
//! statements.  Every other kind is counted by name in `BuildEnv.uncovered`
//! and reported as an I0002 line: the builder never produces a node it cannot
//! stand behind (a missing piece is an I0002, never a guess).
package Lyric.Tir.Build

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Parser
import Lyric.Parser as Px
import Lyric.TypeChecker
import Lyric.Tir
import Lyric.Tir as TirT

/// The builder's state for one function: the lexical scopes of locals, the
/// next local number, the I0002 messages, and the kinds it has no case for.
pub record BuildEnv {
  ctx: TyConvCtx
  scopes: List[Map[String, LocalDecl]]
  nextLocal: List[Int]
  errors: List[String]
  uncovered: Map[String, Int]
  /// The next `NodeId` for a node the builder makes up (a conversion, a block with no
  /// node of its own, an interpolation text part).  Shared by the envs of one file so
  /// that ids stay unique; it starts above every id the numbering gives a node.
  nextNode: List[Int]
  /// The generic context of the function being built (empty or one entry): the type
  /// parameters an annotation may name.
  generics: List[GenericContext]
  /// The lambdas being built, innermost last: a local resolved from outside one is a
  /// capture of it.
  lambdas: List[LambdaFrame]
  /// The declarations the body being built reaches, by `SymbolId`, for the verifier.
  syms: Map[Int, TSymEntry] = newMap()
  /// The type a context fixes for an expression the checker typed with a hole
  /// (`None` or `[]` passed where the parameter's type is known), by `NodeId`.
  settled: Map[Int, Ty] = newMap()
  /// Where each uncovered kind was first met, as `line:column`.
  sites: Map[String, String] = newMap()
  /// The symbol of the member being built (empty or one entry): a method, an `impl` member or
  /// a protected entry has no top-level function symbol for `symTableFuncSymOf` to find.
  symOverride: List[SymbolId] = newList()
  /// The type of the member's receiver (empty or one entry): the body's `self`, declared as the
  /// leading parameter.
  recvTy: List[Ty] = newList()
  /// The generic type or `impl` the member being built belongs to (empty or one entry).
  memberOwner: List[MemberOwner] = newList()
}

/// The binder of a member's owner: the checker's key for it (a type's name, or the `impl`'s
/// key), the symbol that stands for it in a `TParam`, and its type parameters in order.
pub record MemberOwner {
  key: String
  sym: SymbolId
  names: List[String]
}

/// A lambda being built: the highest local number declared before it began (a local
/// numbered at most this is outside it) and the captures found so far.
pub record LambdaFrame {
  start: Int
  caps: List[Capture]
}

/// The first `NodeId` of a made-up node: above any id `renumberNodeIds` hands out.
pub func firstSynthNodeId(): Int {
  100000000
}

pub func newBuildEnv(ctx: in TyConvCtx): BuildEnv {
  val counter: List[Int] = newList()
  counter.add(firstSynthNodeId())
  newBuildEnvSharing(ctx, counter)
}

/// An env that draws made-up `NodeId`s from `counter`, shared with other envs.
pub func newBuildEnvSharing(ctx: in TyConvCtx, counter: in List[Int]): BuildEnv {
  val next: List[Int] = newList()
  next.add(0)
  BuildEnv(
    ctx = ctx,
    scopes = newList(),
    nextLocal = next,
    errors = newList(),
    uncovered = newMap(),
    nextNode = counter,
    generics = newList(),
    lambdas = newList()
  )
}

func freshNodeId(env: in BuildEnv): NodeId {
  val n = env.nextNode[0]
  env.nextNode[0] = n + 1
  NodeId(id = n)
}

func pushScope(env: in BuildEnv): Unit {
  env.scopes.add(newMap())
}

func popScope(env: in BuildEnv): Unit {
  env.scopes.removeAt(env.scopes.count - 1)
}

/// Declare a local in the innermost scope.
pub func declareLocal(env: in BuildEnv, name: in String, ty: in Ty, mutable: in Bool): LocalDecl {
  val n = env.nextLocal[0] + 1
  env.nextLocal[0] = n
  val d = LocalDecl(id = LocalId(id = n), name = name, ty = ty, mutable = mutable)
  val top = env.scopes[env.scopes.count - 1]
  if top.containsKey(name) {
    top.remove(name)
  }
  top.add(name, d)
  d
}

func lookupLocal(env: in BuildEnv, name: in String): Option[LocalDecl] {
  var i = env.scopes.count - 1
  while i >= 0 {
    match mapGet(env.scopes[i], name) {
      case Some(d) -> {
        noteCapture(env, d)
        return Some(value = d)
      }
      case None -> ()
    }
    i = i - 1
  }
  None
}

/// A local used inside a lambda but declared before it began is captured by it, and by
/// every enclosing lambda it is also outside of.  A `var` is captured by reference.
func noteCapture(env: in BuildEnv, d: in LocalDecl): Unit {
  for f in env.lambdas {
    if d.id.id <= f.start {
      var seen = false
      for c in f.caps {
        if c.local.id == d.id.id {
          seen = true
        }
      }
      if not seen {
        f.caps.add(Capture(local = d.id, mode = if d.mutable { CmByRef } else { CmByValue }))
      }
    }
  }
}

/// Count a construct the builder has no case for.
func noteUncovered(env: in BuildEnv, what: in String): Unit {
  val n = match mapGet(env.uncovered, what) { case Some(k) -> k; case None -> 0 }
  if env.uncovered.containsKey(what) {
    env.uncovered.remove(what)
  }
  env.uncovered.add(what, n + 1)
}

/// Count a construct the builder has no case for and remember where its kind was
/// first met.
func noteUncoveredAt(env: in BuildEnv, what: in String, sp: in Span): Unit {
  noteUncovered(env, what)
  if not env.sites.containsKey(what) {
    env.sites.add(what, toString(sp.startPos.line) + ":" + toString(sp.startPos.column))
  }
}

func uncoveredExpr(env: in BuildEnv, e: in Expr, what: in String): Option[TExpr] {
  noteUncoveredAt(env, what, e.span)
  env.errors.add(
    "I0002: the builder has no case for " + what + " at " + toString(e.span.startPos.line) + ":" +
      toString(e.span.startPos.column)
  )
  None
}

func uncoveredArgs(env: in BuildEnv, e: in Expr, what: in String): Option[List[TArg]] {
  val _ = uncoveredExpr(env, e, what)
  None
}

func mkExpr(e: in Expr, ty: in Ty, kind: in TExprKind): TExpr {
  TExpr(id = NodeId(id = e.nodeId), ty = ty, span = e.span, kind = kind)
}

func litOf(l: in Literal): TLit {
  match l {
    case LInt(v, _, _) -> TLInt(value = v)
    case LFloat(v, _, _) -> TLFloat(value = v)
    case LChar(c) -> TLChar(codepoint = c)
    case LString(t) -> TLString(text = t)
    case LTripleString(t) -> TLString(text = t)
    case LRawString(t) -> TLString(text = t)
    case LBool(b) -> TLBool(value = b)
    case LUnit -> TLUnit
  }
}

/// A range pattern's bound: a literal, possibly parenthesised or negated (`-5 ..= -1`).
func rangeBoundLit(e: in Expr): Option[TLit] {
  match e.kind {
    case ELiteral(l) -> Some(value = litOf(l))
    case EParen(inner) -> rangeBoundLit(inner)
    case EPrefix(op, operand) -> match op {
      case PreNeg -> match operand.kind {
        case ELiteral(l) -> match l {
          case LInt(v, _, _) -> Some(
            value = TLInt(
              value = 0i64 -
                v
            )
          )
          case LFloat(v, _, _) -> Some(
            value = TLFloat(
              value = 0.0 -
                v
            )
          )
          case _ -> None
        }
        case _ -> None
      }
      case _ -> None
    }
    case _ -> None
  }
}

func intrinsicOfBinop(op: in BinOp): Option[IntrinsicOp] {
  match op {
    case BAdd -> Some(value = IoAdd)
    case BSub -> Some(value = IoSub)
    case BMul -> Some(value = IoMul)
    case BDiv -> Some(value = IoDiv)
    case BMod -> Some(value = IoMod)
    case BXor -> Some(value = IoBitXor)
    case BEq -> Some(value = IoEq)
    case BNeq -> Some(value = IoNeq)
    case BLt -> Some(value = IoLt)
    case BLte -> Some(value = IoLte)
    case BGt -> Some(value = IoGt)
    case BGte -> Some(value = IoGte)
    case _ -> None
  }
}

func shortOfBinop(op: in BinOp): Option[ShortOp] {
  match op {
    case BAnd -> Some(value = ShAnd)
    case BOr -> Some(value = ShOr)
    case BImplies -> Some(value = ShImplies)
    case BCoalesce -> Some(value = ShCoalesce)
    case _ -> None
  }
}

/// `a == b` and `a != b` on values that are not primitives: one structural relation (language
/// reference 2.5, D172, D206), lowered by each backend by the operands' type. The operands have the
/// same type, the right one converted to the left's when the checker accepted a difference
/// (`opt == 5`). Any other operator on a declared type has no case.
func buildDeclaredEquality(
  env: in BuildEnv,
  e: in Expr,
  ty: in Ty,
  op: in BinOp,
  iop: in IntrinsicOp,
  lt: in TExpr,
  rt: in TExpr,
): Option[TExpr] {
  val isEq = match op { case BEq -> true; case BNeq -> true; case _ -> false }
  if not isEq {
    return uncoveredExpr(env, e, "an operator on a declared type")
  }
  val rhs = if tyEq(lt.ty, rt.ty) { Some(value = rt) } else { convertValue(env, rt, lt.ty) }
  match rhs {
    case Some(r2) -> {
      val two: List[TExpr] = newList()
      two.add(lt)
      two.add(r2)
      Some(value = mkExpr(e, ty, intrinsicCall(iop, two)))
    }
    case None -> uncoveredExpr(env, e, "an equality of operands of different types")
  }
}

func isPrimTy(t: in Ty): Bool {
  match t {
    case TPrim(_) -> true
    case _ -> false
  }
}

func buildAll(env: in BuildEnv, es: in List[Expr]): Option[List[TExpr]] {
  val res: List[TExpr] = newList()
  var ok = true
  for x in es {
    match buildExpr(env, x) {
      case Some(t) -> res.add(t)
      case None -> {
        ok = false
      }
    }
  }
  if ok {
    Some(value = res)
  } else {
    None
  }
}

func intrinsicCall(op: in IntrinsicOp, args: in List[TExpr]): TExprKind {
  val targs: List[TArg] = newList()
  for a in args {
    targs.add(TArgIn(value = a))
  }
  XCall(callee = Intrinsic(op = op), args = targs)
}

/// The interpolation part as a `String` expression: a part of another type is
/// converted by the built-in `toString`.
func stringPart(env: in BuildEnv, part: in TExpr): TExpr {
  match part.ty {
    case TPrim(TPString) -> part
    case _ -> {
      val one: List[TExpr] = newList()
      one.add(part)
      TExpr(
        id = freshNodeId(env),
        ty = tyString(),
        span = part.span,
        kind = intrinsicCall(IoBuiltin(name = "toString"), one)
      )
    }
  }
}

/// A name the checker resolved to a declaration: a value, constant, function value
/// or nullary case.
func buildRefPath(env: in BuildEnv, e: in Expr, ty: in Ty): Option[TExpr] {
  match refSite(env.ctx, e.nodeId) {
    case Some(r) -> match r.kind {
      case RkNullaryCase -> {
        noteCaseSym(env, r.sym)
        Some(value = mkExpr(e, ty, XConstruct(sym = r.sym, fields = newList())))
      }
      case _ -> {
        noteGlobalSym(env, r.sym, ty)
        Some(value = mkExpr(e, ty, XGlobal(sym = r.sym, typeArgs = newList())))
      }
    }
    case None -> {
      // A protected member names a field of its receiver without `self.`.
      val bare = match e.kind {
        case EPath(p) -> if p.segments.count == 1 { bareSelfField(env, e, p.segments[0]) } else { None }
        case _ -> None
      }
      match bare {
        case Some(bf) -> Some(value = mkExpr(e, ty, XField(recv = bf.recv, field = bf.field)))
        case None -> uncoveredExpr(env, e, "a name that is not a local")
      }
    }
  }
}

/// Build the expression `e`, or `None` after recording why in `env.errors`.
pub func buildExpr(env: in BuildEnv, e: in Expr): Option[TExpr] {
  val ty = match exprTy(env.ctx, e.nodeId) {
    case Ok(t) -> t
    case Err(msg) -> match mapGet(env.settled, e.nodeId) {
      case Some(t) -> t
      case None -> {
        env.errors.add(msg + " (at " + toString(e.span.startPos.line) + ":" + toString(e.span.startPos.column) + ")")
        return None
      }
    }
  }
  match e.kind {
    case ELiteral(l) -> Some(value = mkExpr(e, ty, XLit(lit = litOf(l))))
    case EParen(inner) -> buildExpr(env, inner)
    case ETuple(xs) -> match buildAll(env, xs) {
      case Some(ts) -> Some(value = mkExpr(e, ty, XTuple(elems = ts)))
      case None -> None
    }
    case EList(xs) -> match buildAll(env, xs) {
      case Some(ts) -> Some(value = mkExpr(e, ty, XListLit(elems = ts)))
      case None -> None
    }
    case EInterpolated(segs) -> {
      val parts: List[TExpr] = newList()
      var ok = true
      for seg in segs {
        match seg {
          case ISText(text, sp) -> parts.add(
            TExpr(
              id = freshNodeId(env),
              ty = tyString(),
              span = sp,
              kind = XLit(lit = TLString(text = text))
            )
          )
          case ISExpr(x) -> match buildExpr(env, x) {
            case Some(t) -> parts.add(stringPart(env, t))
            case None -> {
              ok = false
            }
          }
        }
      }
      if ok {
        Some(value = mkExpr(e, ty, XInterp(parts = parts)))
      } else {
        None
      }
    }
    case EPath(p) -> {
      if p.segments.count == 1 {
        match lookupLocal(env, p.segments[0]) {
          case Some(d) -> {
            if d.id.id < 0 {
              return None
            }
            return Some(value = mkExpr(e, ty, XLocal(local = d.id)))
          }
          case None -> ()
        }
      }
      buildRefPath(env, e, ty)
    }
    case EAwait(inner) -> match buildExpr(env, inner) {
      case Some(t) -> Some(value = mkExpr(e, ty, XAwait(inner = t)))
      case None -> None
    }
    case ESpawn(inner) -> match buildExpr(env, inner) {
      case Some(t) -> Some(value = mkExpr(e, ty, XSpawn(inner = t)))
      case None -> None
    }
    case EYield(inner) -> match buildExpr(env, inner) {
      case Some(t) -> Some(value = mkExpr(e, ty, XYield(inner = t)))
      case None -> None
    }
    case EPropagate(inner) -> match buildExpr(env, inner) {
      case Some(t) -> Some(value = mkExpr(e, ty, XPropagate(inner = t)))
      case None -> None
    }
    case EOld(inner) -> match buildExpr(env, inner) {
      case Some(t) -> Some(value = mkExpr(e, ty, XOld(inner = t)))
      case None -> None
    }
    case EResult -> Some(value = mkExpr(e, ty, XResult))
    case EPrefix(op, operand) -> {
      val iop = match op { case PreNeg -> Some(value = IoNeg); case PreNot -> Some(value = IoNot); case PreRef -> None }
      match iop {
        case None -> uncoveredExpr(env, e, "a reference prefix")
        case Some(o) -> match buildExpr(env, operand) {
          case Some(t) -> if isPrimTy(t.ty) {
            val one: List[TExpr] = newList()
            one.add(t)
            Some(value = mkExpr(e, ty, intrinsicCall(o, one)))
          } else {
            uncoveredExpr(env, e, "a prefix operator on a declared type")
          }
          case None -> None
        }
      }
    }
    case EBinop(op, lhs, rhs) -> {
      val l = buildExpr(env, lhs)
      // `x == None`: the checker leaves the bare right operand untyped, and equality
      // takes its type from the left one.
      match l {
        case Some(lt0) -> match op {
          case BEq -> settleHole(env, rhs, lt0.ty)
          case BNeq -> settleHole(env, rhs, lt0.ty)
          case _ -> ()
        }
        case None -> ()
      }
      val r = buildExpr(env, rhs)
      match l {
        case Some(lt) -> match r {
          case Some(rt) -> match shortOfBinop(op) {
            case Some(sop) -> Some(
              value = mkExpr(
                e,
                ty,
                XShort(op = sop, lhs = lt, rhs = rt)
              )
            )
            case None -> match intrinsicOfBinop(op) {
              case Some(iop) -> if isPrimTy(lt.ty) {
                val two: List[TExpr] = newList()
                two.add(lt)
                two.add(rt)
                Some(value = mkExpr(e, ty, intrinsicCall(iop, two)))
              } else {
                buildDeclaredEquality(env, e, ty, op, iop, lt, rt)
              }
              case None -> uncoveredExpr(env, e, "a bitwise operator")
            }
          }
          case None -> None
        }
        case None -> None
      }
    }
    case EIf(cond, thenBranch, elseBranch, _) -> {
      val c = buildExpr(env, cond)
      val t = buildOrBlock(env, thenBranch, ty)
      var el: Option[TExpr] = None
      var elOk = true
      match elseBranch {
        case Some(eb) -> match buildOrBlock(env, eb, ty) {
          case Some(x) -> {
            el = Some(value = x)
          }
          case None -> {
            elOk = false
          }
        }
        case None -> ()
      }
      match c {
        case Some(ct) -> match t {
          case Some(tt) -> if elOk {
            Some(value = mkExpr(e, ty, XIf(cond = ct, thenBranch = tt, elseBranch = el)))
          } else {
            None
          }
          case None -> None
        }
        case None -> None
      }
    }
    case EBlock(b) -> buildBlock(env, b, Some(value = ty), NodeId(id = e.nodeId))
    case EUnsafe(b) -> match buildBlock(env, b, Some(value = ty), freshNodeId(env)) {
      case Some(body) -> Some(value = mkExpr(e, ty, XUnsafe(body = body)))
      case None -> None
    }
    case ECall(fn, args) -> buildCall(env, e, ty, fn, args)
    case EMember(r, name) -> buildFieldRead(env, e, ty, r, name)
    case EIndex(r, idxs) -> buildIndexRead(env, e, ty, r, idxs)
    case EMatch(scrut, arms) -> buildMatch(env, e, ty, scrut, arms)
    case ELambda(ps, b) -> buildLambda(env, e, ty, ps, b)
    case EAssign(t, op, v) -> buildAssign(env, e, t, op, v)
    case ERange(_) -> uncoveredExpr(env, e, "a range")
    case ESelf -> match lookupLocal(env, "self") {
      case Some(d) -> Some(value = mkExpr(e, ty, XLocal(local = d.id)))
      case None -> uncoveredExpr(env, e, "self")
    }
    case ETry(_) -> uncoveredExpr(env, e, "a try expression")
    case ETypeApp(_, _) -> uncoveredExpr(env, e, "a type application")
    case EForall(_, _, _, _) -> uncoveredExpr(env, e, "a quantifier")
    case EExists(_, _, _, _) -> uncoveredExpr(env, e, "a quantifier")
    case EError -> uncoveredExpr(env, e, "an error node")
  }
}

func mkPat(p: in Pattern, ty: in Ty, kind: in TPatKind): TPat {
  TPat(id = NodeId(id = p.nodeId), ty = ty, span = p.span, kind = kind)
}

func uncoveredPat(env: in BuildEnv, p: in Pattern, what: in String): Option[TPat] {
  noteUncoveredAt(env, what, p.span)
  env.errors.add(
    "I0002: the builder has no case for " + what + " at " + toString(p.span.startPos.line) + ":" +
      toString(p.span.startPos.column)
  )
  None
}

/// Whether a built pattern binds a name anywhere inside it.
func patBinds(p: in TPat): Bool {
  match p.kind {
    case TpBind(_, _) -> true
    case TpCtor(_, args) -> {
      for a in args {
        if patBinds(a) {
          return true
        }
      }
      false
    }
    case TpRecord(_, fields) -> {
      for f in fields {
        if patBinds(f.pat) {
          return true
        }
      }
      false
    }
    case TpTuple(elems) -> {
      for a in elems {
        if patBinds(a) {
          return true
        }
      }
      false
    }
    case TpTypeTest(inner, _) -> patBinds(inner)
    case TpOr(alts) -> {
      for a in alts {
        if patBinds(a) {
          return true
        }
      }
      false
    }
    case _ -> false
  }
}

func buildPats(env: in BuildEnv, ps: in List[Pattern]): Option[List[TPat]] {
  val res: List[TPat] = newList()
  var ok = true
  for q in ps {
    match buildPat(env, q) {
      case Some(t) -> res.add(t)
      case None -> {
        ok = false
      }
    }
  }
  if ok {
    Some(value = res)
  } else {
    None
  }
}

/// The sub-patterns of a case pattern, one per payload field. The checker accepts fewer
/// sub-patterns than the case has fields and every backend binds the leading fields and
/// ignores the rest, so the missing trailing ones are wildcards.
func padCasePats(env: in BuildEnv, p: in Pattern, sym: in SymbolId, ts: in List[TPat]): List[TPat] {
  val sg = match mapGet(env.syms, sym.id) {
    case Some(entry) -> match entry.sig { case Some(x) -> x; case None -> return ts }
    case None -> return ts
  }
  if ts.count >= sg.params.count {
    return ts
  }
  val padded: List[TPat] = newList()
  for t in ts {
    padded.add(t)
  }
  var i = ts.count
  while i < sg.params.count {
    padded.add(TPat(id = freshNodeId(env), ty = sg.params[i].ty, span = p.span, kind = TpWild))
    i = i + 1
  }
  padded
}

/// Build a pattern, declaring the locals it binds in the innermost scope.
func buildPat(env: in BuildEnv, p: in Pattern): Option[TPat] {
  val ty = match patTy(env.ctx, p.nodeId) {
    case Ok(t) -> t
    case Err(msg) -> {
      env.errors.add(msg + " (at " + toString(p.span.startPos.line) + ":" + toString(p.span.startPos.column) + ")")
      return None
    }
  }
  match p.kind {
    case PWildcard -> Some(value = mkPat(p, ty, TpWild))
    case PParen(inner) -> buildPat(env, inner)
    case PLiteral(l) -> Some(value = mkPat(p, ty, TpLit(lit = litOf(l))))
    case PTuple(ps) -> match buildPats(env, ps) {
      case Some(ts) -> Some(value = mkPat(p, ty, TpTuple(elems = ts)))
      case None -> None
    }
    case PBinding(name, inner) -> {
      if name == "_" {
        return Some(value = mkPat(p, ty, TpWild))
      }
      match patSym(env.ctx, p.nodeId) {
        case Some(sym) -> {
          return match inner {
            case None -> {
              noteCaseSym(env, sym)
              Some(value = mkPat(p, ty, TpCtor(sym = sym, args = newList())))
            }
            case Some(_) -> uncoveredPat(env, p, "a case name with a sub-pattern")
          }
        }
        case None -> ()
      }
      if not patIsBinding(env.ctx, p.nodeId) {
        return uncoveredPat(env, p, "a bare name the checker did not bind")
      }
      // The name is bound before the sub-pattern, as the checker binds it, so a
      // sub-pattern binding the same name shadows it.
      val d = declareLocal(env, name, ty, false)
      var innerPat: Option[TPat] = None
      match inner {
        case Some(ip) -> match buildPat(env, ip) {
          case Some(t) -> {
            innerPat = Some(value = t)
          }
          case None -> return None
        }
        case None -> ()
      }
      Some(value = mkPat(p, ty, TpBind(decl = d, inner = innerPat)))
    }
    case PConstructor(_, args) -> match patSym(env.ctx, p.nodeId) {
      case Some(sym) -> match buildPats(env, args) {
        case Some(ts) -> {
          noteCaseSym(env, sym)
          Some(value = mkPat(p, ty, TpCtor(sym = sym, args = padCasePats(env, p, sym, ts))))
        }
        case None -> None
      }
      case None -> uncoveredPat(
        env,
        p,
        "a constructor pattern the checker did not resolve"
      )
    }
    case PRecord(_, fields, _) -> match patSym(env.ctx, p.nodeId) {
      case Some(sym) -> {
        val fps: List[TFieldPat] = newList()
        for f in fields {
          match f {
            case RPFNamed(fname, fp, _) -> match recordFieldPos(env.ctx, sym, fname) {
              case Some(ix) -> match buildPat(env, fp) {
                case Some(t) -> fps.add(
                  TFieldPat(
                    field = FieldRef(
                      owner = sym,
                      name = fname,
                      index = ix
                    ),
                    pat = t
                  )
                )
                case None -> return None
              }
              case None -> return uncoveredPat(env, p, "a record pattern field the builder cannot place")
            }
            case RPFShort(_, _) -> return uncoveredPat(env, p, "a shorthand record pattern field")
          }
        }
        Some(value = mkPat(p, ty, TpRecord(sym = sym, fields = fps)))
      }
      case None -> uncoveredPat(env, p, "a record pattern the checker did not resolve")
    }
    case PRange(lo, inclusive, hi, _) -> match rangeBoundLit(lo) {
      case Some(l) -> match rangeBoundLit(hi) {
        case Some(h) -> Some(
          value = mkPat(
            p,
            ty,
            TpRange(
              lo = l,
              hi = h,
              inclusive = inclusive
            )
          )
        )
        case None -> uncoveredPat(
          env,
          p,
          "a range pattern bound that is not a literal"
        )
      }
      case None -> uncoveredPat(
        env,
        p,
        "a range pattern bound that is not a literal"
      )
    }
    case POr(alts) -> {
      // Every alternative binds the same locals, and a local is declared once, so only
      // alternatives that bind nothing (literals, constants, nullary cases) are built.
      val built = match buildPats(env, alts) { case Some(x) -> x; case None -> return None }
      for a in built {
        if patBinds(a) {
          return uncoveredPat(env, p, "an or-pattern that binds a name")
        }
      }
      Some(value = mkPat(p, ty, TpOr(alts = built)))
    }
    case PTypeTest(_, _) -> uncoveredPat(env, p, "a type-test pattern")
    case PConstRef(_) -> uncoveredPat(env, p, "a constant pattern")
    case PError -> uncoveredPat(env, p, "an error pattern")
  }
}

func buildMatch(env: in BuildEnv, e: in Expr, ty: in Ty, scrut: in Expr, arms: in List[MatchArm]): Option[TExpr] {
  val proved = match matchProved(env.ctx, e.nodeId) {
    case Some(b) -> b
    case None -> return uncoveredExpr(env, e, "a match the checker recorded no verdict for")
  }
  val s = buildExpr(env, scrut)
  val tarms: List[TArm] = newList()
  var ok = true
  for arm in arms {
    pushScope(env)
    val pat = buildPat(env, arm.pattern)
    var guard: Option[TExpr] = None
    var armOk = true
    match arm.guard {
      case Some(g) -> match buildExpr(env, g) {
        case Some(t) -> {
          // The checker accepts a guard that never completes; the verifier wants a Bool.
          guard = match t.ty {
            case TNever -> Some(
              value = TExpr(
                id = freshNodeId(env),
                ty = tyBool(),
                span = t.span,
                kind = XConvert(kind = CvFromNever, inner = t)
              )
            )
            case _ -> Some(value = t)
          }
        }
        case None -> {
          armOk = false
        }
      }
      case None -> ()
    }
    val body = buildOrBlock(env, arm.body, ty)
    popScope(env)
    match pat {
      case Some(tp) -> match body {
        case Some(tb) -> if armOk {
          tarms.add(TArm(pat = tp, guard = guard, body = tb))
        } else {
          ok = false
        }
        case None -> {
          ok = false
        }
      }
      case None -> {
        ok = false
      }
    }
  }
  match s {
    case Some(st) -> if ok {
      Some(value = mkExpr(e, ty, XMatch(scrutinee = st, arms = tarms, exhaustive = proved)))
    } else {
      None
    }
    case None -> None
  }
}

/// A branch of an `if`: an expression, or a block typed as the `if` is.
/// An expression the checker may have left untyped (a bare `None`, `[]`, or a union case
/// whose type arguments only the context fixes) takes `ty`, the type its position gives it.
/// It only matters when the checker recorded no usable type for the node.
func settleHole(env: in BuildEnv, x: in Expr, ty: in Ty): Unit {
  if not env.settled.containsKey(x.nodeId) {
    env.settled.add(x.nodeId, ty)
  }
}

/// The tail expression of `blk`, when its last statement is one, settled to `ty`.
func settleBlockTail(env: in BuildEnv, blk: in Block, ty: in Ty): Unit {
  if blk.statements.count > 0 {
    match blk.statements[blk.statements.count - 1].kind {
      case SExpr(tail) -> settleHole(env, tail, ty)
      case _ -> ()
    }
  }
}

func buildOrBlock(env: in BuildEnv, b: in ExprOrBlock, ty: in Ty): Option[TExpr] {
  val built = match b {
    case EOBExpr(x) -> {
      settleHole(env, x, ty)
      buildExpr(env, x)
    }
    case EOBBlock(blk) -> {
      settleBlockTail(env, blk, ty)
      buildBlock(env, blk, Some(value = ty), freshNodeId(env))
    }
  }
  match built {
    case Some(t) -> coerceBranch(env, t, ty)
    case None -> None
  }
}

func isUnitTy(t: in Ty): Bool {
  match t {
    case TPrim(TPUnit) -> true
    case _ -> false
  }
}

/// Build a block as an `XBlock` typed `known`, or as its last expression's type
/// when none is given.  A last expression statement is the block's value unless
/// the block is `Unit`, where it stays a statement.
pub func buildBlock(env: in BuildEnv, b: in Block, known: in Option[Ty], id: in NodeId): Option[TExpr] {
  pushScope(env)
  val stmts: List[TStmt] = newList()
  var tail: Option[TExpr] = None
  var ok = true
  val unitBlock = match known { case Some(k) -> isUnitTy(k); case None -> false }
  var i = 0
  while i < b.statements.count {
    val s = b.statements[i]
    val last = i == b.statements.count - 1
    match s.kind {
      case SExpr(x) -> if last and not unitBlock {
        match buildExpr(env, x) {
          case Some(t) -> {
            tail = Some(value = t)
          }
          case None -> {
            ok = false
          }
        }
      } else {
        match buildStmt(env, s) {
          case Some(ts) -> stmts.add(ts)
          case None -> {
            ok = false
          }
        }
      }
      case _ -> match buildStmt(env, s) { case Some(ts) -> stmts.add(ts); case None -> { ok = false } }
    }
    i = i + 1
  }
  popScope(env)
  if not ok {
    return None
  }
  val ty = match known {
    case Some(k) -> k
    case None -> match tail {
      case Some(t) -> t.ty
      case None -> if endsInJump(stmts) { TirT.TNever } else { tyUnit() }
    }
  }
  Some(value = TExpr(id = id, ty = ty, span = b.span, kind = XBlock(stmts = stmts, tail = tail)))
}

/// Does control never fall out of the end of `stmts`: the last statement is a `return`,
/// `throw`, `break` or `continue`?  Such a block has type `Never` (the checker's rule).
func endsInJump(stmts: in List[TStmt]): Bool {
  if stmts.count == 0 {
    return false
  }
  match stmts[stmts.count - 1].kind {
    case TsReturn(_) -> true
    case TsThrow(_) -> true
    case TsBreak(_) -> true
    case TsContinue(_) -> true
    case _ -> false
  }
}

func loopBody(env: in BuildEnv, b: in Block): Option[TExpr] {
  buildBlock(env, b, Some(value = tyUnit()), freshNodeId(env))
}

func stmtOf(s: in Statement, kind: in TStmtKind): TStmt {
  TStmt(id = NodeId(id = s.nodeId), span = s.span, kind = kind)
}

func buildStmt(env: in BuildEnv, s: in Statement): Option[TStmt] {
  match s.kind {
    case SExpr(x) -> match buildExpr(env, x) {
      case Some(t) -> Some(value = stmtOf(s, TsExpr(expr = t)))
      case None -> None
    }
    case SReturn(v) -> match v {
      case None -> Some(value = stmtOf(s, TsReturn(value = None)))
      case Some(x) -> match buildExpr(env, x) {
        case Some(t) -> Some(value = stmtOf(s, TsReturn(value = Some(value = t))))
        case None -> None
      }
    }
    case SBreak(label) -> Some(value = stmtOf(s, TsBreak(label = label)))
    case SContinue(label) -> Some(value = stmtOf(s, TsContinue(label = label)))
    case SLocal(binding) -> buildLocal(env, s, binding)
    case SWhile(label, cond, body) -> {
      val c = buildExpr(env, cond)
      val bd = loopBody(env, body)
      match c {
        case Some(ct) -> match bd {
          case Some(bt) -> Some(value = stmtOf(s, TsWhile(label = label, cond = ct, body = bt)))
          case None -> None
        }
        case None -> None
      }
    }
    case SLoop(label, body) -> {
      match loopBody(env, body) {
        case Some(bt) -> Some(value = stmtOf(s, TsLoop(label = label, body = bt)))
        case None -> None
      }
    }
    case SFor(label, pat, iter, body) -> {
      val it = match buildForIter(env, iter) { case Some(x) -> x; case None -> return None }
      pushScope(env)
      val built = match buildPat(env, pat) {
        case Some(tp) -> match loopBody(env, body) {
          case Some(bt) -> Some(
            value = stmtOf(
              s,
              TsFor(label = label, pat = tp, iter = it, body = bt)
            )
          )
          case None -> None
        }
        case None -> None
      }
      popScope(env)
      built
    }
    case SAssign(t, op, v) -> {
      val ae = Expr(kind = EAssign(target = t, op = op, value = v), span = s.span, nodeId = freshNodeId(env).id)
      match buildAssign(env, ae, t, op, v) {
        case Some(x) -> Some(value = stmtOf(s, TsExpr(expr = x)))
        case None -> None
      }
    }
    case SThrow(_) -> uncoveredStmt(env, s, "a throw")
    case STry(body, catches, fin) -> {
      val tb = match loopBody(env, body) { case Some(x) -> x; case None -> return None }
      val tcs: List[TCatch] = newList()
      for c in catches {
        pushScope(env)
        var binding: Option[LocalDecl] = None
        match c.bindName {
          case Some(n) -> {
            binding = Some(value = declareLocal(env, n, TException, false))
          }
          case None -> ()
        }
        val built = loopBody(env, c.body)
        popScope(env)
        match built {
          case Some(cb) -> tcs.add(TCatch(binding = binding, exceptionType = c.typeName, body = cb))
          case None -> return None
        }
      }
      var tfin: Option[TExpr] = None
      match fin {
        case Some(fb) -> match loopBody(env, fb) { case Some(x) -> { tfin = Some(value = x) }; case None -> return None }
        case None -> ()
      }
      Some(value = stmtOf(s, TsTry(body = tb, catches = tcs, finallyBody = tfin)))
    }
    case SDefer(body) -> match loopBody(env, body) {
      case Some(bt) -> Some(value = stmtOf(s, TsDefer(body = bt)))
      case None -> None
    }
    case SScope(binding, body) -> {
      // A scope's handle binding has no type to give yet.
      if isSome(binding) {
        return uncoveredStmt(env, s, "a scope with a handle binding")
      }
      match loopBody(env, body) {
        case Some(bt) -> Some(value = stmtOf(s, TsScope(binding = None, body = bt)))
        case None -> None
      }
    }
    case SInvariant(_) -> uncoveredStmt(env, s, "a loop invariant")
    case SRule(_, _) -> uncoveredStmt(env, s, "a rule")
    case SItem(_) -> uncoveredStmt(env, s, "a local item")
  }
}

/// The iterable of a `for`.  A range is typed by the checker only as the loop's
/// element type, so its `XRange` takes the type of its bounds (docs/01: a range
/// exists only in iterator position).
func buildForIter(env: in BuildEnv, iter: in Expr): Option[TExpr] {
  match iter.kind {
    case ERange(bound) -> {
      val parts = match bound {
        case RBClosed(lo, hi) -> Some(value = (lo, hi, true))
        case RBHalfOpen(lo, hi, _) -> Some(value = (lo, hi, false))
        case _ -> None
      }
      match parts {
        case None -> uncoveredExpr(env, iter, "an open-ended range")
        case Some((lo, hi, inclusive)) -> {
          val l = match buildExpr(env, lo) { case Some(x) -> x; case None -> return None }
          val h = match buildExpr(env, hi) { case Some(x) -> x; case None -> return None }
          Some(value = mkExpr(iter, l.ty, XRange(lo = l, hi = h, inclusive = inclusive)))
        }
      }
    }
    case _ -> buildExpr(env, iter)
  }
}

func uncoveredStmt(env: in BuildEnv, s: in Statement, what: in String): Option[TStmt] {
  noteUncoveredAt(env, what, s.span)
  env.errors.add(
    "I0002: the builder has no case for " + what + " at " + toString(s.span.startPos.line) + ":" +
      toString(s.span.startPos.column)
  )
  None
}

/// A `val`, `let` or `var` of one name: its local takes the annotation's type when
/// there is one (the initializer is converted to it) and the initializer's otherwise,
/// declared after the initializer is built so the initializer cannot see it.  A
/// `var` without an initializer takes its annotation's type.
/// The names a pattern binds, in order.
func patBoundNames(p: in Pattern, into: in List[String]): Unit {
  match p.kind {
    case PBinding(name, inner) -> {
      if name != "_" {
        into.add(name)
      }
      match inner {
        case Some(q) -> patBoundNames(q, into)
        case None -> ()
      }
    }
    case PConstructor(_, args) -> {
      for a in args {
        patBoundNames(a, into)
      }
    }
    case PRecord(_, fields, _) -> {
      for f in fields {
        match f {
          case RPFNamed(_, q, _) -> patBoundNames(q, into)
          case RPFShort(n, _) -> into.add(n)
        }
      }
    }
    case PTuple(ps) -> {
      for q in ps {
        patBoundNames(q, into)
      }
    }
    case PParen(q) -> patBoundNames(q, into)
    case PTypeTest(q, _) -> patBoundNames(q, into)
    case POr(alts) -> {
      if alts.count > 0 {
        patBoundNames(alts[0], into)
      }
    }
    case _ -> ()
  }
}

/// Make `name` a binding whose initializer failed: a later use of it is not a new
/// unbuildable construct, only the consequence of the one already counted.
func poisonName(env: in BuildEnv, name: in String): Unit {
  val top = env.scopes[env.scopes.count - 1]
  if top.containsKey(name) {
    top.remove(name)
  }
  top.add(name, LocalDecl(id = LocalId(id = -1), name = name, ty = TirT.TNever, mutable = false))
}

/// A local binding. When it cannot be built, the names it would bind are poisoned so the
/// uses that follow are not counted as unbuildable names of their own.
func buildLocal(env: in BuildEnv, s: in Statement, binding: in Px.LocalBinding): Option[TStmt] {
  val built = buildLocalCore(env, s, binding)
  match built {
    case Some(_) -> ()
    case None -> {
      match binding {
        case LBVal(pat, _, _) -> {
          val names: List[String] = newList()
          patBoundNames(pat, names)
          for n in names {
            poisonName(env, n)
          }
        }
        case LBLet(name, _, _) -> poisonName(env, name)
        case LBVar(name, _, _) -> poisonName(env, name)
      }
    }
  }
  built
}

func buildLocalCore(env: in BuildEnv, s: in Statement, binding: in Px.LocalBinding): Option[TStmt] {
  match binding {
    case LBVal(pat, ann, init) -> match pat.kind {
      case PBinding(name, None) -> buildLet(env, s, pat, name, ann, init)
      case _ -> buildLetPattern(env, s, pat, ann, init)
    }
    case LBLet(name, ann, init) -> {
      val pat = Pattern(kind = PBinding(name = name, inner = None), span = s.span, nodeId = freshNodeId(env).id)
      buildLet(env, s, pat, name, ann, init)
    }
    case LBVar(name, ann, init) -> match init {
      case None -> match ann {
        case Some(te) -> match annotatedTy(env, te) {
          case Some(want) -> {
            val d = declareLocal(env, name, want, true)
            Some(value = stmtOf(s, TsVar(decl = d, init = None)))
          }
          case None -> None
        }
        case None -> uncoveredStmt(
          env,
          s,
          "a var without an initializer or annotation"
        )
      }
      case Some(x) -> match buildInit(env, s, ann, x) {
        case Some(t) -> {
          val d = declareLocal(env, name, t.ty, true)
          Some(value = stmtOf(s, TsVar(decl = d, init = Some(value = t))))
        }
        case None -> None
      }
    }
  }
}

/// The type an annotation names, as a `Ty`.
func annotatedTy(env: in BuildEnv, te: in TypeExpr): Option[Ty] {
  // The checker has already reported an annotation that does not resolve, so the
  // diagnostics of this second resolution are not read.
  val diag: List[Diagnostic] = newList()
  val gc = if env.generics.count > 0 {
    env.generics[0]
  } else {
    GenericContext(params = newList(), owners = newList(), stackDepths = newList())
  }
  match tyOfType(env.ctx, resolveType(env.ctx.tbl, gc, diag, te)) {
    case Ok(w) -> Some(value = w)
    case Err(msg) -> {
      env.errors.add(msg)
      None
    }
  }
}

/// The initializer of a binding as a value of the annotated type, or as built when
/// there is no annotation.
func buildInit(env: in BuildEnv, s: in Statement, ann: in Option[TypeExpr], init: in Expr): Option[TExpr] {
  val t = match buildExpr(env, init) { case Some(x) -> x; case None -> return None }
  match ann {
    case None -> Some(value = t)
    case Some(te) -> {
      val want = match annotatedTy(env, te) { case Some(w) -> w; case None -> return None }
      match convertValue(env, t, want) {
        case Some(c) -> Some(value = c)
        case None -> {
          noteUncovered(env, "an annotated binding conversion")
          env.errors.add(
            "I0002: the builder has no case for an annotated binding conversion at " + toString(s.span.startPos.line) + ":" +
              toString(s.span.startPos.column)
          )
          None
        }
      }
    }
  }
}

/// A `val` of a pattern: the initializer is built first (it cannot see the names the
/// pattern binds), then the pattern, which declares them.
func buildLetPattern(
  env: in BuildEnv, s: in Statement, pat: in Pattern, ann: in Option[TypeExpr], init: in Expr
): Option[TStmt] {
  val t = match buildInit(env, s, ann, init) { case Some(x) -> x; case None -> return None }
  match buildPat(env, pat) {
    case Some(tp) -> Some(value = stmtOf(s, TsLet(pat = tp, init = t)))
    case None -> None
  }
}

func buildLet(
  env: in BuildEnv,
  s: in Statement,
  pat: in Pattern,
  name: in String,
  ann: in Option[TypeExpr],
  init: in Expr,
): Option[TStmt] {
  match buildInit(env, s, ann, init) {
    case Some(t) -> {
      val d = declareLocal(env, name, t.ty, false)
      val tp = TPat(id = NodeId(id = pat.nodeId), ty = t.ty, span = pat.span, kind = TpBind(decl = d, inner = None))
      Some(value = stmtOf(s, TsLet(pat = tp, init = t)))
    }
    case None -> None
  }
}

/// What building a function yields beyond its body: the parameters as declared locals
/// with their modes and defaults, the return type, and the contract clauses.
record FnCore {
  sym: Option[SymbolId]
  typeNames: List[String]
  params: List[TParamDecl]
  ret: Ty
  pre: List[TExpr]
  post: List[TExpr]
  body: TExpr
  barrier: Option[TExpr] = None
}

func buildFnCore(env: in BuildEnv, fn: in FunctionDecl, tbl: in SymbolTable, wantSym: in Bool): Option[FnCore] {
  val gc = GenericContext(params = newList(), owners = newList(), stackDepths = newList())
  val names = extractGenericNames(fn.generics)
  val sym = if env.symOverride.count > 0 { Some(value = env.symOverride[0]) } else { symTableFuncSymOf(tbl, fn) }
  // A member of a generic type or `impl` has the owner's parameters first and its own after, all
  // indexed under the member's symbol.  The checker keys the owner's by the owner and the member's
  // own by `Owner.fn`; both are bound to the member here.
  var fnKey = fn.name
  var allNames = names
  if env.memberOwner.count > 0 {
    val mo = env.memberOwner[0]
    fnKey = mo.key + "." + fn.name
    if mo.names.count > 0 {
      match sym {
        case Some(sy) -> {
          tyConvBind(env.ctx, mo.key, sy, mo.names)
          gctxPushOwned(gc, mo.names, mo.key)
        }
        case None -> {
          noteUncovered(env, "a member of a generic type with no symbol")
          env.errors.add("I0002: the builder has no symbol for the member: " + fn.name)
          return None
        }
      }
      allNames = newList()
      for n in mo.names {
        allNames.add(n)
      }
      for n in names {
        allNames.add(n)
      }
    }
  }
  match fn.generics {
    case Some(_) -> {
      match sym {
        case Some(sy) -> {
          tyConvBind(env.ctx, fnKey, sy, allNames)
          gctxPushOwned(gc, names, fnKey)
        }
        case None -> {
          noteUncovered(env, "a generic function with no symbol")
          env.errors.add("I0002: the builder has no symbol for the generic function: " + fn.name)
          return None
        }
      }
    }
    case None -> ()
  }
  if wantSym and not isSome(sym) {
    noteUncovered(env, "a function with no symbol")
    env.errors.add("I0002: the builder has no symbol for the function: " + fn.name)
    return None
  }
  pushScope(env)
  env.generics.clear()
  env.generics.add(gc)
  val diag: List[Diagnostic] = newList()
  var ok = true
  val params: List[TParamDecl] = newList()
  if env.recvTy.count > 0 {
    val selfLocal = declareLocal(env, "self", env.recvTy[0], false)
    params.add(TParamDecl(local = selfLocal, mode = TMIn, dflt = None))
  }
  for p in fn.params {
    var dflt: Option[TExpr] = None
    match p.dflt {
      case Some(dx) -> match buildExpr(env, dx) {
        case Some(t) -> {
          dflt = Some(value = t)
        }
        case None -> {
          ok = false
        }
      }
      case None -> ()
    }
    match tyOfType(env.ctx, resolveType(tbl, gc, diag, p.ty)) {
      case Ok(t) -> {
        val d = declareLocal(env, p.name, t, p.mode != PMIn)
        params.add(TParamDecl(local = d, mode = modeOfParam(p.mode), dflt = dflt))
      }
      case Err(msg) -> {
        env.errors.add(msg)
        ok = false
      }
    }
  }
  var ret: Ty = TPrim(kind = TPUnit)
  match fn.ret {
    case Some(te) -> match tyOfType(env.ctx, resolveType(tbl, gc, diag, te)) {
      case Ok(t) -> {
        ret = t
      }
      case Err(msg) -> {
        env.errors.add(msg)
        ok = false
      }
    }
    case None -> ()
  }
  val pre: List[TExpr] = newList()
  val post: List[TExpr] = newList()
  var barrier: Option[TExpr] = None
  if ok {
    for c in fn.contracts {
      match c {
        case CCRequires(x, _) -> match buildExpr(env, x) { case Some(t) -> pre.add(t); case None -> { ok = false } }
        case CCEnsures(x, _) -> match buildExpr(env, x) { case Some(t) -> post.add(t); case None -> { ok = false } }
        case CCWhen(x, _) -> match buildExpr(env, x) {
          case Some(t) -> {
            barrier = Some(value = t)
          }
          case None -> {
            ok = false
          }
        }
        case _ -> ()
      }
    }
  }
  var res: Option[TExpr] = None
  if ok {
    match fn.body {
      case Some(FBBlock(b)) -> {
        res = buildBlock(env, b, None, freshNodeId(env))
      }
      case Some(FBExpr(x)) -> {
        res = buildExpr(env, x)
      }
      case None -> ()
    }
    // The body is the function's value: it meets the declared return type through a
    // conversion the types alone derive, or the build counts the one it cannot.
    if not isUnitTy(ret) {
      match res {
        case Some(b) -> {
          res = coerceBranch(env, b, ret)
        }
        case None -> ()
      }
    }
  }
  popScope(env)
  match res {
    case Some(b) -> Some(
      value = FnCore(
        sym = sym,
        typeNames = allNames,
        params = params,
        ret = ret,
        pre = pre,
        post = post,
        body = b,
        barrier = barrier
      )
    )
    case None -> None
  }
}

/// A function's body as TIR, or `None` with the reasons in `env.errors`.  The
/// parameters become the outermost locals; a generic function binds its type
/// parameters to its symbol.  Contracts are built with the body: a clause the
/// builder has no case for fails it like any other expression.
pub func buildFnBody(env: in BuildEnv, fn: in FunctionDecl, tbl: in SymbolTable): Option[TExpr] {
  match buildFnCore(env, fn, tbl, false) {
    case Some(c) -> Some(value = c.body)
    case None -> None
  }
}

/// A function with a body as a `TFnDecl` (docs/70 §6.2): its symbol, type
/// parameters (their bounds are not converted yet), parameters with modes and
/// defaults, return type, contracts as `preconds`/`postconds`, and the body.
pub func buildFnDecl(env: in BuildEnv, fn: in FunctionDecl, tbl: in SymbolTable): Option[TFnDecl] {
  match buildFnCore(env, fn, tbl, true) {
    case Some(c) -> {
      val tps: List[TTypeParam] = newList()
      for n in c.typeNames {
        tps.add(TTypeParam(name = n, bounds = newList(), valueTy = None))
      }
      val sym = match c.sym { case Some(x) -> x; case None -> SymbolId(id = 0) }
      val ownerCount = if env.memberOwner.count > 0 { env.memberOwner[0].names.count } else { 0 }
      Some(
        value = TFnDecl(
          sym = sym,
          typeParams = tps,
          params = c.params,
          ret = c.ret,
          isAsync = fn.isAsync,
          preconds = c.pre,
          postconds = c.post,
          body = Some(value = c.body),
          span = fn.span,
          barrier = c.barrier,
          ownerParamCount = ownerCount
        )
      )
    }
    case None -> None
  }
}

/// How many function bodies of a file the builder covers, and what it has no
/// case for, by kind with the number of nodes (the `--verify-ir` census, D366).
pub record BuildCensus {
  total: Int
  built: Int
  uncovered: Map[String, Int]
  /// Where each uncovered kind was first met in the file, as `line:column`.
  sites: Map[String, String] = newMap()
  /// The first I0002 message of each body that did not build: the cause, where
  /// `uncovered` does not count the uses a failed binding leaves undefined (D569).
  firstErrors: List[String] = newList()
  /// The built functions as a package, with the declarations their bodies reach.
  pkg: TPackage = TPackage(name = "", symbols = newList(), funcs = newList())
}

/// Build every function body of `file` that has one, each with a fresh
/// `BuildEnv`, and total the outcome.
pub func buildCensus(ctx: in TyConvCtx, tbl: in SymbolTable, file: in SourceFile): BuildCensus {
  val pb = buildPackage(ctx, tbl, file, "")
  val firstErrors: List[String] = newList()
  for f in pb.failed {
    if f.messages.count > 0 {
      firstErrors.add(f.name + ": " + f.messages[0])
    }
  }
  BuildCensus(
    total = pb.total,
    built = pb.built,
    uncovered = pb.uncovered,
    sites = pb.sites,
    firstErrors = firstErrors,
    pkg = pb.pkg
  )
}

/// The uncovered kinds of `c`, most frequent first, as `kind x count`.
pub func buildCensusLines(c: in BuildCensus, limit: in Int): List[String] {
  val res: List[String] = newList()
  val taken: Map[String, Bool] = newMap()
  var round = 0
  while round < limit {
    var best = ""
    var bestN = 0
    for k in mapKeys(c.uncovered) {
      if not taken.containsKey(k) {
        val n = match mapGet(c.uncovered, k) { case Some(v) -> v; case None -> 0 }
        if n > bestN {
          best = k
          bestN = n
        }
      }
    }
    if bestN == 0 {
      return res
    }
    taken.add(best, true)
    val at = match mapGet(c.sites, best) { case Some(a) -> " (first at " + a + ")"; case None -> "" }
    res.add(best + " x " + toString(bestN) + at)
    round = round + 1
  }
  res
}

/// The call's arguments as plain expressions, when none is named.
func positionalArgs(args: in List[CallArg]): Option[List[Expr]] {
  val res: List[Expr] = newList()
  for a in args {
    match a {
      case CAPositional(x) -> res.add(x)
      case CANamed(_, _, _) -> return None
    }
  }
  Some(value = res)
}

func inArgs(ts: in List[TExpr]): List[TArg] {
  val res: List[TArg] = newList()
  for t in ts {
    res.add(TArgIn(value = t))
  }
  res
}

/// The implicit widening the language allows from `from` to `to`
/// (docs/01 §4.1: `Byte < Int < Long`, `Byte < UInt < ULong`, `Float < Double`).
func widenKind(from: in Ty, to: in Ty): Option[ConvKind] {
  match from {
    case TPrim(f) -> match to {
      case TPrim(t) -> {
        val ok = match f {
          case TPByte -> match t {
            case TPInt -> true
            case TPLong -> true
            case TPUInt -> true
            case TPULong -> true
            case _ -> false
          }
          case TPInt -> match t { case TPLong -> true; case _ -> false }
          case TPUInt -> match t { case TPULong -> true; case _ -> false }
          case TPFloat -> match t { case TPDouble -> true; case _ -> false }
          case _ -> false
        }
        if ok {
          Some(value = CvWiden(to = t))
        } else {
          None
        }
      }
      case _ -> None
    }
    case _ -> None
  }
}

/// A call: a built-in by its recorded name, a call through a function value,
/// or a call to a declared non-generic function with in-mode arguments.  Other
/// calls (methods, constructors, generics, defaults, `out` and `inout`
/// arguments, conversions other than widening) are counted and reported by what
/// they need.
func buildCall(env: in BuildEnv, e: in Expr, ty: in Ty, fn: in Expr, args: in List[CallArg]): Option[TExpr] {
  val tbl = env.ctx.tbl
  match mapGet(tbl.builtinByNode, e.nodeId) {
    case Some(name) -> return buildBuiltinCall(env, e, ty, name, fn, args)
    case None -> ()
  }
  if tbl.indirectByNode.containsKey(e.nodeId) {
    return buildIndirectCall(env, e, ty, fn, args)
  }
  match mapGet(tbl.callSigByNode, e.nodeId) {
    case Some(sig) -> match mapGet(tbl.calleeByNode, e.nodeId) {
      case Some(sym) -> match fn.kind {
        case EPath(_) -> return buildDirectCall(env, e, ty, sym, sig, args)
        case EIndex(_, _) -> return buildDirectCall(env, e, ty, sym, sig, args)
        // `Pkg.f(x)` and `Type.f(x)`: a function the checker resolved by its qualified name.
        // A method call has its own table and is built below.
        case EMember(_, _) -> if not tbl.methodCallByNode.containsKey(e.nodeId) {
          return buildDirectCall(env, e, ty, sym, sig, args)
        }
        case _ -> return uncoveredExpr(env, e, "a package-qualified or static call")
      }
      case None -> ()
    }
    case None -> ()
  }
  match mapGet(tbl.ctorSigByNode, e.nodeId) {
    case Some(sig) -> match mapGet(tbl.calleeByNode, e.nodeId) {
      case Some(sym) -> return buildConstructCall(env, e, ty, sym, sig, args)
      case None -> ()
    }
    case None -> ()
  }
  match mapGet(tbl.methodCallByNode, e.nodeId) {
    case Some(site) -> match mapGet(tbl.calleeByNode, e.nodeId) {
      case Some(sym) -> return buildMethodCall(env, e, ty, sym, site, fn, args)
      case None -> ()
    }
    case None -> ()
  }
  match mapGet(tbl.externByNode, e.nodeId) {
    case Some(site) -> return buildExternCall(env, e, ty, site, fn, args)
    case None -> ()
  }
  if tbl.calleeByNode.containsKey(e.nodeId) {
    return uncoveredExpr(env, e, "a method, constructor or member call")
  }
  match buildRecordCopy(env, e, ty, fn, args) {
    case Some(r) -> return r
    case None -> ()
  }
  match buildUnderlyingConversion(env, e, ty, fn, args) {
    case Some(r) -> return r
    case None -> ()
  }
  match buildDistinctFactory(env, e, ty, fn, args) {
    case Some(r) -> return r
    case None -> ()
  }
  uncoveredExpr(env, e, "a call the checker did not resolve")
}

/// A numeric conversion method (`x.toInt()`, `x.toLong()`) on a range-subtype or distinct
/// value: the checker types the call at the primitive and records no callee. The value is
/// unwrapped to its underlying type (`CvUnrefine`, `CvUnwrapDistinct`), then widened to
/// the call's type when that differs. None when the call is not such a conversion;
/// Some(None) after a part could not be built.
func buildUnderlyingConversion(
  env: in BuildEnv, e: in Expr, ty: in Ty, fn: in Expr, args: in List[CallArg]
): Option[Option[TExpr]] {
  if args.count != 0 {
    return None
  }
  val recvE = match fn.kind {
    case EMember(r, m) -> if m == "toByte" or m == "toInt" or m == "toLong" or m == "toChar" or m == "toDouble" or m == "toFloat" or m == "toNat" {
      r
    } else {
      return None
    }
    case _ -> return None
  }
  val rt = match mapGet(env.ctx.tbl.exprTypes, recvE.nodeId) { case Some(t) -> t; case None -> return None }
  val isRefined = match rt { case TyRefined(_, _, _, _, _) -> true; case _ -> false }
  val isDistinct = match rt {
    case TyUser(id, _, _) -> match symbolOfDefId(env.ctx.tbl, id) {
      case Some(sym) -> match sym.kind {
        case DKDistinctType(_, _) -> true
        case _ -> false
      }
      case None -> false
    }
    case _ -> false
  }
  if not isRefined and not isDistinct {
    return None
  }
  val recv = match buildExpr(env, recvE) { case Some(t) -> t; case None -> return Some(value = None) }
  val unwrapped: TExpr = match recv.ty {
    case TRefined(u, _, _, _) -> TExpr(
      id = freshNodeId(env),
      ty = u,
      span = recv.span,
      kind = XConvert(kind = CvUnrefine, inner = recv)
    )
    case TNamed(did, targs) -> {
      if targs.count != 0 {
        return Some(value = uncoveredExpr(env, e, "a conversion method on a generic distinct value"))
      }
      val under = match symbolOfDefId(env.ctx.tbl, did) {
        case Some(sym) -> match distinctUnderlyingOf(env.ctx.tbl, TyUser(id = did, name = sym.name, args = newList())) {
          case Some(u) -> u
          case None -> return Some(value = uncoveredExpr(env, e, "a conversion method on a distinct value with no underlying type"))
        }
        case None -> return Some(value = None)
      }
      val uty = match tyOfType(env.ctx, under) {
        case Ok(t) -> t
        case Err(msg) -> {
          env.errors.add(msg)
          return Some(value = None)
        }
      }
      TExpr(
        id = freshNodeId(env),
        ty = uty,
        span = recv.span,
        kind = XConvert(kind = CvUnwrapDistinct(sym = did), inner = recv)
      )
    }
    case _ -> return None
  }
  Some(value = convertValueAs(env, e, unwrapped, ty))
}

/// `t` as a value of `ty` for the call `e`, or the counted reason it cannot be.
func convertValueAs(env: in BuildEnv, e: in Expr, t: in TExpr, ty: in Ty): Option[TExpr] {
  match convertValue(env, t, ty) {
    case Some(c) -> Some(value = c)
    case None -> uncoveredExpr(env, e, "a conversion method whose result differs from the underlying type")
  }
}

/// `r.copy(f = x, ...)` on a record, which the checker validates as a copy site and
/// records no callee for: the receiver built once, then each named field converted to
/// its type at the receiver's instantiation.  None when the call is not a record copy;
/// Some(None) after a part could not be built (counted or reported there).
func buildRecordCopy(
  env: in BuildEnv, e: in Expr, ty: in Ty, fn: in Expr, args: in List[CallArg]
): Option[Option[TExpr]] {
  val recv = match fn.kind { case EMember(r, m) -> if m == "copy" { r } else { return None }; case _ -> return None }
  if not env.ctx.tbl.recordCopySites.containsKey(recordCopySiteKey(e.span)) {
    return None
  }
  val cty = match mapGet(env.ctx.tbl.exprTypes, recv.nodeId) { case Some(t) -> t; case None -> return None }
  val rid = match cty { case TyUser(id, _, _) -> id; case _ -> return None }
  val targs = match cty { case TyUser(_, _, a) -> a; case _ -> return None }
  val fields = fieldsOfRecordInstantiated(env.ctx.tbl, rid, targs)
  val base = match buildExpr(env, recv) { case Some(t) -> t; case None -> return Some(value = None) }
  val updates: List[TFieldUpdate] = newList()
  for a in args {
    match a {
      case CAPositional(_) -> return Some(value = uncoveredExpr(env, e, "a record copy with a positional argument"))
      case CANamed(name, value, _) -> {
        var idx = -1
        var i = 0
        while i < fields.count {
          if fields[i].name == name {
            idx = i
          }
          i = i + 1
        }
        if idx < 0 {
          return Some(value = uncoveredExpr(env, e, "a record copy naming no field"))
        }
        val fty = match tyOfType(env.ctx, fields[idx].ty) {
          case Ok(t) -> t
          case Err(msg) -> {
            env.errors.add(msg)
            return Some(value = None)
          }
        }
        val bv = match settleArg(env, value, fty) { case Some(t) -> t; case None -> return Some(value = None) }
        val cv = match coerceArg(env, bv, fty) { case Some(t) -> t; case None -> return Some(value = None) }
        updates.add(TFieldUpdate(field = FieldRef(owner = rid, name = name, index = idx), value = cv))
      }
    }
  }
  Some(value = Some(value = mkExpr(e, ty, XCopy(base = base, updates = updates))))
}

/// `T.from(x)` and `T.tryFrom(x)` on a non-generic distinct type `T` (language reference
/// 2.3), which the checker types without recording a callee.  The call's own type names
/// `T` (`from`) or `Result[T, String]` (`tryFrom`).  The argument is converted to `T`'s
/// underlying type; `from` is then a `CvWrapDistinct` node and `tryFrom` an `IoTryFrom`
/// intrinsic.  None when the call is not such a factory (the caller counts it); a
/// factory the builder cannot finish is reported inside and yields Some(None).
func buildDistinctFactory(
  env: in BuildEnv, e: in Expr, ty: in Ty, fn: in Expr, args: in List[CallArg]
): Option[Option[TExpr]] {
  val mname = match fn.kind {
    case EMember(recv, m) -> if m == "from" or m == "tryFrom" {
      match recv.kind {
        case EPath(path) -> if path.segments.count == 1 { m } else { return None }
        case _ -> return None
      }
    } else {
      return None
    }
    case _ -> return None
  }
  val target = if mname == "from" {
    ty
  } else {
    match ty {
      case TNamed(_, rargs) -> if rargs.count == 2 { rargs[0] } else { return None }
      case _ -> return None
    }
  }
  val tbl = env.ctx.tbl
  var distinctId: Option[SymbolId] = None
  val uty = match target {
    case TRefined(u, _, _, _) -> u
    case TNamed(did, targs) -> {
      if targs.count != 0 {
        return None
      }
      val under = match symbolOfDefId(tbl, did) {
        case Some(sym) -> match sym.kind {
          case DKDistinctType(_, _) -> match distinctUnderlyingOf(tbl, TyUser(id = did, name = sym.name, args = newList())) {
            case Some(u) -> u
            case None -> return None
          }
          case _ -> return None
        }
        case None -> return None
      }
      distinctId = Some(value = did)
      match tyOfType(env.ctx, under) {
        case Ok(t) -> t
        case Err(msg) -> {
          env.errors.add(msg)
          return Some(value = None)
        }
      }
    }
    case _ -> return None
  }
  val xs = match positionalArgs(args) {
    case Some(v) -> v
    case None -> return Some(value = uncoveredExpr(env, e, "a distinct factory with a named argument"))
  }
  if xs.count != 1 {
    return None
  }
  val built = match buildExpr(env, xs[0]) { case Some(t) -> t; case None -> return Some(value = None) }
  val arg = match coerceArg(env, built, uty) { case Some(c) -> c; case None -> return Some(value = None) }
  if mname == "from" {
    return Some(
      value = match distinctId {
        case Some(did) -> Some(
          value = mkExpr(e, ty, XConvert(kind = CvWrapDistinct(sym = did), inner = arg))
        )
        case None -> convertValue(env, arg, ty)
      }
    )
  }
  val one: List[TArg] = newList()
  one.add(TArgIn(value = arg))
  Some(value = Some(value = mkExpr(e, ty, XCall(callee = Intrinsic(op = IoTryFrom), args = one))))
}

/// A host element as a `Ty`: the receiver's type argument, a Lyric primitive, or a
/// host type.  `hint` is the type of the argument (or the call) the element is matched
/// with: a host class the hint already names keeps the hint's own name, and a host
/// string takes Lyric's `String` when the hint is one.
func hostElemTy(elem: in ExternIterElem, targs: in List[Ty], hint: in Ty): Option[Ty] {
  match elem {
    case EIEArg(i) -> if i >= 0 and i < targs.count { Some(value = targs[i]) } else { None }
    case EIEPrim(name) -> match primFromString(name) { case Some(p) -> Some(value = primOf(p)); case None -> None }
    case EIEHost(h, hargs) -> {
      if h == "System.Char" {
        return Some(value = TPrim(kind = TPChar))
      }
      if h == "System.String" or h == "java.lang.String" {
        match hint {
          case TPrim(TPString) -> return Some(value = hint)
          case _ -> ()
        }
      }
      match hint {
        case TExtern(r) -> if externHostBase(r.name) == h { return Some(value = hint) }
        case _ -> ()
      }
      val conv: List[Ty] = newList()
      for a in hargs {
        match hostElemTy(a, targs, TirT.TNever) {
          case Some(t) -> conv.add(t)
          case None -> return None
        }
      }
      Some(value = TExtern(host = HostTypeRef(name = h, args = conv)))
    }
  }
}

/// A host result the checker types as a Lyric type without checking it (D359): an array as
/// a slice, a possibly null string as `String?`, a host enum as `Int`, the host's 32-bit and
/// 64-bit floating point types as `Float` and `Double`, a host task as the built-in `Task[T]`.
/// The call then has the host type and a `CvFromHost` conversion to the checker's type.
pub func hostResultIsCallType(host: in Ty, callTy: in Ty): Bool {
  match host {
    case TExtern(h) -> {
      val n = h.name
      match callTy {
        case TSlice(_) -> n == "an array, pointer or by-reference type"
        case TArray(_, _) -> n == "an array, pointer or by-reference type"
        case TNullable(inner) -> match inner {
          case TPrim(TPString) -> n == "System.String" or n == "java.lang.String"
          case _ -> false
        }
        case TPrim(TPFloat) -> n == "System.Single" or n == "java.lang.Float"
        case TPrim(TPDouble) -> n == "System.Double" or n == "java.lang.Double"
        case TPrim(TPInt) -> n != "an array, pointer or by-reference type" and n != "System.String" and
          n != "java.lang.String"
        case TNamed(sym, targs) -> isBuiltinSymbol(sym) and targs.count == 1 and h.args.count == 1 and
          (tyEq(h.args[0], targs[0]) or hostResultIsCallType(h.args[0], targs[0])) and
          (
            n == "System.Threading.Tasks.Task" or n == "java.util.concurrent.CompletableFuture" or
              n == "java.util.concurrent.Future"
          )
        case _ -> false
      }
    }
    case _ -> false
  }
}

/// An overload that fits the argument types: its parameters and how well.
record OverloadFit {
  params: List[Ty]
  score: Int
}

/// The parameters of one overload as `Ty`s matched against the argument types, with
/// the score of the match (2 per exact argument, 1 per widened one), or None when
/// an argument does not fit.
func scoreOverload(sig: in ExternMemberSig, targs: in List[Ty], argTys: in List[Ty]): Option[OverloadFit] {
  val ps: List[Ty] = newList()
  var score = 0
  var i = 0
  while i < sig.params.count {
    val p = match hostElemTy(sig.params[i], targs, argTys[i]) { case Some(t) -> t; case None -> return None }
    if tyEq(p, argTys[i]) {
      score = score + 2
    } else {
      match widenKind(argTys[i], p) {
        case Some(_) -> {
          score = score + 1
        }
        case None -> return None
      }
    }
    ps.add(p)
    i = i + 1
  }
  Some(value = OverloadFit(params = ps, score = score))
}

/// A call to a member of a host type (`ExternCallSite`): the overload the argument
/// types select among the candidates the bridge read from the host's metadata, as a
/// `HostMemberRef`.  An instance member takes its receiver as the first argument and
/// first parameter.  Named arguments, an ambiguous or missing overload and a host
/// type the metadata cannot say are counted.
func buildExternCall(
  env: in BuildEnv,
  e: in Expr,
  ty: in Ty,
  site: in ExternCallSite,
  fn: in Expr,
  args: in List[CallArg],
): Option[TExpr] {
  val tbl = env.ctx.tbl
  if tbl.externIterResolver.count == 0 {
    return uncoveredExpr(env, e, "an extern call with no host metadata")
  }
  val recvExpr = match fn.kind {
    case EMember(r, _) -> r
    case _ -> return uncoveredExpr(env, e, "an extern call whose callee is not a member access")
  }
  val targs: List[Ty] = newList()
  for t in site.targs {
    match tyOfType(env.ctx, t) {
      case Ok(x) -> targs.add(x)
      case Err(msg) -> {
        env.errors.add(msg)
        return None
      }
    }
  }
  val built: List[TExpr] = newList()
  for a in args {
    match a {
      case CAPositional(x) -> match buildExpr(env, x) { case Some(t) -> built.add(t); case None -> return None }
      case CANamed(_, _, _) -> return uncoveredExpr(env, e, "an extern call with a named argument")
    }
  }
  val argTys: List[Ty] = newList()
  for b in built {
    argTys.add(b.ty)
  }
  val cands = match tbl.externIterResolver[0].resolveMemberSigs(site.hostType, site.name, site.argCount, false) {
    case Some(c) -> c
    case None -> return uncoveredExpr(env, e, "an extern call the host metadata cannot resolve")
  }
  var bestSig: Option[ExternMemberSig] = None
  var bestParams: List[Ty] = newList()
  var bestScore = -1
  var ambiguous = false
  for c in cands {
    if c.params.count == argTys.count {
      match scoreOverload(c, targs, argTys) {
        case Some(fit) -> {
          val ps = fit.params
          val sc = fit.score
          if sc > bestScore {
            bestScore = sc
            bestSig = Some(value = c)
            bestParams = ps
            ambiguous = false
          } else if sc == bestScore {
            var same = bestParams.count == ps.count
            var k = 0
            while same and k < ps.count {
              if not tyEq(bestParams[k], ps[k]) {
                same = false
              }
              k = k + 1
            }
            match bestSig {
              case Some(b) -> if b.isStatic != c.isStatic { same = false }
              case None -> ()
            }
            if not same {
              ambiguous = true
            }
          }
        }
        case None -> ()
      }
    }
  }
  val sig = match bestSig {
    case Some(c) -> c
    case None -> return uncoveredExpr(env, e, "an extern call no host overload fits")
  }
  if ambiguous {
    return uncoveredExpr(env, e, "an extern call with ambiguous host overloads")
  }
  val isCtor = site.name == "new"
  val ret = if isCtor {
    ty
  } else {
    match sig.ret {
      case EMTVoid -> tyUnit()
      case EMTType(el) -> match hostElemTy(el, targs, ty) {
        case Some(t) -> t
        case None -> return uncoveredExpr(env, e, "an extern call with a host result the builder cannot type")
      }
    }
  }
  val owner = HostTypeRef(name = site.hostType, args = targs)
  val params: List[TParamTy] = newList()
  val targsOut: List[TArg] = newList()
  if not sig.isStatic {
    val rt = match buildExpr(env, recvExpr) { case Some(t) -> t; case None -> return None }
    val want = TExtern(host = owner)
    if not tyEq(rt.ty, want) {
      return uncoveredExpr(env, e, "an extern call on a receiver that is not the host type itself")
    }
    params.add(TParamTy(mode = TMIn, ty = want))
    targsOut.add(TArgIn(value = rt))
  }
  var i = 0
  while i < built.count {
    val want = bestParams[i]
    params.add(TParamTy(mode = TMIn, ty = want))
    val c = match coerceArg(env, built[i], want) { case Some(x) -> x; case None -> return None }
    targsOut.add(TArgIn(value = c))
    i = i + 1
  }
  val member = HostMemberRef(
    owner = owner,
    name = site.name,
    kind = if isCtor { HMConstructor } else { HMMethod },
    isStatic = sig.isStatic,
    params = params,
    ret = ret
  )
  // A host string can be null: the checker types the call `String?`, the host's result is the String.
  val nullableString = match ty {
    case TNullable(TPrim(TPString)) -> tyEq(ret, TPrim(kind = TPString))
    case _ -> false
  }
  if nullableString {
    val call = TExpr(
      id = freshNodeId(env),
      ty = ret,
      span = e.span,
      kind = XCall(callee = Extern(member = member), args = targsOut)
    )
    return Some(value = mkExpr(e, ty, XConvert(kind = CvLiftNullable, inner = call)))
  }
  if hostResultIsCallType(ret, ty) {
    val call = TExpr(
      id = freshNodeId(env),
      ty = ret,
      span = e.span,
      kind = XCall(callee = Extern(member = member), args = targsOut)
    )
    return Some(value = mkExpr(e, ty, XConvert(kind = CvFromHost, inner = call)))
  }
  Some(value = mkExpr(e, ty, XCall(callee = Extern(member = member), args = targsOut)))
}

/// The field `name` of the record type `ty` declares, by its position among the record's
/// declared fields (the order a construction places them in).  `fieldsOfRecord` is empty
/// for a declared type that is not a record (a union, an enum, a distinct type), so such a
/// type has no field here.
func fieldRefOf(env: in BuildEnv, ty: in Ty, name: in String): Option[FieldRef] {
  match ty {
    case TNamed(sym, _) -> {
      val fields = fieldsOfRecord(env.ctx.tbl, sym)
      var i = 0
      while i < fields.count {
        if fields[i].name == name {
          return Some(value = FieldRef(owner = sym, name = name, index = i))
        }
        i = i + 1
      }
      protectedFieldRef(env.ctx.tbl, ty, name)
    }
    case _ -> None
  }
}

/// `recv.name` where `recv` is a value of a record type declaring a field `name`: the
/// receiver built, then the field.  Any other member (a collection's `count`, a host
/// property, a config field, a tuple or union payload) is counted.
func buildFieldRead(env: in BuildEnv, e: in Expr, ty: in Ty, recv: in Expr, name: in String): Option[TExpr] {
  val rt = match buildExpr(env, recv) { case Some(t) -> t; case None -> return None }
  match fieldRefOf(env, rt.ty, name) {
    case Some(f) -> Some(value = mkExpr(e, ty, XField(recv = rt, field = f)))
    case None -> match builtinPropertyName(env, recv, name) {
      case Some(bn) -> Some(
        value = mkExpr(
          e,
          ty,
          XCall(
            callee = Intrinsic(op = IoBuiltin(name = bn)),
            args = inArgs(singleTExpr(rt))
          )
        )
      )
      case None -> uncoveredExpr(env, e, "a member access that is not a record field")
    }
  }
}

func singleTExpr(t: in TExpr): List[TExpr] {
  val xs: List[TExpr] = newList()
  xs.add(t)
  xs
}

/// The built-in a property read names: a stdlib collection's `count` and a string's
/// `length`, as the checker names the built-in members (`List.count`).  A user type
/// that happens to be named `List` is not the stdlib's.
func builtinPropertyName(env: in BuildEnv, recv: in Expr, name: in String): Option[String] {
  val rty = match mapGet(env.ctx.tbl.exprTypes, recv.nodeId) { case Some(t) -> t; case None -> return None }
  match rty {
    case TyPrim(PtString) -> if name == "length" { return Some(value = "String.length") }
    case TySlice(_) -> if name == "length" { return Some(value = "slice.length") }
    case TyArray(_, _, _) -> if name == "length" { return Some(value = "array.length") }
    case TyException -> if name == "message" { return Some(value = "Exception.message") }
    case TyUser(id, hd, _) -> if name == "length" and symbolIdEq(id, builtinBufferTypeId()) {
      return Some(value = "buffer.length")
    } else if name == "count" and (hd == "List" or hd == "Map" or hd == "Set") {
      val stdlib = match symTableTypeSymbolOf(env.ctx.tbl, id) {
        case Some(ts) -> ts.originPackage.startsWith("Std.")
        case None -> false
      }
      if stdlib {
        return Some(value = hd + ".count")
      }
    }
    case _ -> ()
  }
  None
}

/// How `recv[idx]` is performed, from the receiver's type: arrays, slices and strings by
/// their type, the stdlib `List` and `Map` by the name the checker typed the receiver
/// with (their host types differ per target).  A record's `index` method and a host
/// indexer are not derived here.
func indexKindOf(env: in BuildEnv, recvExpr: in Expr, rt: in TExpr): Option[TirT.IndexKind] {
  match rt.ty {
    case TArray(_, _) -> return Some(value = IkArray)
    case TSlice(_) -> return Some(value = IkSlice)
    case TPrim(TPString) -> return Some(value = IkString)
    case TNamed(s, targs) -> if targs.count == 1 and symbolIdEq(s, builtinBufferTypeId()) {
      return Some(value = IkBuffer)
    }
    case _ -> ()
  }
  match mapGet(env.ctx.tbl.exprTypes, recvExpr.nodeId) {
    case Some(TyUser(id, name, _)) -> {
      // A user type that happens to be named `List` or `Map` is not the stdlib's.
      val stdlib = match symTableTypeSymbolOf(env.ctx.tbl, id) {
        case Some(ts) -> ts.originPackage == "Std.CollectionsHost"
        case None -> false
      }
      if stdlib and name == "List" {
        return Some(value = IkList)
      }
      if stdlib and name == "Map" {
        return Some(value = IkMap)
      }
      None
    }
    case _ -> None
  }
}

/// The type an index of kind `how` takes on a receiver of type `recv`: `Int` for
/// sequences, the key type for a map.
func indexKeyTy(how: in TirT.IndexKind, recv: in Ty): Option[Ty] {
  match how {
    case IkMap -> match recv {
      case TExtern(h) -> if h.args.count == 2 { Some(value = h.args[0]) } else { None }
      case TNamed(_, targs) -> if targs.count == 2 { Some(value = targs[0]) } else { None }
      case _ -> None
    }
    case IkMethod(_) -> None
    case IkHost(_) -> None
    case _ -> Some(value = tyInt())
  }
}

/// The receiver and index of `recv[idx]`, built and converted: a single index only.
func buildIndexParts(env: in BuildEnv, e: in Expr, recv: in Expr, idxs: in List[Expr]): Option[IndexParts] {
  if idxs.count != 1 {
    val _ = uncoveredExpr(env, e, "an index with several indices")
    return None
  }
  val rt = match buildExpr(env, recv) { case Some(t) -> t; case None -> return None }
  val how = match indexKindOf(env, recv, rt) {
    case Some(h) -> h
    case None -> {
      val _ = uncoveredExpr(env, e, "an index on a receiver that is not an array, slice, string, List or Map")
      return None
    }
  }
  val it = match buildExpr(env, idxs[0]) { case Some(t) -> t; case None -> return None }
  val keyTy = match indexKeyTy(how, rt.ty) {
    case Some(k) -> k
    case None -> {
      val _ = uncoveredExpr(env, e, "an index with an unknown key type")
      return None
    }
  }
  val idx = match coerceArg(env, it, keyTy) { case Some(c) -> c; case None -> return None }
  Some(value = IndexParts(recv = rt, idx = idx, how = how))
}

record IndexParts {
  recv: TExpr
  idx: TExpr
  how: TirT.IndexKind
}

func buildIndexRead(env: in BuildEnv, e: in Expr, ty: in Ty, recv: in Expr, idxs: in List[Expr]): Option[TExpr] {
  match buildIndexParts(env, e, recv, idxs) {
    case Some(p) -> Some(value = mkExpr(e, ty, XIndex(recv = p.recv, idx = p.idx, how = p.how)))
    case None -> None
  }
}

/// A lambda: its parameters take the types of the function type the checker gave it, its
/// body is built with the parameters in scope and converted to the result type, and its
/// captures are the outer locals the body used.
func buildLambda(
  env: in BuildEnv, e: in Expr, ty: in Ty, params: in List[Px.LambdaParam], body: in Block
): Option[TExpr] {
  val sig = match ty {
    case TFunc(ps, r, _) -> if ps.count == params.count {
      Some(value = LambdaSig(params = ps, ret = r))
    } else {
      None
    }
    case _ -> None
  }
  val ls = match sig {
    case Some(x) -> x
    case None -> return uncoveredExpr(env, e, "a lambda whose type has other parameters")
  }
  pushScope(env)
  val frame = LambdaFrame(start = env.nextLocal[0], caps = newList())
  env.lambdas.add(frame)
  val decls: List[LocalDecl] = newList()
  var i = 0
  while i < params.count {
    decls.add(declareLocal(env, params[i].name, ls.params[i].ty, false))
    i = i + 1
  }
  // The checker leaves a bare `None` or `[]` at a lambda's tail untyped; it takes the
  // lambda's return type, as an argument hole takes its parameter's.
  settleBlockTail(env, body, ls.ret)
  val built = buildBlock(env, body, None, freshNodeId(env))
  env.lambdas.removeAt(env.lambdas.count - 1)
  popScope(env)
  val b = match built { case Some(x) -> x; case None -> return None }
  val conv = match coerceBranch(env, b, ls.ret) { case Some(c) -> c; case None -> return None }
  Some(value = mkExpr(e, ty, XLambda(params = decls, captures = frame.caps, body = conv)))
}

record LambdaSig {
  params: List[TParamTy]
  ret: Ty
}

/// The place an assignment writes: a local, a record field or an element.  An assignment
/// to a global, or through `self` or a host member, is counted.
func buildPlace(env: in BuildEnv, target: in Expr): Option[TPlace] {
  val pty = match exprTy(env.ctx, target.nodeId) {
    case Ok(t) -> t
    case Err(msg) -> {
      env.errors.add(msg)
      return None
    }
  }
  match target.kind {
    case EParen(inner) -> buildPlace(env, inner)
    case EPath(p) -> {
      if p.segments.count == 1 {
        match lookupLocal(env, p.segments[0]) {
          case Some(d) -> {
            if d.id.id < 0 {
              return None
            }
            return Some(value = TPlace(ty = d.ty, kind = PlLocal(local = d.id)))
          }
          case None -> ()
        }
      }
      if p.segments.count == 1 {
        match bareSelfField(env, target, p.segments[0]) {
          case Some(bf) -> return Some(value = TPlace(ty = pty, kind = PlField(recv = bf.recv, field = bf.field)))
          case None -> ()
        }
      }
      val _ = uncoveredExpr(env, target, "an assignment to a name that is not a local")
      None
    }
    case EMember(r, name) -> {
      val rt = match buildExpr(env, r) { case Some(t) -> t; case None -> return None }
      match fieldRefOf(env, rt.ty, name) {
        case Some(f) -> Some(value = TPlace(ty = pty, kind = PlField(recv = rt, field = f)))
        case None -> {
          val _ = uncoveredExpr(env, target, "an assignment to a member that is not a record field")
          None
        }
      }
    }
    case EIndex(r, idxs) -> match buildIndexParts(env, target, r, idxs) {
      case Some(p) -> Some(
        value = TPlace(
          ty = pty,
          kind = PlIndex(recv = p.recv, idx = p.idx, how = p.how)
        )
      )
      case None -> None
    }
    case _ -> {
      val _ = uncoveredExpr(env, target, "an assignment target that is not a local, field or element")
      None
    }
  }
}

func assignKindOf(op: in AssignOp): AssignKind {
  match op {
    case AssEq -> AkSet
    case AssPlus -> AkAdd
    case AssMinus -> AkSub
    case AssStar -> AkMul
    case AssSlash -> AkDiv
    case AssPercent -> AkMod
  }
}

/// `target op= value`: the place and the value converted to the place's type.  The
/// result is a `Unit` node (`XAssign`).
func buildAssign(env: in BuildEnv, e: in Expr, target: in Expr, op: in AssignOp, value: in Expr): Option[TExpr] {
  val place = match buildPlace(env, target) { case Some(p) -> p; case None -> return None }
  val vt = match buildExpr(env, value) { case Some(t) -> t; case None -> return None }
  val v = match coerceArg(env, vt, place.ty) { case Some(c) -> c; case None -> return None }
  Some(value = mkExpr(e, tyUnit(), XAssign(place = place, op = assignKindOf(op), value = v)))
}

/// The implicit conversion that takes a value of type `from` to `to`, derived from the
/// two types alone: numeric widening, `Never` used as a value, `T` used as `T?`, a value
/// of a refinement's underlying type checked into the refinement, and a refined value
/// used as its underlying type.  None for any other pair: a distinct wrap, an interface
/// upcast, a host boxing or a slice/list conversion needs the declaration, not the
/// types, and stays counted.
pub func convKindOf(from: in Ty, to: in Ty): Option[ConvKind] {
  match widenKind(from, to) {
    case Some(k) -> return Some(value = k)
    case None -> ()
  }
  match from {
    case TNever -> return Some(value = CvFromNever)
    case _ -> ()
  }
  match to {
    case TNullable(inner) -> if tyEq(from, inner) { return Some(value = CvLiftNullable) }
    case TRefined(u, _, _, _) -> if tyEq(from, u) { return Some(value = CvRangeCheck) }
    case _ -> ()
  }
  match from {
    case TRefined(u, _, _, _) -> if tyEq(u, to) { return Some(value = CvUnrefine) }
    case _ -> ()
  }
  None
}

func convertNode(env: in BuildEnv, t: in TExpr, to: in Ty, k: in ConvKind): TExpr {
  TExpr(id = freshNodeId(env), ty = to, span = t.span, kind = XConvert(kind = k, inner = t))
}

/// `t` as a value of type `ty`: as is, converted by a node of its own, or not at all
/// (None, uncounted), never converted by guessing.
func convertValue(env: in BuildEnv, t: in TExpr, ty: in Ty): Option[TExpr] {
  if tyEq(t.ty, ty) {
    return Some(value = t)
  }
  match convKindOf(t.ty, ty) {
    case Some(k) -> Some(value = convertNode(env, t, ty, k))
    case None -> match upcastKind(env, t.ty, ty) {
      case Some(k) -> Some(value = convertNode(env, t, ty, k))
      case None -> None
    }
  }
}

/// A value of a declared type used where an interface is expected: the checker accepts
/// that only for a type that implements it, so the node names the interface.
func upcastKind(env: in BuildEnv, from: in Ty, to: in Ty): Option[ConvKind] {
  val iface = match to { case TNamed(i, _) -> i; case _ -> return None }
  val src = match from { case TNamed(a, _) -> a; case _ -> return None }
  if src.id == iface.id {
    return None
  }
  val tbl = env.ctx.tbl
  val targetIsInterface = match symbolOfDefId(tbl, iface) {
    case Some(s) -> match s.kind { case DKInterface(_, _) -> true; case _ -> false }
    case None -> false
  }
  val sourceIsInterface = match symbolOfDefId(tbl, src) {
    case Some(s) -> match s.kind { case DKInterface(_, _) -> true; case _ -> false }
    case None -> true
  }
  if targetIsInterface and not sourceIsInterface {
    Some(value = CvUpcast(iface = iface))
  } else {
    None
  }
}

/// An argument as the parameter `pty` takes it: as is, converted by a node of its own,
/// or not at all (counted), never converted by guessing.
func coerceArg(env: in BuildEnv, t: in TExpr, pty: in Ty): Option[TExpr] {
  match convertValue(env, t, pty) {
    case Some(c) -> Some(value = c)
    case None -> {
      noteUncovered(env, "an argument conversion")
      None
    }
  }
}

/// Whether `t` is a block with no tail value whose last statement always leaves it.
func blockNeverCompletes(t: in TExpr): Bool {
  match t.kind {
    case XBlock(stmts, None) -> {
      if stmts.count == 0 {
        return false
      }
      match stmts[stmts.count - 1].kind {
        case TsReturn(_) -> true
        case TsThrow(_) -> true
        case TsScope(_, body) -> blockNeverCompletes(body)
        case _ -> false
      }
    }
    case _ -> false
  }
}

/// A branch of an `if` or `match` as the whole takes it: as is, widened by a node of
/// its own, or not at all (counted).  A branch that never completes fits any type.
func coerceBranch(env: in BuildEnv, t: in TExpr, ty: in Ty): Option[TExpr] {
  // A block with no tail whose last statement always leaves it (`return`, `throw`, or a
  // `scope` that ends in one) never completes, so it fits any type.
  if blockNeverCompletes(t) {
    return Some(value = TExpr(id = t.id, ty = ty, span = t.span, kind = t.kind))
  }
  // A block is typed as the whole, but its tail keeps its own type, which is
  // the value that needs converting.
  match t.kind {
    case XBlock(stmts, Some(tail)) -> match coerceBranch(env, tail, ty) {
      case Some(nt) -> return Some(value = TExpr(id = t.id, ty = ty, span = t.span, kind = XBlock(stmts = stmts, tail = Some(value = nt))))
      case None -> return None
    }
    case _ -> ()
  }
  if tyEq(t.ty, ty) {
    return Some(value = t)
  }
  match t.ty {
    case TNever -> return Some(value = t)
    case _ -> ()
  }
  match convKindOf(t.ty, ty) {
    case Some(k) -> Some(value = convertNode(env, t, ty, k))
    case None -> {
      noteUncovered(env, "a branch conversion")
      env.errors.add(
        "I0002: the builder has no case for a branch conversion at " + toString(t.span.startPos.line) + ":" +
          toString(t.span.startPos.column)
      )
      None
    }
  }
}

/// The built-ins whose parameter is any `T`: no argument converts.
func genericBuiltin(name: in String): Bool {
  name == "println" or name == "print" or name == "toString" or name == "hashCode"
}

/// A primitive an implicit widening can change, or a refined number an unrefinement or
/// widening is owed for: an argument the builder cannot check against an unknown
/// parameter type.
func isWidenablePrim(t: in Ty): Bool {
  match t {
    case TPrim(p) -> match p {
      case TPByte -> true
      case TPInt -> true
      case TPUInt -> true
      case TPFloat -> true
      case _ -> false
    }
    case TRefined(_, _, _, _) -> true
    case _ -> false
  }
}

/// The parameter types of the element-taking members of `List`, `Map` and `Set` and of
/// the `slice` members, from the receiver's type arguments (docs/01 member table).
/// The stdlib collections are host types (`TExtern`) to the type conversion, a declared
/// generic is a `TNamed`; both carry the arguments.  `None` for any other built-in: its
/// parameter types are not derived here.
pub func memberArgTys(recv: in Ty, name: in String, argc: in Int): Option[List[Ty]] {
  match recv {
    case TSlice(elem) -> sliceMemberArgTys(elem, name, argc)
    case TNamed(_, targs) -> collMemberArgTys(targs, name, argc)
    case TExtern(host) -> collMemberArgTys(host.args, name, argc)
    case _ -> None
  }
}

func sliceMemberArgTys(elem: in Ty, name: in String, argc: in Int): Option[List[Ty]] {
  val res: List[Ty] = newList()
  if name == "slice.append" and argc == 1 {
    res.add(elem)
    return Some(value = res)
  }
  if name == "slice.concat" and argc == 1 {
    res.add(TSlice(element = elem))
    return Some(value = res)
  }
  if name == "slice.slice" and argc == 2 {
    res.add(tyInt())
    res.add(tyInt())
    return Some(value = res)
  }
  None
}

func collMemberArgTys(targs: in List[Ty], name: in String, argc: in Int): Option[List[Ty]] {
  val res: List[Ty] = newList()
  if name.startsWith("List.") and targs.count == 1 {
    val op = name.substring(5, name.length - 5)
    if op == "add" and argc == 2 {
      res.add(tyInt())
      res.add(targs[0])
      return Some(value = res)
    }
    if argc == 1 and (op == "add" or op == "contains" or op == "indexOf" or op == "lastIndexOf" or op == "remove") {
      res.add(targs[0])
      return Some(value = res)
    }
    if argc == 1 and op == "removeAt" {
      res.add(tyInt())
      return Some(value = res)
    }
  }
  if name.startsWith("Map.") and targs.count == 2 {
    val op = name.substring(4, name.length - 4)
    if op == "add" and argc == 2 {
      res.add(targs[0])
      res.add(targs[1])
      return Some(value = res)
    }
    if argc == 1 and (op == "containsKey" or op == "remove") {
      res.add(targs[0])
      return Some(value = res)
    }
  }
  if name.startsWith("Set.") and targs.count == 1 {
    val op = name.substring(4, name.length - 4)
    if argc == 1 and (op == "add" or op == "contains" or op == "remove") {
      res.add(targs[0])
      return Some(value = res)
    }
  }
  None
}

/// A built-in call.  Its arguments are checked against the parameter types derived for
/// the collection and slice members; a generic built-in (`println`) converts nothing; any
/// other built-in given an argument an implicit widening could change is counted, since
/// its parameter types are not known here.
func buildBuiltinCall(
  env: in BuildEnv, e: in Expr, ty: in Ty, name: in String, fn: in Expr, args: in List[CallArg]
): Option[TExpr] {
  match positionalArgs(args) {
    case None -> uncoveredExpr(env, e, "a built-in call with a named argument")
    case Some(xs) -> {
      var recvT: Option[TExpr] = None
      match fn.kind {
        case EMember(recv, _) -> match buildExpr(env, recv) {
          case Some(r) -> {
            recvT = Some(value = r)
          }
          case None -> return None
        }
        case _ -> ()
      }
      match buildAll(env, xs) {
        case None -> None
        case Some(ts) -> {
          val expected: Option[List[Ty]] = match recvT { case Some(r) -> memberArgTys(r.ty, name, ts.count); case None -> None }
          val res: List[TExpr] = newList()
          match recvT {
            case Some(r) -> res.add(r)
            case None -> ()
          }
          match expected {
            case Some(tys) -> {
              var i = 0
              while i < ts.count {
                match coerceArg(env, ts[i], tys[i]) {
                  case Some(c) -> res.add(c)
                  case None -> return uncoveredExpr(env, e, "a built-in call needing a conversion")
                }
                i = i + 1
              }
            }
            case None -> {
              // A member the checker gave a function type (`String.substring`): its
              // parameters, the call's leading ones when it leaves an optional one out.
              var declared: Option[List[TParamTy]] = None
              if not genericBuiltin(name) {
                match mapGet(env.ctx.tbl.builtinFnTyByNode, e.nodeId) {
                  case Some(ft) -> match tyOfType(env.ctx, ft) {
                    case Ok(TFunc(ps, _, _)) -> if ts.count <= ps.count { declared = Some(value = ps) }
                    case _ -> ()
                  }
                  case None -> ()
                }
              }
              match declared {
                case Some(ps) -> {
                  var i = 0
                  while i < ts.count {
                    match coerceArg(env, ts[i], ps[i].ty) {
                      case Some(c) -> res.add(c)
                      case None -> return uncoveredExpr(env, e, "a built-in call needing a conversion")
                    }
                    i = i + 1
                  }
                }
                case None -> {
                  if not genericBuiltin(name) {
                    for t in ts {
                      if isWidenablePrim(t.ty) {
                        return uncoveredExpr(env, e, "a built-in call with an argument the builder cannot check")
                      }
                    }
                  }
                  for t in ts {
                    res.add(t)
                  }
                }
              }
            }
          }
          Some(value = mkExpr(e, ty, XCall(callee = Intrinsic(op = IoBuiltin(name = name)), args = inArgs(res))))
        }
      }
    }
  }
}

/// A call through a function value: the arguments are checked against the function
/// type's parameters.
func buildIndirectCall(env: in BuildEnv, e: in Expr, ty: in Ty, fn: in Expr, args: in List[CallArg]): Option[TExpr] {
  match positionalArgs(args) {
    case None -> uncoveredExpr(env, e, "an indirect call with a named argument")
    case Some(xs) -> {
      val fv = buildExpr(env, fn)
      match buildAll(env, xs) {
        case None -> None
        case Some(ts) -> match fv {
          case None -> None
          case Some(f) -> match f.ty {
            case TFunc(params, _, _) -> {
              if params.count != ts.count {
                return uncoveredExpr(env, e, "an indirect call whose arguments do not match the function type")
              }
              val res: List[TExpr] = newList()
              var i = 0
              while i < ts.count {
                match coerceArg(env, ts[i], params[i].ty) {
                  case Some(c) -> res.add(c)
                  case None -> return uncoveredExpr(env, e, "an indirect call needing a conversion")
                }
                i = i + 1
              }
              Some(value = mkExpr(e, ty, XCall(callee = Indirect(fnValue = f), args = inArgs(res))))
            }
            case _ -> uncoveredExpr(
              env,
              e,
              "a call of a value that is not a function type"
            )
          }
        }
      }
    }
  }
}

/// The index of the parameter `name` of `sig`.
func paramIndex(sig: in ResolvedSignature, name: in String): Option[Int] {
  var i = 0
  while i < sig.params.count {
    if sig.params[i].name == name {
      return Some(value = i)
    }
    i = i + 1
  }
  None
}

/// An argument whose evaluation has no effect and cannot fail, so the order it is
/// evaluated in does not matter.
func isPlainArg(x: in Expr): Bool {
  match x.kind {
    case ELiteral(_) -> true
    case EPath(_) -> true
    case EParen(inner) -> isPlainArg(inner)
    case _ -> false
  }
}

/// The type arguments of a generic call the checker recorded no instantiation for: read
/// back from the argument types it recorded and from the call's result type together,
/// since either alone can leave a parameter out (`andThenResult(Ok(value = 5), f)` has
/// `T` only in an argument and `U` and `E` only in the annotated result).  An argument the
/// checker left untyped fixes nothing.
func genericArgsFromCall(
  env: in BuildEnv, sig: in ResolvedSignature, resultTy: in Type, args: in List[CallArg]
): List[Type] {
  val named: List[String] = newList()
  for a in args {
    match a {
      case CANamed(n, _, _) -> named.add(n)
      case CAPositional(_) -> ()
    }
  }
  val free: List[Int] = newList()
  var pi = 0
  while pi < sig.params.count {
    if not named.contains(sig.params[pi].name) {
      free.add(pi)
    }
    pi = pi + 1
  }
  val ps: List[Type] = newList()
  val ts: List[Type] = newList()
  var pos = 0
  for a in args {
    var slot = -1
    var arg: Option[Expr] = None
    match a {
      case CAPositional(x) -> {
        if pos < free.count {
          slot = free[pos]
        }
        pos = pos + 1
        arg = Some(value = x)
      }
      case CANamed(n, x, _) -> {
        var j = 0
        while j < sig.params.count {
          if sig.params[j].name == n {
            slot = j
          }
          j = j + 1
        }
        arg = Some(value = x)
      }
    }
    match arg {
      case Some(x) -> if slot >= 0 {
        ps.add(sig.params[slot].ty)
        ts.add(match mapGet(env.ctx.tbl.exprTypes, x.nodeId) { case Some(t) -> t; case None -> tyErrorSilent() })
      }
      case None -> ()
    }
  }
  ps.add(sig.returnTy)
  ts.add(resultTy)
  inferGenericArgsDeep(sig.generics, ps, ts)
}

/// A call to a declared non-generic function.  Named arguments take their parameter's
/// slot first and the positional ones fill the free slots in order, as the checker pairs
/// them.  The arguments run in parameter order in TIR, so a call whose source order
/// differs is built only when every argument is plain.
func buildDirectCall(
  env: in BuildEnv,
  e: in Expr,
  ty: in Ty,
  sym: in SymbolId,
  sig: in ResolvedSignature,
  args: in List[CallArg],
): Option[TExpr] {
  var tyArgs: List[Ty] = newList()
  var callSig = sig
  if sig.generics.count > 0 {
    val checkerArgs = match mapGet(env.ctx.tbl.genericArgsByNode, e.nodeId) {
      case Some(ts) -> ts
      case None -> match mapGet(env.ctx.tbl.exprTypes, e.nodeId) {
        case Some(rt) -> genericArgsFromCall(env, sig, rt, args)
        case None -> return uncoveredExpr(env, e, "a generic call with no recorded instantiation")
      }
    }
    if checkerArgs.count != sig.generics.count {
      return uncoveredExpr(env, e, "a generic call whose instantiation does not match the callee")
    }
    for ta in checkerArgs {
      match tyOfType(env.ctx, ta) {
        case Ok(t) -> tyArgs.add(t)
        case Err(msg) -> {
          env.errors.add(msg)
          return None
        }
      }
    }
    val ps: List[ResolvedParam] = newList()
    for p in sig.params {
      ps.add(p.copy(ty = substituteTyParamsOwned(p.ty, sig.generics, sig.genericOwners, checkerArgs)))
    }
    callSig = sig.copy(params = ps)
  }
  val pre: List[TStmt] = newList()
  match buildCallArgs(env, e, callSig, args, pre) {
    case Some(targs) -> {
      noteFuncSym(env, sym, sig, None, None, TSkFunc)
      Some(
        value = withPrelude(env, e, pre, mkExpr(e, ty, XCall(callee = Direct(sym = sym, typeArgs = tyArgs), args = targs)))
      )
    }
    case None -> None
  }
}

/// Whether `t` is a protected type: its members take no declared receiver.
func recvIsProtected(env: in BuildEnv, t: in Type): Bool {
  match t {
    case TyUser(id, _, _) -> match symbolOfDefId(env.ctx.tbl, id) {
      case Some(s) -> match s.kind { case DKProtected(_, _) -> true; case _ -> false }
      case None -> false
    }
    case _ -> false
  }
}

/// A method call `recv.m(args)`: the receiver first, then the arguments placed by
/// parameter, to the method the checker resolved (`Direct`, or `Interface` for an
/// interface-typed receiver).  Only a receiver passed `in` is built; a mutating
/// receiver would be a place argument, and an unknown mode is not guessed.
func buildMethodCall(
  env: in BuildEnv,
  e: in Expr,
  ty: in Ty,
  sym: in SymbolId,
  site: in MethodCallSite,
  fn: in Expr,
  args: in List[CallArg],
): Option[TExpr] {
  val recvExpr = match fn.kind {
    case EMember(r, _) -> r
    case _ -> return uncoveredExpr(env, e, "a method call whose callee is not a member access")
  }
  var isEntry = false
  var isImplMember = false
  match site.sig.recvMode {
    case Some(PMIn) -> ()
    case Some(_) -> return uncoveredExpr(env, e, "a method call with a mutating receiver")
    // An entry or `func` of a protected type declares no receiver: the protected value is
    // the receiver, passed `in` (a reference whose lock the backend takes).
    // An interface method is declared without a receiver too: the value it is called
    // on is the receiver, dispatched on its interface.
    case None -> if recvIsProtected(env, site.recvTy) {
      isEntry = true
    } else if isSome(site.iface) {
      ()
    } else {
      // A member of an `impl Iface for T` block declares no receiver either: `self` is
      // implicit, so the value it is called on is the receiver, passed `in`.
      isImplMember = true
    }
  }
  val declared = match tyOfType(env.ctx, site.recvTy) {
    case Ok(t) -> t
    case Err(msg) -> {
      env.errors.add(msg)
      return None
    }
  }
  val rt = match buildExpr(env, recvExpr) { case Some(t) -> t; case None -> return None }
  val recv = match coerceArg(env, rt, declared) { case Some(c) -> c; case None -> return None }
  val inst = match instantiateMethod(env, e, site, args) { case Some(i) -> i; case None -> return None }
  val pre: List[TStmt] = newList()
  val rest = match buildCallArgs(env, e, inst.sig, args, pre) { case Some(a) -> a; case None -> return None }
  val all: List[TArg] = newList()
  // The receiver is evaluated before any argument: when arguments were hoisted ahead of
  // the call, a receiver that is not a literal or a name is hoisted ahead of them.
  var recvArg = recv
  val stmts: List[TStmt] = newList()
  if pre.count > 0 and not isPlainArg(recvExpr) {
    val d = declareLocal(env, "__recv" + toString(env.nextLocal[0] + 1), recv.ty, false)
    val bindPat = TPat(id = freshNodeId(env), ty = recv.ty, span = recv.span, kind = TpBind(decl = d, inner = None))
    stmts.add(TStmt(id = freshNodeId(env), span = recv.span, kind = TsLet(pat = bindPat, init = recv)))
    recvArg = TExpr(id = freshNodeId(env), ty = recv.ty, span = recv.span, kind = XLocal(local = d.id))
  }
  for st in pre {
    stmts.add(st)
  }
  all.add(TArgIn(value = recvArg))
  for a in rest {
    all.add(a)
  }
  val callee = match site.iface {
    case Some(i) -> Interface(iface = i, ifaceArgs = newList(), method = sym, typeArgs = newList())
    case None -> Direct(sym = sym, typeArgs = inst.tyArgs)
  }
  noteFuncSymN(
    env,
    sym,
    site.sig,
    Some(value = site.recvTy),
    if isEntry or isImplMember or (isSome(site.iface) and not isSome(site.sig.recvMode)) {
      Some(value = PMIn)
    } else {
      site.sig.recvMode
    },
    if isEntry { TSkEntry } else if isSome(site.iface) { TSkInterfaceMethod } else { TSkFunc },
    inst.tyArgs.count
  )
  Some(value = withPrelude(env, e, stmts, mkExpr(e, ty, XCall(callee = callee, args = all))))
}

/// A record or union-case construction: the fields in declaration order, placed and
/// converted as a call's arguments are.  A field left to its default is counted.
func buildConstructCall(
  env: in BuildEnv,
  e: in Expr,
  ty: in Ty,
  sym: in SymbolId,
  sig: in ResolvedSignature,
  args: in List[CallArg],
): Option[TExpr] {
  val pre: List[TStmt] = newList()
  match buildCallArgs(env, e, sig, args, pre) {
    case Some(targs) -> {
      val fields: List[TExpr] = newList()
      for a in targs {
        match a {
          case TArgIn(v) -> fields.add(v)
          case _ -> return uncoveredExpr(env, e, "a construction field passed by reference")
        }
      }
      noteCaseSym(env, sym)
      // A generic record's entry is its declaration's (`typeEntries`), under its own
      // parameters; the instantiated signature here would be the wrong fields.
      val genericRecord = match ty { case TNamed(_, targs) -> targs.count > 0; case _ -> false }
      if not genericRecord {
        noteCtorSym(env, sym, sig)
      }
      Some(value = withPrelude(env, e, pre, mkExpr(e, ty, XConstruct(sym = sym, fields = fields))))
    }
    case None -> None
  }
}

/// Build the argument `x` of a parameter of type `pty`.  An argument the checker typed
/// with a hole (`None`, `[]`) takes the parameter's type, which the call's other
/// arguments have fixed.
func settleArg(env: in BuildEnv, x: in Expr, pty: in Ty): Option[TExpr] {
  if not env.settled.containsKey(x.nodeId) {
    env.settled.add(x.nodeId, pty)
  }
  buildExpr(env, x)
}

/// The argument for a parameter the call leaves out: its declared default, placed at
/// the call under a fresh node id (the declaration's own node stays the parameter's).
/// A literal or a name the checker resolved to a declaration (a constant, `None`);
/// any other default, and one from a restored package, has no case yet.
func buildDefaultArg(env: in BuildEnv, call: in Expr, p: in ResolvedParam): Option[TExpr] {
  val d = match p.dfltExpr { case Some(x) -> x; case None -> return uncoveredExpr(env, call, "a defaulted argument") }
  val pty = match tyOfType(env.ctx, p.ty) { case Ok(t) -> t; case Err(msg) -> { env.errors.add(msg); return None } }
  val ty = match exprTy(env.ctx, d.nodeId) { case Ok(t) -> t; case Err(msg) -> { env.errors.add(msg); return None } }
  val built = match d.kind {
    case ELiteral(_) -> buildExpr(env, d)
    case EPath(_) -> buildRefPath(env, d, ty)
    case _ -> uncoveredExpr(env, call, "a default argument that is not a literal or a name")
  }
  match built {
    case Some(t) -> match coerceArg(env, TExpr(id = freshNodeId(env), ty = t.ty, span = call.span, kind = t.kind), pty) {
      case Some(c) -> Some(value = c)
      case None -> uncoveredExpr(env, call, "a default argument needing a conversion")
    }
    case None -> None
  }
}

/// An argument bound to a temporary, with its position in the source.
record OrderedStmt {
  order: Int
  stmt: TStmt
}

/// `call` run after the statements `pre` that bind its reordered arguments in source order.
func withPrelude(env: in BuildEnv, e: in Expr, pre: in List[TStmt], call: in TExpr): TExpr {
  if pre.count == 0 {
    return call
  }
  TExpr(id = freshNodeId(env), ty = call.ty, span = e.span, kind = XBlock(stmts = pre, tail = Some(value = call)))
}

/// The arguments of a call placed by parameter, in parameter order, each built and
/// converted to its parameter's type; `None` after counting why not.
func buildCallArgs(
  env: in BuildEnv, e: in Expr, sig: in ResolvedSignature, args: in List[CallArg], pre: in List[TStmt]
): Option[List[TArg]] {
  val slots: List[Option[Expr]] = newList()
  val srcIdx: List[Int] = newList()
  var pi = 0
  while pi < sig.params.count {
    slots.add(None)
    srcIdx.add(-1)
    pi = pi + 1
  }
  var si = 0
  for a in args {
    match a {
      case CANamed(name, x, _) -> match paramIndex(sig, name) {
        case Some(ix) -> {
          match slots[ix] {
            case Some(_) -> return uncoveredArgs(env, e, "a call naming one parameter twice")
            case None -> ()
          }
          slots[ix] = Some(value = x)
          srcIdx[ix] = si
        }
        case None -> return uncoveredArgs(env, e, "a call with an unknown named argument")
      }
      case CAPositional(_) -> ()
    }
    si = si + 1
  }
  var nextFree = 0
  si = 0
  for a in args {
    match a {
      case CAPositional(x) -> {
        while nextFree < slots.count and slots[nextFree].isSome() {
          nextFree = nextFree + 1
        }
        if nextFree >= slots.count {
          return uncoveredArgs(env, e, "a call with extra arguments")
        }
        slots[nextFree] = Some(value = x)
        srcIdx[nextFree] = si
        nextFree = nextFree + 1
      }
      case CANamed(_, _, _) -> ()
    }
    si = si + 1
  }
  var reordered = false
  var last = -1
  var k = 0
  while k < srcIdx.count {
    if srcIdx[k] >= 0 {
      if srcIdx[k] < last {
        reordered = true
      }
      last = srcIdx[k]
    }
    k = k + 1
  }
  val hoisted: List[OrderedStmt] = newList()
  val targs: List[TArg] = newList()
  var ok = true
  var i = 0
  while i < sig.params.count {
    val p = sig.params[i]
    match slots[i] {
      case None -> {
        if p.hasDefault {
          match buildDefaultArg(env, e, p) {
            case Some(t) -> targs.add(TArgIn(value = t))
            case None -> {
              ok = false
            }
          }
        } else {
          ok = false
          noteUncovered(env, "a missing argument")
        }
      }
      case Some(x) -> match p.mode {
        case PMIn -> match tyOfType(env.ctx, p.ty) {
          case Err(msg) -> {
            env.errors.add(msg)
            ok = false
          }
          case Ok(pty) -> match settleArg(env, x, pty) {
            case None -> {
              ok = false
            }
            case Some(t) -> match coerceArg(env, t, pty) {
              case Some(c) -> {
                // Arguments are evaluated in the order written. When names reorder them, an
                // argument that is not a literal or a name is bound to a temporary first, in
                // source order, and the call takes the temporary.
                if reordered and not isPlainArg(x) {
                  val d = declareLocal(env, "__arg" + toString(env.nextLocal[0] + 1), c.ty, false)
                  val bindPat = TPat(id = freshNodeId(env), ty = c.ty, span = c.span, kind = TpBind(decl = d, inner = None))
                  hoisted.add(
                    OrderedStmt(
                      order = srcIdx[i],
                      stmt = TStmt(id = freshNodeId(env), span = c.span, kind = TsLet(pat = bindPat, init = c))
                    )
                  )
                  targs.add(TArgIn(value = TExpr(id = freshNodeId(env), ty = c.ty, span = c.span, kind = XLocal(local = d.id))))
                } else {
                  targs.add(TArgIn(value = c))
                }
              }
              case None -> {
                ok = false
              }
            }
          }
        }
        case PMOut -> match buildPlace(env, x) {
          case Some(pl) -> targs.add(TArgOut(place = pl))
          case None -> {
            ok = false
          }
        }
        case PMInout -> match buildPlace(env, x) {
          case Some(pl) -> targs.add(TArgInout(place = pl))
          case None -> {
            ok = false
          }
        }
      }
    }
    i = i + 1
  }
  if not ok {
    env.errors.add(
      "I0002: the builder cannot build the call at " + toString(e.span.startPos.line) + ":" +
        toString(e.span.startPos.column) +
        " yet"
    )
    return None
  }
  var emitted = 0
  while emitted < hoisted.count {
    var best = -1
    var j = 0
    while j < hoisted.count {
      if hoisted[j].order >= 0 and (best < 0 or hoisted[j].order < hoisted[best].order) {
        best = j
      }
      j = j + 1
    }
    pre.add(hoisted[best].stmt)
    hoisted[best] = OrderedStmt(order = -1, stmt = hoisted[best].stmt)
    emitted = emitted + 1
  }
  Some(value = targs)
}
