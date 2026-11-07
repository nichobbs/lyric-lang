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
    nextNode = counter
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
      case Some(d) -> return Some(value = d)
      case None -> ()
    }
    i = i - 1
  }
  None
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
    case Err(msg) -> {
      env.errors.add(msg + " (at " + toString(e.span.startPos.line) + ":" + toString(e.span.startPos.column) + ")")
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
func buildOrBlock(env: in BuildEnv, b: in ExprOrBlock, ty: in Ty): Option[TExpr] {
  match b {
    case EOBExpr(x) -> buildExpr(env, x)
    case EOBBlock(blk) -> buildBlock(env, blk, Some(value = ty), freshNodeId(env))
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
  val ty = match known { case Some(k) -> k; case None -> match tail { case Some(t) -> t.ty; case None -> tyUnit() } }
  Some(value = TExpr(id = id, ty = ty, span = b.span, kind = XBlock(stmts = stmts, tail = tail)))
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
        res = buildBlock(env, b, None, freshNodeId(env))
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

/// How many function bodies of a file the builder covers, and what it has no
/// case for, by kind with the number of nodes (the `--verify-ir` census, D366).
pub record BuildCensus {
  total: Int
  built: Int
  uncovered: Map[String, Int]
}

/// Build every function body of `file` that has one, each with a fresh
/// `BuildEnv`, and total the outcome.
pub func buildCensus(ctx: in TyConvCtx, tbl: in SymbolTable, file: in SourceFile): BuildCensus {
  var total = 0
  var built = 0
  val sums: Map[String, Int] = newMap()
  val counter: List[Int] = newList()
  counter.add(firstSynthNodeId())
  for it in file.items {
    match it.kind {
      case IFunc(decl) -> match decl.body {
        case Some(_) -> {
          total = total + 1
          val env = newBuildEnvSharing(ctx, counter)
          match buildFnBody(env, decl, tbl) {
            case Some(_) -> {
              built = built + 1
            }
            case None -> ()
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
  BuildCensus(total = total, built = built, uncovered = sums)
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
        case _ -> return uncoveredExpr(env, e, "a package-qualified or static call")
      }
      case None -> ()
    }
    case None -> ()
  }
  if tbl.externByNode.containsKey(e.nodeId) {
    return uncoveredExpr(env, e, "an extern call")
  }
  if tbl.calleeByNode.containsKey(e.nodeId) {
    return uncoveredExpr(env, e, "a method, constructor or member call")
  }
  uncoveredExpr(env, e, "a call the checker did not resolve")
}

/// An argument as the parameter `pty` takes it: as is, widened by a node of its own,
/// or not at all (counted), never converted by guessing.
func coerceArg(env: in BuildEnv, t: in TExpr, pty: in Ty): Option[TExpr] {
  if tyEq(t.ty, pty) {
    return Some(value = t)
  }
  match widenKind(t.ty, pty) {
    case Some(k) -> Some(
      value = TExpr(
        id = freshNodeId(env),
        ty = pty,
        span = t.span,
        kind = XConvert(kind = k, inner = t)
      )
    )
    case None -> {
      noteUncovered(env, "an argument conversion")
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
  if sig.generics.count > 0 {
    return uncoveredExpr(env, e, "a generic call")
  }
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
            case Some(_) -> return uncoveredExpr(env, e, "a call naming one parameter twice")
            case None -> ()
          }
          slots[ix] = Some(value = x)
          srcIdx[ix] = si
        }
        case None -> return uncoveredExpr(env, e, "a call with an unknown named argument")
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
          return uncoveredExpr(env, e, "a call with extra arguments")
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
          return uncoveredExpr(env, e, "a call whose named arguments reorder effects")
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
          case Ok(pty) -> match buildExpr(env, x) {
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
  Some(value = mkExpr(e, ty, XCall(callee = Direct(sym = sym, typeArgs = newList()), args = targs)))
}
