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
}

pub func newBuildEnv(ctx: in TyConvCtx): BuildEnv {
  val next: List[Int] = newList()
  next.add(0)
  BuildEnv(ctx = ctx, scopes = newList(), nextLocal = next, errors = newList(), uncovered = newMap())
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
      case Some(d) -> return Some(value = d)
      case None -> ()
    }
    i = i - 1
  }
  None
}

/// Count a construct the builder has no case for.
func noteUncovered(env: in BuildEnv, what: in String): Unit {
  val n = match mapGet(env.uncovered, what) {
    case Some(k) -> k
    case None -> 0
  }
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
func stringPart(part: in TExpr): TExpr {
  match part.ty {
    case TPrim(TPString) -> part
    case _ -> {
      val one: List[TExpr] = newList()
      one.add(part)
      TExpr(
        id = part.id,
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
    case Err(msg) -> {
      env.errors.add(msg)
      return None
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
            TExpr(id = NodeId(id = e.nodeId), ty = tyString(), span = sp, kind = XLit(lit = TLString(text = text)))
          )
          case ISExpr(x) -> match buildExpr(env, x) {
            case Some(t) -> parts.add(stringPart(t))
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
      val iop = match op {
        case PreNeg -> Some(value = IoNeg)
        case PreNot -> Some(value = IoNot)
        case PreRef -> None
      }
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
            case Some(sop) -> Some(value = mkExpr(e, ty, XShort(op = sop, lhs = lt, rhs = rt)))
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
      val t = buildOrBlock(env, thenBranch, e, ty)
      var el: Option[TExpr] = None
      var elOk = true
      match elseBranch {
        case Some(eb) -> match buildOrBlock(env, eb, e, ty) {
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
    case EBlock(b) -> buildBlock(env, b, Some(value = ty), e)
    case EUnsafe(b) -> match buildBlock(env, b, Some(value = ty), e) {
      case Some(body) -> Some(value = mkExpr(e, ty, XUnsafe(body = body)))
      case None -> None
    }
    case ECall(_, _) -> uncoveredExpr(env, e, "a call")
    case EMember(_, _) -> uncoveredExpr(env, e, "a member access")
    case EIndex(_, _) -> uncoveredExpr(env, e, "an index")
    case EMatch(_, _) -> uncoveredExpr(env, e, "a match")
    case ELambda(_, _) -> uncoveredExpr(env, e, "a lambda")
    case EAssign(_, _, _) -> uncoveredExpr(env, e, "an assignment")
    case ERange(_) -> uncoveredExpr(env, e, "a range")
    case ESelf -> uncoveredExpr(env, e, "self")
    case ETry(_) -> uncoveredExpr(env, e, "a try expression")
    case ETypeApp(_, _) -> uncoveredExpr(env, e, "a type application")
    case EForall(_, _, _, _) -> uncoveredExpr(env, e, "a quantifier")
    case EExists(_, _, _, _) -> uncoveredExpr(env, e, "a quantifier")
    case EError -> uncoveredExpr(env, e, "an error node")
  }
}

/// A branch of an `if`: an expression, or a block typed as the `if` is.
func buildOrBlock(env: in BuildEnv, b: in ExprOrBlock, owner: in Expr, ty: in Ty): Option[TExpr] {
  match b {
    case EOBExpr(x) -> buildExpr(env, x)
    case EOBBlock(blk) -> buildBlock(env, blk, Some(value = ty), owner)
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
pub func buildBlock(env: in BuildEnv, b: in Block, known: in Option[Ty], owner: in Expr): Option[TExpr] {
  pushScope(env)
  val stmts: List[TStmt] = newList()
  var tail: Option[TExpr] = None
  var ok = true
  val unitBlock = match known {
    case Some(k) -> isUnitTy(k)
    case None -> false
  }
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
      case _ -> match buildStmt(env, s) {
        case Some(ts) -> stmts.add(ts)
        case None -> {
          ok = false
        }
      }
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
      case None -> tyUnit()
    }
  }
  Some(value = TExpr(id = NodeId(id = owner.nodeId), ty = ty, span = b.span, kind = XBlock(stmts = stmts, tail = tail)))
}

func loopBody(env: in BuildEnv, b: in Block, owner: in Expr): Option[TExpr] {
  buildBlock(env, b, Some(value = tyUnit()), owner)
}

func stmtOf(s: in Statement, kind: in TStmtKind): TStmt {
  TStmt(id = NodeId(id = s.nodeId), span = s.span, kind = kind)
}

/// A statement's owner expression for blocks it contains: the blocks of
/// statements have no node of their own, so they take the statement's number.
func stmtOwner(s: in Statement, e: in Expr): Expr {
  Expr(kind = e.kind, span = s.span, nodeId = s.nodeId)
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
      val owner = Expr(kind = EError, span = s.span, nodeId = s.nodeId)
      val bd = loopBody(env, body, owner)
      match c {
        case Some(ct) -> match bd {
          case Some(bt) -> Some(value = stmtOf(s, TsWhile(label = label, cond = ct, body = bt)))
          case None -> None
        }
        case None -> None
      }
    }
    case SLoop(label, body) -> {
      val owner = Expr(kind = EError, span = s.span, nodeId = s.nodeId)
      match loopBody(env, body, owner) {
        case Some(bt) -> Some(value = stmtOf(s, TsLoop(label = label, body = bt)))
        case None -> None
      }
    }
    case SFor(_, _, _, _) -> uncoveredStmt(env, s, "a for loop")
    case SAssign(_, _, _) -> uncoveredStmt(env, s, "an assignment")
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

/// A `val`, `let` or `var` of one name and no annotation: its local takes the
/// initializer's type, declared after the initializer is built so the
/// initializer cannot see it.  A pattern or an annotated binding has no case yet.
func buildLocal(env: in BuildEnv, s: in Statement, binding: in Px.LocalBinding): Option[TStmt] {
  match binding {
    case LBVal(pat, ann, init) -> match ann {
      case Some(_) -> uncoveredStmt(env, s, "an annotated binding")
      case None -> match pat.kind {
        case PBinding(name, None) -> buildLet(env, s, pat, name, init)
        case _ -> uncoveredStmt(env, s, "a binding pattern")
      }
    }
    case LBLet(name, ann, init) -> match ann {
      case Some(_) -> uncoveredStmt(env, s, "an annotated binding")
      case None -> {
        val pat = Pattern(kind = PBinding(name = name, inner = None), span = s.span, nodeId = s.nodeId)
        buildLet(env, s, pat, name, init)
      }
    }
    case LBVar(name, ann, init) -> match ann {
      case Some(_) -> uncoveredStmt(env, s, "an annotated binding")
      case None -> match init {
        case None -> uncoveredStmt(env, s, "a var without an initializer")
        case Some(x) -> match buildExpr(env, x) {
          case Some(t) -> {
            val d = declareLocal(env, name, t.ty, true)
            Some(value = stmtOf(s, TsVar(decl = d, init = Some(value = t))))
          }
          case None -> None
        }
      }
    }
  }
}

func buildLet(env: in BuildEnv, s: in Statement, pat: in Pattern, name: in String, init: in Expr): Option[TStmt] {
  match buildExpr(env, init) {
    case Some(t) -> {
      val d = declareLocal(env, name, t.ty, false)
      val tp = TPat(id = NodeId(id = pat.nodeId), ty = t.ty, span = pat.span, kind = TpBind(decl = d, inner = None))
      Some(value = stmtOf(s, TsLet(pat = tp, init = t)))
    }
    case None -> None
  }
}

/// A function's body as TIR, or `None` with the reasons in `env.errors`.  The
/// parameters become the outermost locals; a generic function, a function with
/// contracts and a function with an expression body are not covered yet.
pub func buildFnBody(env: in BuildEnv, fn: in FunctionDecl, tbl: in SymbolTable): Option[TExpr] {
  match fn.generics {
    case Some(_) -> {
      noteUncovered(env, "a generic function")
      env.errors.add("I0002: the builder has no case for a generic function: " + fn.name)
      return None
    }
    case None -> ()
  }
  pushScope(env)
  val diag: List[Diagnostic] = newList()
  val gc = GenericContext(params = newList(), owners = newList(), stackDepths = newList())
  var ok = true
  for p in fn.params {
    match tyOfType(env.ctx, resolveType(tbl, gc, diag, p.ty)) {
      case Ok(t) -> {
        val _ = declareLocal(env, p.name, t, false)
      }
      case Err(msg) -> {
        env.errors.add(msg)
        ok = false
      }
    }
  }
  var res: Option[TExpr] = None
  if ok {
    match fn.body {
      case Some(FBBlock(b)) -> {
        val owner = Expr(kind = EError, span = fn.span, nodeId = 0)
        res = buildBlock(env, b, None, owner)
      }
      case Some(FBExpr(x)) -> {
        res = buildExpr(env, x)
      }
      case None -> ()
    }
  }
  popScope(env)
  res
}
