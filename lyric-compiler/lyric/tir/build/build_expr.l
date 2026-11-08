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

func uncoveredExpr(env: in BuildEnv, e: in Expr, what: in String): Option[TExpr] {
  noteUncovered(env, what)
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
          case Some(d) -> return Some(value = mkExpr(e, ty, XLocal(local = d.id)))
          case None -> ()
        }
      }
      match refSite(env.ctx, e.nodeId) {
        case Some(r) -> match r.kind {
          case RkNullaryCase -> {
            noteCaseSym(env, r.sym)
            return Some(value = mkExpr(e, ty, XConstruct(sym = r.sym, fields = newList())))
          }
          case _ -> {
            noteGlobalSym(env, r.sym, ty)
            return Some(value = mkExpr(e, ty, XGlobal(sym = r.sym, typeArgs = newList())))
          }
        }
        case None -> ()
      }
      uncoveredExpr(env, e, "a name that is not a local")
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
                uncoveredExpr(env, e, "an operator on a declared type")
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
    case ESelf -> uncoveredExpr(env, e, "self")
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
  noteUncovered(env, what)
  env.errors.add(
    "I0002: the builder has no case for " + what + " at " + toString(p.span.startPos.line) + ":" +
      toString(p.span.startPos.column)
  )
  None
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
        case Some(ts) -> Some(
          value = withCaseSym(
            env,
            sym,
            mkPat(
              p,
              ty,
              TpCtor(sym = sym, args = ts)
            )
          )
        )
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
    case PRange(_, _, _, _) -> uncoveredPat(env, p, "a range pattern")
    case POr(_) -> uncoveredPat(env, p, "an or-pattern")
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
func buildOrBlock(env: in BuildEnv, b: in ExprOrBlock, ty: in Ty): Option[TExpr] {
  val built = match b {
    case EOBExpr(x) -> buildExpr(env, x)
    case EOBBlock(blk) -> buildBlock(env, blk, Some(value = ty), freshNodeId(env))
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
    case SFor(_, _, _, _) -> uncoveredStmt(env, s, "a for loop")
    case SAssign(t, op, v) -> {
      val ae = Expr(kind = EAssign(target = t, op = op, value = v), span = s.span, nodeId = freshNodeId(env).id)
      match buildAssign(env, ae, t, op, v) {
        case Some(x) -> Some(value = stmtOf(s, TsExpr(expr = x)))
        case None -> None
      }
    }
    case SThrow(_) -> uncoveredStmt(env, s, "a throw")
    case STry(_, _, _) -> uncoveredStmt(env, s, "a try statement")
    case SDefer(_) -> uncoveredStmt(env, s, "a defer")
    case SScope(_, _) -> uncoveredStmt(env, s, "a scope")
    case SInvariant(_) -> uncoveredStmt(env, s, "a loop invariant")
    case SRule(_, _) -> uncoveredStmt(env, s, "a rule")
    case SItem(_) -> uncoveredStmt(env, s, "a local item")
  }
}

func uncoveredStmt(env: in BuildEnv, s: in Statement, what: in String): Option[TStmt] {
  noteUncovered(env, what)
  env.errors.add(
    "I0002: the builder has no case for " + what + " at " + toString(s.span.startPos.line) + ":" +
      toString(s.span.startPos.column)
  )
  None
}

/// A `val`, `let` or `var` of one name: its local takes the annotation's type when
/// there is one (the initializer is converted to it) and the initializer's otherwise,
/// declared after the initializer is built so the initializer cannot see it.  A
/// pattern, or a `var` without an initializer, has no case yet.
func buildLocal(env: in BuildEnv, s: in Statement, binding: in Px.LocalBinding): Option[TStmt] {
  match binding {
    case LBVal(pat, ann, init) -> match pat.kind {
      case PBinding(name, None) -> buildLet(env, s, pat, name, ann, init)
      case _ -> uncoveredStmt(env, s, "a binding pattern")
    }
    case LBLet(name, ann, init) -> {
      val pat = Pattern(kind = PBinding(name = name, inner = None), span = s.span, nodeId = freshNodeId(env).id)
      buildLet(env, s, pat, name, ann, init)
    }
    case LBVar(name, ann, init) -> match init {
      case None -> uncoveredStmt(env, s, "a var without an initializer")
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

/// The initializer of a binding as a value of the annotated type, or as built when
/// there is no annotation.
func buildInit(env: in BuildEnv, s: in Statement, ann: in Option[TypeExpr], init: in Expr): Option[TExpr] {
  val t = match buildExpr(env, init) { case Some(x) -> x; case None -> return None }
  match ann {
    case None -> Some(value = t)
    case Some(te) -> {
      // The checker has already reported an annotation that does not resolve, so the
      // diagnostics of this second resolution are not read.
      val diag: List[Diagnostic] = newList()
      val gc = if env.generics.count > 0 {
        env.generics[0]
      } else {
        GenericContext(params = newList(), owners = newList(), stackDepths = newList())
      }
      val want = match tyOfType(env.ctx, resolveType(env.ctx.tbl, gc, diag, te)) {
        case Ok(w) -> w
        case Err(msg) -> {
          env.errors.add(msg)
          return None
        }
      }
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
}

func buildFnCore(env: in BuildEnv, fn: in FunctionDecl, tbl: in SymbolTable, wantSym: in Bool): Option[FnCore] {
  val gc = GenericContext(params = newList(), owners = newList(), stackDepths = newList())
  val names = extractGenericNames(fn.generics)
  val sym = symTableFuncSymOf(tbl, fn)
  match fn.generics {
    case Some(_) -> {
      match sym {
        case Some(sy) -> {
          tyConvBind(env.ctx, fn.name, sy, names)
          gctxPushOwned(gc, names, fn.name)
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
  if ok {
    for c in fn.contracts {
      match c {
        case CCRequires(x, _) -> match buildExpr(env, x) { case Some(t) -> pre.add(t); case None -> { ok = false } }
        case CCEnsures(x, _) -> match buildExpr(env, x) { case Some(t) -> post.add(t); case None -> { ok = false } }
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
        typeNames = names,
        params = params,
        ret = ret,
        pre = pre,
        post = post,
        body = b
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
          span = fn.span
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
  /// The first I0002 message of each body that did not build: the cause, where
  /// `uncovered` also counts the uses a failed binding leaves undefined.
  firstErrors: List[String] = newList()
  /// The built functions as a package, with the declarations their bodies reach.
  pkg: TPackage = TPackage(name = "", symbols = newList(), funcs = newList())
}

/// Build every function body of `file` that has one, each with a fresh
/// `BuildEnv`, and total the outcome.
pub func buildCensus(ctx: in TyConvCtx, tbl: in SymbolTable, file: in SourceFile): BuildCensus {
  val funcs: List[TFnDecl] = newList()
  val syms: Map[Int, TSymEntry] = newMap()
  var total = 0
  var built = 0
  val firstErrors: List[String] = newList()
  val sums: Map[String, Int] = newMap()
  val counter: List[Int] = newList()
  counter.add(firstSynthNodeId())
  for it in file.items {
    match it.kind {
      case IFunc(decl) -> match decl.body {
        case Some(_) -> {
          total = total + 1
          val env = newBuildEnvSharing(ctx, counter)
          match buildFnDecl(env, decl, tbl) {
            case Some(fd) -> {
              built = built + 1
              funcs.add(fd)
              if not syms.containsKey(fd.sym.id) {
                syms.add(fd.sym.id, ownFnEntry(fd))
              }
            }
            case None -> {
              if env.errors.count > 0 {
                firstErrors.add(decl.name + ": " + env.errors[0])
              }
            }
          }
          for sk in mapKeys(env.syms) {
            match mapGet(env.syms, sk) {
              case Some(en) -> if not syms.containsKey(sk) { syms.add(sk, en) }
              case None -> ()
            }
          }
          for k in mapKeys(env.uncovered) {
            val add = match mapGet(env.uncovered, k) { case Some(n) -> n; case None -> 0 }
            val had = match mapGet(sums, k) { case Some(n) -> n; case None -> 0 }
            if sums.containsKey(k) {
              sums.remove(k)
            }
            sums.add(k, had + add)
          }
        }
        case None -> ()
      }
      case _ -> ()
    }
  }
  for te in typeEntries(tbl) {
    if not syms.containsKey(te.sym.id) {
      syms.add(te.sym.id, te)
    }
  }
  val entries: List[TSymEntry] = newList()
  for k in mapKeys(syms) {
    match mapGet(syms, k) {
      case Some(en) -> entries.add(en)
      case None -> ()
    }
  }
  BuildCensus(
    total = total,
    built = built,
    uncovered = sums,
    firstErrors = firstErrors,
    pkg = TPackage(name = "", symbols = entries, funcs = funcs)
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
    res.add(best + " x " + toString(bestN))
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
  uncoveredExpr(env, e, "a call the checker did not resolve")
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
      None
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
    case TyUser(id, hd, _) -> if name == "count" and (hd == "List" or hd == "Map" or hd == "Set") {
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
          case Some(d) -> return Some(value = TPlace(ty = d.ty, kind = PlLocal(local = d.id)))
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
    case None -> None
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

/// A branch of an `if` or `match` as the whole takes it: as is, widened by a node of
/// its own, or not at all (counted).  A branch that never completes fits any type.
func coerceBranch(env: in BuildEnv, t: in TExpr, ty: in Ty): Option[TExpr] {
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
        case Some(rt) -> genericArgsFromResult(sig, rt)
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
  match buildCallArgs(env, e, callSig, args) {
    case Some(targs) -> {
      noteFuncSym(env, sym, sig, None, None, TSkFunc)
      Some(value = mkExpr(e, ty, XCall(callee = Direct(sym = sym, typeArgs = tyArgs), args = targs)))
    }
    case None -> None
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
  match site.sig.recvMode {
    case Some(PMIn) -> ()
    case Some(_) -> return uncoveredExpr(env, e, "a method call with a mutating receiver")
    case None -> return uncoveredExpr(env, e, "a method call with no declared receiver")
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
  val rest = match buildCallArgs(env, e, site.sig, args) { case Some(a) -> a; case None -> return None }
  val all: List[TArg] = newList()
  all.add(TArgIn(value = recv))
  for a in rest {
    all.add(a)
  }
  val callee = match site.iface {
    case Some(i) -> Interface(iface = i, ifaceArgs = newList(), method = sym, typeArgs = newList())
    case None -> Direct(sym = sym, typeArgs = newList())
  }
  noteFuncSym(
    env,
    sym,
    site.sig,
    Some(value = site.recvTy),
    site.sig.recvMode,
    if isSome(site.iface) { TSkInterfaceMethod } else { TSkFunc }
  )
  Some(value = mkExpr(e, ty, XCall(callee = callee, args = all)))
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
  match buildCallArgs(env, e, sig, args) {
    case Some(targs) -> {
      val fields: List[TExpr] = newList()
      for a in targs {
        match a {
          case TArgIn(v) -> fields.add(v)
          case _ -> return uncoveredExpr(env, e, "a construction field passed by reference")
        }
      }
      noteCaseSym(env, sym)
      noteCtorSym(env, sym, sig)
      Some(value = mkExpr(e, ty, XConstruct(sym = sym, fields = fields)))
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

/// The arguments of a call placed by parameter, in parameter order, each built and
/// converted to its parameter's type; `None` after counting why not.
func buildCallArgs(env: in BuildEnv, e: in Expr, sig: in ResolvedSignature, args: in List[CallArg]): Option[List[TArg]] {
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
  if reordered {
    for sl in slots {
      match sl {
        case Some(x) -> if not isPlainArg(x) {
          return uncoveredArgs(env, e, "a call whose named arguments reorder effects")
        }
        case None -> ()
      }
    }
  }
  val targs: List[TArg] = newList()
  var ok = true
  var i = 0
  while i < sig.params.count {
    val p = sig.params[i]
    match slots[i] {
      case None -> {
        ok = false
        if p.hasDefault {
          noteUncovered(env, "a defaulted argument")
        } else {
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
              case Some(c) -> targs.add(TArgIn(value = c))
              case None -> {
                ok = false
              }
            }
          }
        }
        case _ -> {
          noteUncovered(env, "an res or inout argument")
          ok = false
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
  Some(value = targs)
}
