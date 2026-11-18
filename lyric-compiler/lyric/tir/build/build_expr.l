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
import Std.String as Str
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Parser
import Lyric.Parser as Px
import Lyric.TypeChecker
import Lyric.Tir
import Lyric.Tir as TirT
import Lyric.Iface

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
  /// The unions `retypeValue` is rebuilding, innermost last: a payload that holds the same union
  /// would need an unbounded match.
  retyping: List[Int] = newList()
  /// The type of the member's receiver (empty or one entry): the body's `self`, declared as the
  /// leading parameter.
  recvTy: List[Ty] = newList()
  /// The generic type or `impl` the member being built belongs to (empty or one entry).
  memberOwner: List[MemberOwner] = newList()
  /// The locals the first alternative of an or-pattern bound: a later alternative's binding of
  /// the same name is that local (every alternative binds the same names).
  orBound: List[LocalDecl] = newList()
  /// The value-generic parameters of the function being built (owner's first), by name: a bare
  /// read of one is an `XValueParam` (D469).
  valueParams: List[ValueParamRef] = newList()
}

/// A value-generic parameter a body may read by name: its position among the member's type
/// parameters (the owner's first) and the symbol that binds them.
pub record ValueParamRef {
  name: String
  owner: SymbolId
  index: Int
}

/// The binder of a member's owner: the checker's key for it (a type's name, or the `impl`'s
/// key), the symbol that stands for it in a `TParam`, and its type parameters in order.
pub record MemberOwner {
  key: String
  sym: SymbolId
  names: List[String]
  /// Which of `names` are value-generic parameters (`N: Nat`).
  valueNames: List[String] = newList()
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

/// `uncoveredExpr` with the specifics of the site in the message (the kind `what` stays the census key).
func uncoveredExprDetail(env: in BuildEnv, e: in Expr, what: in String, detail: in String): Option[TExpr] {
  noteUncoveredAt(env, what, e.span)
  env.errors.add(
    "I0002: the builder has no case for " + what + " (" + detail + ") at " + toString(e.span.startPos.line) + ":" +
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

/// A binary operator on values that are not primitives: `a == b` and `a != b` (language reference
/// 2.5, D172, D206), the ordering operators a type derives or a type parameter is bounded by
/// (`T: Compare`), and the arithmetic of a distinct, range or record type that derives `Add`, `Sub`
/// and the rest.  One intrinsic over both operands, lowered by each backend by the operands' type
/// (a distinct value by its underlying value, a range subtype's result range-checked).  The operands
/// have the same type, the right one converted to the left's when the checker accepted a difference
/// (`opt == 5`); the result has the type the checker gave the expression.
func buildDeclaredBinary(
  env: in BuildEnv, e: in Expr, ty: in Ty, iop: in IntrinsicOp, lt: in TExpr, rt: in TExpr
): Option[TExpr] {
  val rhs = if tyEq(lt.ty, rt.ty) { Some(value = rt) } else { convertValue(env, rt, lt.ty) }
  match rhs {
    case Some(r2) -> {
      val two: List[TExpr] = newList()
      two.add(lt)
      two.add(r2)
      Some(value = mkExpr(e, ty, intrinsicCall(iop, two)))
    }
    case None -> uncoveredExpr(env, e, "an operator on operands of different types")
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

/// A bare read of a value-generic parameter of the function being built (`N` of `N: Nat`): an
/// `Int` constant in the body (docs/01), `XValueParam` in the TIR (D469).
func valueParamRead(env: in BuildEnv, e: in Expr): Option[TExpr] {
  match e.kind {
    case EPath(p) -> {
      if p.segments.count != 1 {
        return None
      }
      for v in env.valueParams {
        if v.name == p.segments[0] {
          return Some(value = mkExpr(e, tyInt(), XValueParam(owner = v.owner, index = v.index)))
        }
      }
      None
    }
    case _ -> None
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
        case None -> match valueParamRead(env, e) {
          case Some(v) -> Some(value = v)
          case None -> match sharedCaseRead(env, e, ty) {
            case Some(v) -> Some(value = v)
            case None -> uncoveredExpr(env, e, "a name that is not a local")
          }
        }
      }
    }
  }
}

/// A bare case name several enums share (`On` of `Beam` and `Ray`), read where the expected type decided which
/// enum it is: the checker settled the node's type at that enum and recorded no reference (the name alone does not
/// say), so the case is the one of that enum with the name.  None when the type is not a type with such a case.
func sharedCaseRead(env: in BuildEnv, e: in Expr, ty: in Ty): Option[TExpr] {
  val name = match e.kind {
    case EPath(p) -> if p.segments.count == 1 { p.segments[0] } else { return None }
    case _ -> return None
  }
  val owner = match ty {
    case TNamed(did, targs) -> if targs.count == 0 { did } else { return None }
    case _ -> return None
  }
  for cand in symTableTryFindAllNamed(env.ctx.tbl, name) {
    val parent = match cand.kind {
      case DKEnumCase(pid, _) -> Some(value = pid)
      case DKUnionCase(pid, uc) -> if uc.fields.count == 0 { Some(value = pid) } else { None }
      case _ -> None
    }
    match parent {
      case Some(pid) -> if symbolIdEq(pid, owner) {
        match caseSymbolId(env.ctx.tbl, cand, pid, name) {
          case Some(id) -> {
            noteCaseSym(env, id)
            return Some(value = mkExpr(e, ty, XConstruct(sym = id, fields = newList())))
          }
          case None -> ()
        }
      }
      case None -> ()
    }
  }
  None
}

/// Whether control never reaches the end of the block `b`.
func blockNeverCompletes(b: in Block): Bool {
  if b.statements.count == 0 {
    return false
  }
  statementNeverCompletes(b.statements[b.statements.count - 1])
}

func statementNeverCompletes(s: in Statement): Bool {
  match s.kind {
    case SReturn(_) -> true
    case SThrow(_) -> true
    case SBreak(_) -> true
    case SContinue(_) -> true
    case SExpr(x) -> exprNeverCompletes(x)
    case _ -> false
  }
}

func branchNeverCompletes(b: in ExprOrBlock): Bool {
  match b {
    case EOBExpr(x) -> exprNeverCompletes(x)
    case EOBBlock(bl) -> blockNeverCompletes(bl)
  }
}

/// Whether the source expression `e` is a `match` or `if` whose every branch leaves, or a block
/// that ends in a statement that does: the checker records no join type for it.
/// A `break` or `continue` counts as leaving the branch: it leaves the enclosing loop body, so control
/// does not reach the end of the branch (a loop's own statements are not inspected).
func exprNeverCompletes(e: in Expr): Bool {
  match e.kind {
    case EMatch(_, arms) -> {
      if arms.count == 0 {
        return false
      }
      for arm in arms {
        if not branchNeverCompletes(arm.body) {
          return false
        }
      }
      true
    }
    case EIf(_, thenBranch, elseBranch, _) -> match elseBranch {
      case Some(x) -> branchNeverCompletes(thenBranch) and
        branchNeverCompletes(x)
      case None -> false
    }
    case EBlock(bl) -> blockNeverCompletes(bl)
    case _ -> false
  }
}

/// The expression `x` without its parentheses.
func unparen(x: in Expr): Expr {
  match x.kind {
    case EParen(i) -> unparen(i)
    case _ -> x
  }
}

/// The type the checker recorded for the operand of `?` (`hoistOperandTypeSites`: the closed type of
/// a construction that leaves a type argument open), when it recorded one without a conflict.
func hoistedOperandTy(env: in BuildEnv, inner: in Expr): Option[Ty] {
  match mapGet(env.ctx.tbl.hoistOperandTypeSites, recordCopySiteKey(inner.span)) {
    case Some(site) -> if site.conflicting {
      None
    } else {
      match annotatedTy(env, site.operandType) {
        case Some(t) -> Some(value = t)
        case None -> None
      }
    }
    case None -> None
  }
}

/// The type of the operand of `?` when it is a `Result` or `Option` construction that leaves a type
/// argument open (`Ok(value = "bb")?`, `Err(error = x)?`, `None?`), which the checker records no type
/// for (`openPropagateOperands`).  A success value fixes the success type (the payload's own type);
/// the failure path is the enclosing function's, so the error type is the function's; a failure
/// value or `None` fixes only the error type, and the success type is what the `?` yields
/// (`yielded`).  None when the operand is not such a construction or the function's own type is
/// not recorded.
func propagateOperandTy(env: in BuildEnv, inner: in Expr, yielded: in Ty): Option[Ty] {
  match hoistedOperandTy(env, inner) {
    case Some(t) -> return Some(value = t)
    case None -> ()
  }
  val op = match mapGet(env.ctx.tbl.openPropagateOperands, recordCopySiteKey(inner.span)) {
    case Some(o) -> o
    case None -> return None
  }
  val fb = match tyOfType(env.ctx, op.fallback) { case Ok(t) -> t; case Err(_) -> return None }
  val sym = match fb { case TNamed(s, _) -> s; case _ -> return None }
  val args = match fb { case TNamed(_, a) -> a; case _ -> return None }
  val operand = unparen(inner)
  var name = ""
  var payload: Option[Expr] = None
  match operand.kind {
    case EPath(p) -> {
      name = p.segments[p.segments.count - 1]
    }
    case ECall(fn, cargs) -> {
      match fn.kind {
        case EPath(p) -> {
          name = p.segments[p.segments.count - 1]
        }
        case _ -> return None
      }
      if cargs.count == 1 {
        match cargs[0] {
          case CAPositional(x) -> {
            payload = Some(value = x)
          }
          case CANamed(_, x, _) -> {
            payload = Some(value = x)
          }
        }
      }
    }
    case _ -> return None
  }
  val payloadTy: Option[Ty] = match payload {
    case Some(x) -> match exprTy(env.ctx, x.nodeId) {
      case Ok(t) -> Some(value = t)
      case Err(_) -> None
    }
    case None -> None
  }
  if args.count == 2 {
    if name == "Ok" {
      match payloadTy {
        case Some(t) -> return Some(value = TNamed(sym = sym, args = [t, args[1]]))
        case None -> return None
      }
    }
    if name == "Err" {
      val et = match payloadTy { case Some(t) -> t; case None -> args[1] }
      return Some(value = TNamed(sym = sym, args = [yielded, et]))
    }
    return None
  }
  if args.count == 1 {
    if name == "Some" {
      match payloadTy {
        case Some(t) -> return Some(value = TNamed(sym = sym, args = [t]))
        case None -> return None
      }
    }
    if name == "None" {
      return Some(value = TNamed(sym = sym, args = [yielded]))
    }
  }
  None
}

/// What `Ok(x)?` and `Some(x)?` yield when the checker left the whole `?` untyped (the construction's
/// other type argument is open): the payload's own type.  `Err(x)?` and `None?` yield what their
/// position expects, which only a context fixes.
func openPropagateYield(env: in BuildEnv, e: in Expr): Option[Ty] {
  val inner = match e.kind { case EPropagate(i) -> unparen(i); case _ -> return None }
  match hoistedOperandTy(env, inner) {
    case Some(TNamed(_, args)) -> if args.count > 0 { return Some(value = args[0]) }
    case _ -> ()
  }
  match inner.kind {
    case ECall(fn, cargs) -> {
      val name = match fn.kind { case EPath(p) -> p.segments[p.segments.count - 1]; case _ -> return None }
      if cargs.count != 1 or (name != "Ok" and name != "Some") {
        return None
      }
      val x = match cargs[0] { case CAPositional(v) -> v; case CANamed(_, v, _) -> v }
      match exprTy(env.ctx, x.nodeId) {
        case Ok(t) -> Some(value = t)
        case Err(_) -> None
      }
    }
    case _ -> None
  }
}

/// The type of an expression the checker left untyped, when its own shape gives it: a read of a
/// local declared at a type, or `Ok(x)?` and `Some(x)?`.
func openHoleTy(env: in BuildEnv, e: in Expr): Option[Ty] {
  // A comparison is a `Bool` whatever its operands: one with an operand the checker left untyped
  // (`chunk.length > 0` on a local holding a host array) has no recorded type of its own.
  match e.kind {
    case EBinop(op, _, _) -> match op {
      case BEq -> return Some(value = tyBool())
      case BNeq -> return Some(value = tyBool())
      case BLt -> return Some(value = tyBool())
      case BLte -> return Some(value = tyBool())
      case BGt -> return Some(value = tyBool())
      case BGte -> return Some(value = tyBool())
      case _ -> ()
    }
    case _ -> ()
  }
  match openLocalTy(env, e) {
    case Some(t) -> Some(value = t)
    case None -> match openPropagateYield(env, e) {
      case Some(t) -> Some(value = t)
      case None -> openHostChainTy(env, e)
    }
  }
}

/// The type of a call or property read on a host value, when the checker left it untyped: the host
/// class the host's metadata gives the member (`m.entrySet().iterator()`, where `entrySet()` returns a
/// host class no `extern type` names).  The checker leaves a host result unchecked (docs/01 section
/// 2.11), so the builder types the chain itself, from the receiver's host type and the member's
/// declared result; a member whose candidates do not agree on one host class stays counted (D444).
func openHostChainTy(env: in BuildEnv, e: in Expr): Option[Ty] {
  if env.ctx.tbl.externIterResolver.count == 0 {
    return None
  }
  match e.kind {
    case ECall(fn, args) -> match fn.kind {
      case EMember(recv, name) -> match hostChainReceiver(env, recv) {
        case Some(h) -> hostChainResult(
          env,
          h.host,
          name,
          args.count,
          false,
          h.isStatic
        )
        case None -> None
      }
      case _ -> None
    }
    case EMember(recv, name) -> match hostChainReceiver(env, recv) {
      case Some(h) -> hostChainResult(env, h.host, name, 0, true, h.isStatic)
      case None -> match openLocalBuiltinProperty(env, recv, name) {
        case Some(_) -> Some(value = tyInt())
        case None -> None
      }
    }
    case _ -> None
  }
}

/// A host receiver of a chain: a value of a host class, or (`isStatic`) the host class named by an
/// `extern type` (`JCharacter.TYPE`, `JKeyManagerFactory.getInstance(..)`).
record HostRecv {
  host: HostTypeRef
  isStatic: Bool
}

/// The host class an `extern type` named by the bare path `recv` stands for, when no local shadows it and
/// the type takes no type arguments.
func hostStaticReceiver(env: in BuildEnv, recv: in Expr): Option[HostTypeRef] {
  match recv.kind {
    case EPath(p) -> {
      if p.segments.count != 1 {
        return None
      }
      match lookupLocal(env, p.segments[0]) {
        case Some(_) -> return None
        case None -> ()
      }
      match symTableTryFindOne(env.ctx.tbl, p.segments[0]) {
        case Some(sym) -> match sym.kind {
          case DKExternType(_, d) -> if isSome(d.generics) {
            None
          } else {
            Some(value = HostTypeRef(name = d.clrName, args = newList()))
          }
          case _ -> None
        }
        case None -> None
      }
    }
    case _ -> None
  }
}

/// The host receiver of `recv`: its recorded type when that is a host class, else the type its own chain
/// gives, else the host class it names as an `extern type`.
func hostChainReceiver(env: in BuildEnv, recv: in Expr): Option[HostRecv] {
  match exprTy(env.ctx, recv.nodeId) {
    case Ok(t) -> match t { case TExtern(h) -> Some(value = HostRecv(host = h, isStatic = false)); case _ -> None }
    case Err(_) -> match openHostChainTy(env, recv) {
      case Some(t) -> match t {
        case TExtern(h) -> Some(value = HostRecv(host = h, isStatic = false))
        case _ -> None
      }
      case None -> match openLocalTy(env, recv) {
        // A local bound to an unchecked host result (`val server = JHttpServer.create(..)`) is read at
        // the host class it was declared at, though the checker recorded no type for the read.
        case Some(t) -> match t {
          case TExtern(h) -> Some(
            value = HostRecv(host = h, isStatic = false)
          )
          case _ -> None
        }
        case None -> match hostStaticReceiver(env, recv) {
          case Some(h) -> Some(value = HostRecv(host = h, isStatic = true))
          case None -> None
        }
      }
    }
  }
}

/// A local declared `String?` (a host string, which the checker types `String?` because the host may
/// return null) read where the checker wants a `String`: the checker lets a host string flow unchecked
/// (docs/01 section 2.11), as `CvFromHost` over the local.
func hostStringReadAsString(declared: in Ty, read: in Ty): Bool {
  match declared {
    case TNullable(TPrim(TPString)) -> match read {
      case TPrim(TPString) -> true
      case _ -> false
    }
    case _ -> false
  }
}

/// A host class a chain result can be typed as: not one the checker maps to a Lyric type (`hostResultIsCallType`).
func isPlainHostResult(name: in String): Bool {
  not hostNameHasLyricType(name) and not isHostValueClass(name) and not Str.startsWith(name, "System.Threading.Tasks.")
}

/// A host array result as the slice of its element: `byte[]` and arrays of host classes that are no Lyric value.
/// This applies only to a result the checker left untyped (`openHostChainTy`): where the checker types the call it
/// types a host array as a slice itself and the chain is not consulted (D444).  `Object[]` is safe to expose here
/// because the slice of host objects keeps the array's own representation (`hostArrayAccepts` takes a host
/// `Object` element for any host value), while an array of a Lyric value (`String[]`, `int[]`) would need an
/// element conversion the builder does not make.
func hostArrayAsSlice(el: in ExternIterElem, targs: in List[Ty]): Option[Ty] {
  match el {
    case EIEHost(_, aargs) -> {
      if aargs.count != 1 {
        return None
      }
      val elemOk = match aargs[0] {
        case EIEPrim(n) -> n == "Byte"
        case EIEHost(n, _) -> isPlainHostResult(n) or isHostObject(n)
        case _ -> false
      }
      if not elemOk {
        return None
      }
      match hostElemTy(aargs[0], targs, TirT.TNever) {
        case Some(t) -> Some(value = TirT.TSlice(t))
        case None -> None
      }
    }
    case _ -> None
  }
}

/// The host class every instance candidate of `name` on `host` with `argc` arguments returns, as a type.
func hostChainResult(
  env: in BuildEnv,
  host: in HostTypeRef,
  name: in String,
  argc: in Int,
  isProperty: in Bool,
  wantStatic: in Bool,
): Option[Ty] {
  val cands = match env.ctx.tbl.externIterResolver[0].resolveMemberSigs(host.name, name, argc, isProperty) {
    case Some(c) -> c
    case None -> return None
  }
  var result: Option[Ty] = None
  for c in cands {
    if c.isStatic != wantStatic {
      return None
    }
    val t = match c.ret {
      case EMTVoid -> tyUnit()
      case EMTType(el) -> match el {
        case EIEHost(rname, _) -> {
          if rname == hostArrayName() {
            // The array the checker types as a slice where it types the call at all: bytes and host
            // objects (`Object[] toArray()`), a slice of them.
            match hostArrayAsSlice(el, host.args) {
              case Some(t) -> t
              case None -> return None
            }
          } else if isHostStringName(rname) {
            // The checker types a host call's string as `String?` (the host may return null).
            TirT.TNullable(TPrim(kind = TPString))
          } else {
            // A result the checker types as a Lyric type (an array as a slice, a boxed number, a task,
            // the root object) is not a plain host class: the checker's own type applies there.
            // The root object of a non-generic host class is the class's own result (`Method.invoke`).
            if not isPlainHostResult(rname) and not (isHostObject(rname) and (host.args.count == 0 or allTypeParams(host.args))) {
              return None
            }
            match hostElemTy(el, host.args, TirT.TNever) {
              case Some(x) -> x
              case None -> return None
            }
          }
        }
        case _ -> return None
      }
    }
    match result {
      case Some(prev) -> if not tyEq(prev, t) { return None }
      case None -> {
        result = Some(value = t)
      }
    }
  }
  result
}

/// Whether every type in `args` is a type parameter: a generic host class applied to the type parameters of
/// the function being built (`HashMap<K, V>` in `func f[K, V](m: in JMap[K, V])`).  The checker has no type for
/// the host's erased `Object` result there, and the host's `Object` is exactly what it returns.
func allTypeParams(args: in List[Ty]): Bool {
  for a in args {
    match a {
      case TParam(_, _) -> ()
      case _ -> return false
    }
  }
  true
}

/// The type of a read of a local whose own type the checker left open at the read (`o` after
/// `val o = None`): the type the local was declared at.
func openLocalTy(env: in BuildEnv, e: in Expr): Option[Ty] {
  match e.kind {
    case EPath(p) -> if p.segments.count == 1 {
      match lookupLocal(env, p.segments[0]) {
        case Some(d) -> if d.id.id >= 0 { Some(value = d.ty) } else { None }
        case None -> None
      }
    } else {
      None
    }
    case _ -> None
  }
}

/// Build the expression `e`, or `None` after recording why in `env.errors`.  An array the checker
/// recorded as a copy site (`arrayCopySites`, D167: an array read out of a place and stored) is
/// wrapped in an `XArrayCopy`; the sites a consumer only inspects were removed from the table.
pub func buildExpr(env: in BuildEnv, e: in Expr): Option[TExpr] {
  match buildExprBody(env, e) {
    case Some(t) -> {
      if env.ctx.tbl.arrayCopySites.containsKey(recordCopySiteKey(e.span)) {
        match t.ty {
          case TArray(_, _) -> return Some(value = TExpr(id = freshNodeId(env), ty = t.ty, span = t.span, kind = XArrayCopy(inner = t)))
          case _ -> ()
        }
      }
      Some(value = t)
    }
    case None -> None
  }
}

func buildExprBody(env: in BuildEnv, e: in Expr): Option[TExpr] {
  val ty = match exprTy(env.ctx, e.nodeId) {
    case Ok(t) -> t
    case Err(msg) -> match mapGet(env.settled, e.nodeId) {
      case Some(t) -> t
      case None -> match openHoleTy(env, e) {
        case Some(t) -> t
        case None -> {
          // A `match` or `if` whose every branch leaves (`return`, `throw`, `break`, `continue`) has no
          // join type to record: it never completes.
          if exprNeverCompletes(e) {
            TirT.TNever
          } else {
            env.errors.add(msg + " (at " + toString(e.span.startPos.line) + ":" + toString(e.span.startPos.column) + ")")
            return None
          }
        }
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
            // A local bound to a host result the checker leaves unchecked (`val v = m.computeIfAbsent(..)`,
            // the host's `Object`) is read at the type its context wants (docs/01 section 2.11): the read
            // takes the same conversion the call would have.
            // A host string the call typed `String?` is read as the `String` the context wants
            // (`val path = exchange.getRequestPath()`, then `Request(path = path)`).
            if not tyEq(d.ty, ty) and (hostResultIsCallType(d.ty, ty) or hostStringReadAsString(d.ty, ty)) {
              val inner = TExpr(id = freshNodeId(env), ty = d.ty, span = e.span, kind = XLocal(local = d.id))
              return Some(value = mkExpr(e, ty, XConvert(kind = CvFromHost, inner = inner)))
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
    case EPropagate(inner) -> {
      match propagateOperandTy(env, inner, ty) {
        case Some(ot) -> settleHole(env, inner, ot)
        case None -> ()
      }
      match buildExpr(env, inner) {
        case Some(t) -> Some(value = mkExpr(e, ty, XPropagate(inner = t)))
        case None -> None
      }
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
      // `a + b` on a record that derives `Add`/`Sub` is applied field by field (D155): the AST
      // lowering does that, and TIR has no node for it yet, so the body stays counted.
      if env.ctx.tbl.recordArithSites.containsKey(recordCopySiteKey(e.span)) {
        return uncoveredExpr(env, e, "record arithmetic")
      }
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
                buildDeclaredBinary(env, e, ty, iop, lt, rt)
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
    case EMember(r, name) -> match refSite(env.ctx, e.nodeId) {
      // `Type.Case`: the checker resolved the member to a case (D477).
      case Some(_) -> buildRefPath(env, e, ty)
      case None -> buildFieldRead(env, e, ty, r, name)
    }
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
    case EForall(binders, whereExpr, body, _) -> buildQuantifier(env, e, ty, binders, whereExpr, body, true)
    case EExists(binders, whereExpr, body, _) -> buildQuantifier(env, e, ty, binders, whereExpr, body, false)
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

/// The locals a built pattern declares, in order; an or-pattern's first alternative stands for all.
func patDecls(p: in TPat, into: in List[LocalDecl]): Unit {
  match p.kind {
    case TpBind(d, inner) -> {
      into.add(d)
      match inner {
        case Some(ip) -> patDecls(ip, into)
        case None -> ()
      }
    }
    case TpCtor(_, args) -> {
      for a in args {
        patDecls(a, into)
      }
    }
    case TpRecord(_, fields) -> {
      for f in fields {
        patDecls(f.pat, into)
      }
    }
    case TpTuple(elems) -> {
      for a in elems {
        patDecls(a, into)
      }
    }
    case TpTypeTest(inner, _) -> patDecls(inner, into)
    case TpOr(alts) -> {
      if alts.count > 0 {
        patDecls(alts[0], into)
      }
    }
    case _ -> ()
  }
}

func orBoundLocal(env: in BuildEnv, name: in String, ty: in Ty): Option[LocalDecl] {
  for d in env.orBound {
    if d.name == name and tyEq(d.ty, ty) {
      return Some(value = d)
    }
  }
  None
}

/// The type of the field `fname` of the record a pattern matches, as the checker gave it to
/// the shorthand binding `Rec(fname)`.
func shorthandFieldTy(env: in BuildEnv, p: in Pattern, fname: in String): Option[Ty] {
  val raw = match mapGet(env.ctx.tbl.patTypes, p.nodeId) { case Some(t) -> t; case None -> return None }
  match unrefine(raw) {
    case TyUser(tid, _, targs) -> {
      for fe in fieldsOfRecordInstantiated(env.ctx.tbl, tid, targs) {
        if fe.name == fname {
          return match tyOfType(env.ctx, fe.ty) { case Ok(t) -> Some(value = t); case Err(_) -> None }
        }
      }
      None
    }
    case _ -> None
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

/// The scrutinee's type fixes the type of each pattern that matches it, for a pattern the checker
/// left untyped because the scrutinee's own type was open (`val o = None; match o { case Some(v) -> v }`):
/// a tuple pattern's elements take the tuple's, a constructor pattern's arguments the case's payload
/// types at the union's arguments.
func settlePattern(env: in BuildEnv, p: in Pattern, ty: in Ty): Unit {
  if not env.settled.containsKey(p.nodeId) {
    env.settled.add(p.nodeId, ty)
  }
  match p.kind {
    case PParen(inner) -> settlePattern(env, inner, ty)
    case PTuple(ps) -> match ty {
      case TTuple(ts) -> if ps.count == ts.count {
        var i = 0
        while i < ps.count {
          settlePattern(env, ps[i], ts[i])
          i = i + 1
        }
      }
      case _ -> ()
    }
    case PConstructor(_, args) -> match ty {
      case TNamed(parent, targs) -> match patSym(env.ctx, p.nodeId) {
        case Some(cs) -> {
          noteCaseSym(env, cs)
          match mapGet(env.syms, cs.id) {
            case Some(en) -> match en.sig {
              case Some(sg) -> if sg.params.count == args.count {
                var i = 0
                while i < args.count {
                  settlePattern(env, args[i], substOwnerArgs(sg.params[i].ty, parent, targs))
                  i = i + 1
                }
              }
              case None -> ()
            }
            case None -> ()
          }
        }
        case None -> ()
      }
      case _ -> ()
    }
    case _ -> ()
  }
}

/// Build a pattern, declaring the locals it binds in the innermost scope.
func buildPat(env: in BuildEnv, p: in Pattern): Option[TPat] {
  val ty = match patTy(env.ctx, p.nodeId) {
    case Ok(t) -> t
    case Err(msg) -> match mapGet(env.settled, p.nodeId) {
      case Some(t) -> t
      case None -> {
        env.errors.add(msg + " (at " + toString(p.span.startPos.line) + ":" + toString(p.span.startPos.column) + ")")
        return None
      }
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
      val d = match orBoundLocal(env, name, ty) { case Some(x) -> x; case None -> declareLocal(env, name, ty, false) }
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
          Some(value = mkPat(p, ty, TpCtor(sym = sym, args = ts)))
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
            case RPFShort(fname, fsp) -> match recordFieldPos(env.ctx, sym, fname) {
              case Some(ix) -> match shorthandFieldTy(env, p, fname) {
                case Some(fty) -> {
                  val d = match orBoundLocal(env, fname, fty) { case Some(x) -> x; case None -> declareLocal(env, fname, fty, false) }
                  val bpat = TPat(id = freshNodeId(env), ty = fty, span = fsp, kind = TpBind(decl = d, inner = None))
                  fps.add(TFieldPat(field = FieldRef(owner = sym, name = fname, index = ix), pat = bpat))
                }
                case None -> return uncoveredPat(env, p, "a shorthand record pattern field the builder cannot type")
              }
              case None -> return uncoveredPat(env, p, "a record pattern field the builder cannot place")
            }
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
      // Every alternative binds the same names: the first declares the locals and the others
      // bind those same locals.
      val built: List[TPat] = newList()
      val outer: List[LocalDecl] = newList()
      for d in env.orBound {
        outer.add(d)
      }
      var failed = false
      for a in alts {
        match buildPat(env, a) {
          case Some(t) -> {
            built.add(t)
            if built.count == 1 {
              env.orBound.clear()
              patDecls(t, env.orBound)
              for d in outer {
                env.orBound.add(d)
              }
            }
          }
          case None -> {
            failed = true
          }
        }
      }
      env.orBound.clear()
      for d in outer {
        env.orBound.add(d)
      }
      if failed {
        return None
      }
      Some(value = mkPat(p, ty, TpOr(alts = built)))
    }
    // `case x is T`: the checker types the inner pattern at the tested type `T`, so that
    // type is the test's.
    case PTypeTest(inner, _) -> match buildPat(env, inner) {
      case Some(ip) -> Some(value = mkPat(p, ty, TpTypeTest(inner = ip, ty = ip.ty)))
      case None -> None
    }
    case PConstRef(_) -> match refSite(env.ctx, p.nodeId) {
      case Some(r) -> {
        noteGlobalSym(env, r.sym, ty)
        Some(value = mkPat(p, ty, TpConst(sym = r.sym)))
      }
      case None -> uncoveredPat(env, p, "a constant pattern the checker did not resolve")
    }
    case PError -> uncoveredPat(env, p, "an error pattern")
  }
}

func buildMatch(env: in BuildEnv, e: in Expr, ty: in Ty, scrut: in Expr, arms: in List[MatchArm]): Option[TExpr] {
  val proved = match matchProved(env.ctx, e.nodeId) {
    case Some(b) -> b
    case None -> return uncoveredExpr(env, e, "a match the checker recorded no verdict for")
  }
  // A scrutinee that leaves a type argument open (`match (None, 5)`) has the type the checker
  // resolved from the arms' uses (`resolveOpenBindingSites`).
  match mapGet(env.ctx.tbl.localBindingTypeSites, recordCopySiteKey(scrut.span)) {
    case Some(te) -> match annotatedTy(env, te) { case Some(w) -> settleHole(env, scrut, w); case None -> () }
    case None -> ()
  }
  val s = buildExpr(env, scrut)
  val tarms: List[TArm] = newList()
  var ok = true
  for arm in arms {
    match s {
      case Some(st) -> settlePattern(env, arm.pattern, st.ty)
      case None -> ()
    }
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
  // A tuple's elements take the tuple's element types (`(None, 5)` as `(Option[Int], Int)`).
  match x.kind {
    case ETuple(xs) -> match ty {
      case TTuple(ts) -> if xs.count == ts.count {
        var i = 0
        while i < xs.count {
          settleHole(env, xs[i], ts[i])
          i = i + 1
        }
      }
      case _ -> ()
    }
    case EParen(inner) -> settleHole(env, inner, ty)
    case _ -> ()
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
      case STry(body, catches, fin) -> if last and not unitBlock and known.isSome() {
        match buildTryValue(env, s, body, catches, fin, known, stmts) {
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

/// Whether the last statement of `b` is a `try` statement.
func blockEndsInTry(b: in Block): Bool {
  if b.statements.count == 0 {
    return false
  }
  match b.statements[b.statements.count - 1].kind {
    case STry(_, _, _) -> true
    case _ -> false
  }
}

/// A block of a value-yielding `try`, typed Unit: the block's tail value is assigned to `local`
/// instead, so the value reaches the code after the `try` statement.  A block that never
/// completes assigns nothing.
func tryValueBlock(env: in BuildEnv, b: in Block, ty: in Ty, local: in LocalDecl): Option[TExpr] {
  settleBlockTail(env, b, ty)
  val built = match buildBlock(env, b, Some(value = ty), freshNodeId(env)) {
    case Some(t) -> t
    case None -> return None
  }
  match built.kind {
    case XBlock(stmts, Some(tail)) -> match coerceBranch(env, tail, ty) {
      case Some(v) -> {
        val place = TPlace(ty = ty, kind = PlLocal(local = local.id))
        // A tail that never completes (a `panic`) has nothing to assign: it stays a statement.
        val last = match v.ty {
          case TNever -> v
          case _ -> TExpr(
            id = freshNodeId(env),
            ty = tyUnit(),
            span = v.span,
            kind = XAssign(place = place, op = AkSet, value = v)
          )
        }
        val all: List[TStmt] = newList()
        for st in stmts {
          all.add(st)
        }
        all.add(TStmt(id = freshNodeId(env), span = v.span, kind = TsExpr(expr = last)))
        Some(value = TExpr(id = built.id, ty = tyUnit(), span = built.span, kind = XBlock(stmts = all, tail = None)))
      }
      case None -> None
    }
    case XBlock(stmts, None) -> if neverCompletes(built) {
      Some(value = TExpr(id = built.id, ty = tyUnit(), span = built.span, kind = built.kind))
    } else {
      noteUncoveredAt(env, "a try block that yields no value", built.span)
      env.errors.add("I0002: the builder has no case for a try block that yields no value")
      None
    }
    case _ -> None
  }
}

/// A `try` that ends a non-Unit block yields the value of its body, or of the catch that ran:
/// a `var` of the block's type is declared before the `try`, the body and each catch assign
/// their tail value to it, and the block's value is that local.  `try` stays a statement in TIR.
func buildTryValue(
  env: in BuildEnv,
  s: in Statement,
  body: in Block,
  catches: in List[CatchClause],
  fin: in Option[Block],
  known: in Option[Ty],
  stmts: in List[TStmt],
): Option[TExpr] {
  val ty = match known { case Some(k) -> k; case None -> return None }
  val local = declareLocal(env, "__try" + toString(env.nextLocal[0] + 1), ty, true)
  val tb = match tryValueBlock(env, body, ty, local) { case Some(x) -> x; case None -> return None }
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
    val built = tryValueBlock(env, c.body, ty, local)
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
  stmts.add(TStmt(id = freshNodeId(env), span = s.span, kind = TsVar(decl = local, init = None)))
  stmts.add(stmtOf(s, TsTry(body = tb, catches = tcs, finallyBody = tfin)))
  Some(value = TExpr(id = freshNodeId(env), ty = ty, span = s.span, kind = XLocal(local = local.id)))
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
      if env.ctx.tbl.recordArithSites.containsKey(recordCopySiteKey(s.span)) {
        return uncoveredStmt(env, s, "record arithmetic")
      }
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
    case SInvariant(x) -> match buildExpr(env, x) {
      case Some(t) -> Some(value = stmtOf(s, TsInvariant(expr = t)))
      case None -> None
    }
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
            // An array has no uninitialised state: the checker records its zero value (D167).
            val zero: Option[TExpr] = match want {
              case TArray(_, _) -> if env.ctx.tbl.arrayZeroSites.containsKey(recordCopySiteKey(s.span)) {
                Some(value = TExpr(id = freshNodeId(env), ty = want, span = s.span, kind = XZeroValue(ty = want)))
              } else {
                None
              }
              case _ -> None
            }
            Some(value = stmtOf(s, TsVar(decl = d, init = zero)))
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
func buildInit(env: in BuildEnv, s: in Statement, ann0: in Option[TypeExpr], init: in Expr): Option[TExpr] {
  // A binding with no annotation whose initializer leaves a type argument open (`val o = None`)
  // has the type the checker resolved from the uses of the name (`resolveOpenBindingSites`).
  val ann: Option[TypeExpr] = match ann0 {
    case Some(_) -> ann0
    case None -> mapGet(env.ctx.tbl.localBindingTypeSites, recordCopySiteKey(init.span))
  }
  // The annotation is the type the initializer's position gives it, for an expression the checker
  // left with an open type argument (`val xs: List[K] = newListWithCapacity(n)`).
  val wanted: Option[Ty] = match ann {
    case Some(te) -> match annotatedTy(env, te) {
      case Some(w) -> Some(value = w)
      case None -> return None
    }
    case None -> None
  }
  match wanted {
    case Some(w) -> settleHole(env, init, w)
    case None -> ()
  }
  val t = match buildExpr(env, init) { case Some(x) -> x; case None -> return None }
  match wanted {
    case None -> Some(value = t)
    case Some(want) -> {
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
  settlePattern(env, pat, t.ty)
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
  body: Option[TExpr]
  barrier: Option[TExpr] = None
}

/// `mode` 1 builds the signature half alone (symbol, type parameters, parameters, return type),
/// leaving defaults, contracts and body unbuilt: the description of a member whose body does not
/// build.  Mode 2 adds the parameters' defaults, each left out on its own when it does not build.
func buildFnCore(
  env: in BuildEnv, fn: in FunctionDecl, tbl: in SymbolTable, wantSym: in Bool, mode: in Int
): Option[FnCore] {
  val sigOnly = mode != 0
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
  env.valueParams.clear()
  match sym {
    case Some(sy) -> {
      val values = valueGenericNames(fn.generics)
      if env.memberOwner.count > 0 {
        for v in env.memberOwner[0].valueNames {
          values.add(v)
        }
      }
      var k = 0
      while k < allNames.count {
        if values.contains(allNames[k]) {
          env.valueParams.add(ValueParamRef(name = allNames[k], owner = sy, index = k))
        }
        k = k + 1
      }
    }
    case None -> ()
  }
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
      case Some(dx) -> if mode != 1 {
        match buildExpr(env, dx) {
          case Some(t) -> {
            dflt = Some(value = t)
          }
          case None -> {
            if not sigOnly {
              ok = false
            }
          }
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
  if ok and not sigOnly {
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
  if ok and not sigOnly {
    match fn.body {
      case Some(FBBlock(b)) -> {
        // A body that ends in a `try` takes the declared return type, so the `try` can yield its value.
        // A generator's body is `Unit`: its `yield`s carry the values.
        val known: Option[Ty] = if not isUnitTy(ret) and not functionIsGenerator(fn) and blockEndsInTry(b) {
          Some(value = ret)
        } else {
          None
        }
        res = buildBlock(env, b, known, freshNodeId(env))
      }
      case Some(FBExpr(x)) -> {
        res = buildExpr(env, x)
      }
      case None -> ()
    }
    // The body is the function's value: it meets the declared return type through a
    // conversion the types alone derive, or the build counts the one it cannot.
    if not isUnitTy(ret) and not functionIsGenerator(fn) {
      match res {
        case Some(b) -> {
          res = coerceBranch(env, b, ret)
        }
        case None -> ()
      }
    }
  }
  popScope(env)
  if sigOnly {
    if not ok {
      return None
    }
    return Some(
      value = FnCore(
        sym = sym,
        typeNames = allNames,
        params = params,
        ret = ret,
        pre = pre,
        post = post,
        body = None,
        barrier = None
      )
    )
  }
  match res {
    case Some(b) -> Some(
      value = FnCore(
        sym = sym,
        typeNames = allNames,
        params = params,
        ret = ret,
        pre = pre,
        post = post,
        body = Some(value = b),
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
  match buildFnCore(env, fn, tbl, false, 0) {
    case Some(c) -> c.body
    case None -> None
  }
}

/// A function with a body as a `TFnDecl` (docs/70 §6.2): its symbol, type
/// parameters (their bounds are not converted yet), parameters with modes and
/// defaults, return type, contracts as `preconds`/`postconds`, and the body.
pub func buildFnDecl(env: in BuildEnv, fn: in FunctionDecl, tbl: in SymbolTable): Option[TFnDecl] {
  buildFnDeclWith(env, fn, tbl, 0)
}

/// A function's signature as a body-less `TFnDecl`: what describes a function whose body does not build.
pub func buildFnSigDecl(env: in BuildEnv, fn: in FunctionDecl, tbl: in SymbolTable): Option[TFnDecl] {
  buildFnDeclWith(env, fn, tbl, 1)
}

/// A function's signature with the defaults of its parameters, as a body-less `TFnDecl`: the defaults a
/// package interface carries.  A default that does not build is `None` on its own parameter.
pub func buildFnDefaultsDecl(env: in BuildEnv, fn: in FunctionDecl, tbl: in SymbolTable): Option[TFnDecl] {
  buildFnDeclWith(env, fn, tbl, 2)
}

func buildFnDeclWith(env: in BuildEnv, fn: in FunctionDecl, tbl: in SymbolTable, mode: in Int): Option[TFnDecl] {
  match buildFnCore(env, fn, tbl, true, mode) {
    case Some(c) -> {
      val tps: List[TTypeParam] = newList()
      val values = valueGenericNames(fn.generics)
      if env.memberOwner.count > 0 {
        for v in env.memberOwner[0].valueNames {
          values.add(v)
        }
      }
      for n in c.typeNames {
        tps.add(
          TTypeParam(name = n, bounds = newList(), valueTy = if values.contains(n) { Some(value = tyInt()) } else { None })
        )
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
          body = c.body,
          span = fn.span,
          barrier = c.barrier,
          ownerParamCount = ownerCount,
          isGenerator = functionIsGenerator(fn)
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
  /// One tab-separated line per body, built or not, for the census script to count a body
  /// shared by several programs once (D474); see `bodyCensusLines`.
  bodyLines: List[String] = newList()
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
    pkg = pb.pkg,
    bodyLines = bodyCensusLines(pb)
  )
}

/// The census's per-body lines (D474): `built<TAB>key` for a built body, `unbuilt<TAB>key` for
/// one that did not build, then `kind<TAB>key<TAB>count<TAB>line:column<TAB>kind` for each kind
/// of node an unbuilt body has no case for.  The key is the symbol's DefPath key (`Pkg::name(...)`), or `~name`
/// when the checker has none.
pub func bodyCensusLines(pb: in PackageBuild): List[String] {
  val res: List[String] = newList()
  for fd in pb.pkg.funcs {
    match mapGet(pb.names, fd.sym.id) {
      case Some(k) -> res.add("built\t" + k)
      case None -> ()
    }
  }
  for f in pb.failed {
    val key = match f.path { case Some(k) -> k; case None -> "~" + f.name }
    res.add("unbuilt\t" + key)
    for k in mapKeys(f.uncovered) {
      val n = match mapGet(f.uncovered, k) { case Some(v) -> v; case None -> 0 }
      val at = match mapGet(f.sites, k) { case Some(a) -> a; case None -> "" }
      res.add("kind\t" + key + "\t" + toString(n) + "\t" + at + "\t" + k)
    }
  }
  res
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
/// (docs/01 §4.1: `Byte < Int < Long`, `Byte < UInt < ULong`, `Float < Double`), and `Nat` to
/// `Long` (a `Nat` is a non-negative `Long`, docs/01 §2.1), which a conversion method on a
/// `Nat`-backed subtype yields.
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
          case TPNat -> match t { case TPLong -> true; case _ -> false }
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
  match ffiIntrinsicCall(env, fn) {
    case Some(name) -> return buildBuiltinCall(env, e, ty, name, fn, args)
    case None -> ()
  }
  match buildHostMethodOnString(env, e, ty, fn, args) {
    case Some(r) -> return r
    case None -> ()
  }
  match buildHostMethodOnChain(env, e, ty, fn, args) {
    case Some(r) -> return r
    case None -> ()
  }
  uncoveredExpr(env, e, "a call the checker did not resolve")
}

/// The FFI intrinsics the checker types by name and no table records (`nativeNullPtr()`,
/// `nativeAddrOf(x)`, the byte accessors and callback pins, `externAsObject(x)`, docs/01 §11.6,
/// D158, D212, D229): every backend lowers them by name.
func ffiIntrinsicName(name: in String): Bool {
  name == "nativeNullPtr" or name == "nativeAddrOf" or name == "NativeWeak" or name == "nativeLoadByte" or
    name == "nativeStoreByte" or
    name == "nativeKeepCallback" or
    name == "nativeReleaseCallback" or
    name == "externAsObject"
}

/// The name of the FFI intrinsic `fn` calls: a single bare name that is no local.
func ffiIntrinsicCall(env: in BuildEnv, fn: in Expr): Option[String] {
  match fn.kind {
    case EPath(path) -> if path.segments.count == 1 and ffiIntrinsicName(path.segments[0]) {
      match lookupLocal(env, path.segments[0]) {
        case Some(_) -> None
        case None -> Some(value = path.segments[0])
      }
    } else {
      None
    }
    case _ -> None
  }
}

/// `s.compareTo(t)`, `s.startsWith(p)` and the other host methods a `String` value is called with where the
/// checker records no callee (the host's string is the language's `String`, so the receiver is the value
/// itself): an extern call on whichever host string type declares the method, found through the host
/// metadata.  None, counting nothing, when the callee is not a member of a `String`, the metadata cannot be
/// read, or no host string type declares the member.
func buildHostMethodOnString(
  env: in BuildEnv, e: in Expr, ty: in Ty, fn: in Expr, args: in List[CallArg]
): Option[Option[TExpr]] {
  val tbl = env.ctx.tbl
  if tbl.externIterResolver.count == 0 {
    return None
  }
  val parts = match fn.kind {
    case EMember(recv, name) -> match exprTy(env.ctx, recv.nodeId) {
      case Ok(rt) -> match rt {
        case TPrim(TPString) -> Some(value = name)
        case _ -> None
      }
      case Err(_) -> None
    }
    case _ -> None
  }
  val name = match parts { case Some(n) -> n; case None -> return None }
  val names: List[String] = newList()
  names.add("java.lang.String")
  names.add("System.String")
  for host in names {
    match tbl.externIterResolver[0].resolveMemberSigs(host, name, args.count, false) {
      case Some(_) -> return Some(
        value = buildExternCall(
          env,
          e,
          ty,
          ExternCallSite(hostType = host, targs = newList(), name = name, argCount = args.count),
          fn,
          args
        )
      )
      case None -> ()
    }
  }
  None
}

/// `m.entrySet().iterator()`: a host method called on a host value whose own type the checker left
/// open (`openHostChainTy`), where the checker records no callee.  An extern call on the receiver's host
/// class, found through the host metadata.  None, counting nothing, when the callee is not a member of a
/// host value or the metadata declares no such member.
func buildHostMethodOnChain(
  env: in BuildEnv, e: in Expr, ty: in Ty, fn: in Expr, args: in List[CallArg]
): Option[Option[TExpr]] {
  val tbl = env.ctx.tbl
  if tbl.externIterResolver.count == 0 {
    return None
  }
  val recvAndName = match fn.kind {
    case EMember(recv, name) -> match hostChainReceiver(env, recv) {
      case Some(h) -> Some(
        value = HostChainCall(host = h.host, name = name)
      )
      case None -> None
    }
    case _ -> None
  }
  val hc = match recvAndName {
    case Some(x) -> x
    case None -> match hostMethodOnTypeParam(env, fn, args.count) {
      case Some(x) -> x
      case None -> return None
    }
  }
  // A generic host class takes its type arguments from the checker's site, which a chain has none of.
  if hc.host.args.count > 0 {
    return None
  }
  match tbl.externIterResolver[0].resolveMemberSigs(hc.host.name, hc.name, args.count, false) {
    case Some(_) -> Some(
      value = buildExternCall(
        env,
        e,
        ty,
        ExternCallSite(
          hostType = hc.host.name,
          targs = newList(),
          name = hc.name,
          argCount = args.count
        ),
        fn,
        args
      )
    )
    case None -> None
  }
}

/// `target.getClass()` where `target` has a type parameter's type: the member of the host's root object
/// class the call names, found through the host metadata (the receiver is boxed to it by `buildExternCall`).
/// Both root names are tried, but the metadata resolver is the active target's own (the JVM resolver reads
/// JDK classes, the dotnet one reference assemblies), so only that target's root class resolves.
func hostMethodOnTypeParam(env: in BuildEnv, fn: in Expr, argc: in Int): Option[HostChainCall] {
  match fn.kind {
    case EMember(recv, name) -> match exprTy(env.ctx, recv.nodeId) {
      case Ok(rt) -> match rt {
        case TParam(_, _) -> {
          for obj in ["java.lang.Object", "System.Object"] {
            match env.ctx.tbl.externIterResolver[0].resolveMemberSigs(obj, name, argc, false) {
              case Some(_) -> return Some(value = HostChainCall(host = HostTypeRef(name = obj, args = newList()), name = name))
              case None -> ()
            }
          }
          None
        }
        case _ -> None
      }
      case Err(_) -> None
    }
    case _ -> None
  }
}

/// A host receiver and the member called on it.
record HostChainCall {
  host: HostTypeRef
  name: String
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
        case EPath(path) -> if path.segments.count >= 1 { m } else { return None }
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
  val arg = match built.ty {
    case TPrim(TPLong) -> match uty {
      case TPrim(TPNat) -> convertNode(env, built, uty, CvLongToNat)
      case _ -> match coerceArg(env, built, uty) {
        case Some(c) -> c
        case None -> return Some(value = None)
      }
    }
    case _ -> match coerceArg(env, built, uty) { case Some(c) -> c; case None -> return Some(value = None) }
  }
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
/// 64-bit floating point types as `Float` and `Double`, a host task as the built-in `Task[T]`, an
/// erased generic's `Object` result as the type it is instantiated at (a host class, `String`, `Long`).
/// The call then has the host type and a `CvFromHost` conversion to the checker's type.
pub func hostResultIsCallType(host: in Ty, callTy: in Ty): Bool {
  match host {
    case TExtern(h) -> {
      val n = h.name
      match callTy {
        case TSlice(_) -> n == hostArrayName()
        case TArray(_, _) -> n == hostArrayName()
        // An erased generic's `Object` result instantiated at `String` is a string the host may return null for.
        case TNullable(inner) -> match inner { case TPrim(TPString) -> isHostStringName(n) or isHostObject(n); case _ -> false }
        // A generic member's erased result (`BlockingQueue<HttpExchange>.take()` returns `Object`)
        // is the host class the checker instantiated it at.
        case TExtern(c) -> (n == "java.lang.Object" or n == "System.Object") and c.name != n
        case TPrim(TPString) -> n == "java.lang.Object" or n == "System.Object"
        case TPrim(TPLong) -> n == "java.lang.Object" or n == "System.Object"
        case TPrim(TPBool) -> n == "java.lang.Object" or n == "System.Object"
        case TPrim(TPFloat) -> isHostSingleName(n) or isHostObject(n)
        case TPrim(TPDouble) -> isHostDoubleName(n) or isHostObject(n)
        case TPrim(TPInt) -> n != hostArrayName() and not isHostStringName(n)
        // A host collection's erased `Object` result read as the Lyric record or union stored in it
        // (`val state: RegistryState = registryMap.get(key)`): the checker instantiates the call at the
        // declared type.
        case TNamed(sym, targs) -> (not isBuiltinSymbol(sym) and isHostObject(n)) or
          (isBuiltinSymbol(sym) and targs.count == 1 and h.args.count == 1 and
            (tyEq(h.args[0], targs[0]) or hostResultIsCallType(h.args[0], targs[0])) and
            isHostTaskName(n))
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

/// A `Task[T]` handle is the host's `Task<T>`, which is a host `Task`: passing the handle
/// where the host's non-generic `Task` is expected changes no representation.
func taskAsHostTask(from: in Ty, to: in Ty): Option[ConvKind] {
  match from {
    case TNamed(f, _) -> match to {
      case TExtern(t) -> if symbolIdEq(f, builtinTaskTypeId()) and t.name == "System.Threading.Tasks.Task" {
        Some(value = CvBoxToHost(host = t))
      } else {
        None
      }
      case _ -> None
    }
    case _ -> None
  }
}

/// A host value passed as one of its host supertypes (`HttpClientHandler` for an `HttpMessageHandler`
/// parameter, a `String` for a `CharSequence` one, a record that `impl`s an extern interface for that
/// interface), read from the host's metadata (`resolveBases`).  `object` is boxing, not an upcast.
func hostUpcastKind(env: in BuildEnv, from: in Ty, to: in Ty): Option[ConvKind] {
  match taskAsHostTask(from, to) {
    case Some(k) -> return Some(value = k)
    case None -> ()
  }
  if env.ctx.tbl.externIterResolver.count == 0 {
    return None
  }
  match from {
    case TExtern(f) -> match to {
      case TExtern(t) -> {
        if f.name == t.name or isHostObject(t.name) {
          return None
        }
        match env.ctx.tbl.externIterResolver[0].resolveBases(f.name) {
          case Some(bases) -> {
            for b in bases {
              if b == t.name {
                return Some(value = CvBoxToHost(host = t))
              }
            }
            None
          }
          case None -> None
        }
      }
      case _ -> None
    }
    case TNamed(rsym, _) -> match to {
      case TExtern(t) -> {
        if isHostObject(t.name) {
          return None
        }
        // A Lyric record or union that `impl`s an extern interface passes as that interface.
        for p in env.ctx.tbl.impls {
          if symbolIdEq(p.target, rsym) {
            match symTableExternDeclOf(env.ctx.tbl, p.iface) {
              case Some(d) -> if externHostBase(d.clrName) == t.name { return Some(value = CvBoxToHost(host = t)) }
              case None -> ()
            }
          }
        }
        None
      }
      case _ -> None
    }
    case TPrim(TPString) -> match to {
      case TExtern(t) -> {
        if isHostObject(t.name) {
          return None
        }
        for hostString in ["System.String", "java.lang.String"] {
          match env.ctx.tbl.externIterResolver[0].resolveBases(hostString) {
            case Some(bases) -> {
              for b in bases {
                if b == t.name {
                  return Some(value = CvBoxToHost(host = t))
                }
              }
            }
            case None -> ()
          }
        }
        None
      }
      case _ -> None
    }
    case _ -> None
  }
}

/// The parameters of one overload as `Ty`s matched against the argument types, with
/// the score of the match (2 per exact argument, 1 per widened one), or None when
/// an argument does not fit.
func scoreOverload(
  env: in BuildEnv, sig: in ExternMemberSig, targs: in List[Ty], argTys: in List[Ty]
): Option[OverloadFit] {
  val ps: List[Ty] = newList()
  var score = 0
  var i = 0
  while i < sig.params.count {
    val p = match hostElemTy(sig.params[i], targs, argTys[i]) { case Some(t) -> t; case None -> return None }
    if tyEq(p, argTys[i]) {
      score = score + 2
    } else {
      // The language's own widening beats an integer taken as a floating point type, as the
      // CLR's better-conversion rule prefers `M(Long)` to `M(Double)` for an `Int`.
      match widenKind(argTys[i], p) {
        case Some(_) -> {
          score = score + 1
        }
        case None -> match hostWidenKind(argTys[i], p) {
          case Some(_) -> ()
          // A host subtype passed as its supertype ranks as a widening; boxing and narrowing rank below
          // every widening, as the host's overload resolution has it.
          case None -> match hostUpcastKind(env, argTys[i], p) {
            case Some(_) -> {
              score = score + 1
            }
            case None -> match hostBoxKind(argTys[i], p) {
              case Some(_) -> ()
              case None -> return None
            }
          }
        }
      }
    }
    ps.add(p)
    i = i + 1
  }
  Some(value = OverloadFit(params = ps, score = score))
}

/// A host call's node as the checker typed it: a host string can be null (the checker types the call
/// `String?`, the host's result is the `String`), and a result the checker types as a Lyric type without
/// checking it (D359: an array as a slice, a host enum as `Int`) takes `CvFromHost`.
func hostResultNode(env: in BuildEnv, e: in Expr, ty: in Ty, ret: in Ty, call: in TExprKind): TExpr {
  val nullableString = match ty {
    case TNullable(TPrim(TPString)) -> tyEq(ret, TPrim(kind = TPString))
    case _ -> false
  }
  if nullableString {
    val c = TExpr(id = freshNodeId(env), ty = ret, span = e.span, kind = call)
    return mkExpr(e, ty, XConvert(kind = CvLiftNullable, inner = c))
  }
  if hostResultIsCallType(ret, ty) {
    val c = TExpr(id = freshNodeId(env), ty = ret, span = e.span, kind = call)
    return mkExpr(e, ty, XConvert(kind = CvFromHost, inner = c))
  }
  // The checker settles a host result at the supertype the context expects (`JString.valueOf(x)` returned as
  // a `CharSequence`): the call keeps the host's result type and an upcast gives the checker's.
  if not tyEq(ret, ty) {
    match hostUpcastKind(env, ret, ty) {
      case Some(k) -> {
        val c = TExpr(id = freshNodeId(env), ty = ret, span = e.span, kind = call)
        return mkExpr(e, ty, XConvert(kind = k, inner = c))
      }
      case None -> ()
    }
    // A host result, an array included, read as the host `Object` the context declares
    // (`val o: JObject = tmf.getTrustManagers()`): the call keeps the host's result type.
    match ret {
      case TExtern(r) -> match ty {
        case TExtern(t) -> if isHostObject(t.name) and not isHostObject(r.name) {
          val c = TExpr(id = freshNodeId(env), ty = ret, span = e.span, kind = call)
          return mkExpr(e, ty, XConvert(kind = CvBoxToHost(host = t), inner = c))
        }
        case _ -> ()
      }
      case _ -> ()
    }
    // The checker lets a host result flow into a more specific host type the context declares
    // (`val c: X509Certificate = cf.generateCertificate(in)`): the host's result is the base class.
    if hostResultNarrowsTo(env, ret, ty) {
      val c = TExpr(id = freshNodeId(env), ty = ret, span = e.span, kind = call)
      return mkExpr(e, ty, XConvert(kind = CvFromHost, inner = c))
    }
  }
  mkExpr(e, ty, call)
}

/// Whether `to` is a host class that has the host class `from` among its bases.
func hostResultNarrowsTo(env: in BuildEnv, from: in Ty, to: in Ty): Bool {
  if env.ctx.tbl.externIterResolver.count == 0 {
    return false
  }
  match from {
    case TExtern(f) -> match to {
      case TExtern(t) -> {
        if f.name == t.name {
          return false
        }
        match env.ctx.tbl.externIterResolver[0].resolveBases(t.name) {
          case Some(bases) -> {
            for b in bases {
              if b == f.name {
                return true
              }
            }
            false
          }
          case None -> false
        }
      }
      case _ -> false
    }
    case _ -> false
  }
}

/// An argument converted to the host parameter type `want`: the host's widening, boxing and narrowing, or
/// the language's own conversions.
func hostArgConv(env: in BuildEnv, arg: in TExpr, want: in Ty): Option[TExpr] {
  match hostWidenKind(arg.ty, want) {
    case Some(k) -> if tyEq(arg.ty, want) { Some(value = arg) } else { Some(value = convertNode(env, arg, want, k)) }
    case None -> match hostUpcastKind(env, arg.ty, want) {
      case Some(k) -> Some(value = convertNode(env, arg, want, k))
      case None -> match hostBoxKind(arg.ty, want) {
        case Some(k) -> Some(value = convertNode(env, arg, want, k))
        case None -> coerceArg(env, arg, want)
      }
    }
  }
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
  // A call through a value (`recv.m(x)`) takes an instance overload: a same-named static one is
  // passed over unless no instance overload fits (D479, the rule #6765 gave the emit path).
  val viaValue = match exprTy(env.ctx, recvExpr.nodeId) {
    case Ok(rty) -> match rty { case TExtern(_) -> true; case TPrim(TPString) -> true; case _ -> false }
    case Err(_) -> false
  }
  var pass = 0
  while pass < 2 and not isSome(bestSig) {
    for c in cands {
      if c.params.count == argTys.count and not (pass == 0 and viaValue and c.isStatic) {
        match scoreOverload(env, c, targs, argTys) {
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
    pass = pass + 1
  }
  val sig = match bestSig {
    case Some(c) -> c
    case None -> {
      val tys: List[String] = newList()
      for t in argTys {
        tys.add(renderTy(t))
      }
      var shown = ""
      for i in 0 ..< tys.count {
        shown = shown + (if i > 0 { ", " } else { "" }) + tys[i]
      }
      return uncoveredExprDetail(
        env,
        e,
        "an extern call no host overload fits",
        site.hostType + "." + site.name + "(" + shown + ")"
      )
    }
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
    // The host's string is the language's `String`, so a `String` value is its own receiver.
    // A value of the host's string class (`JString.valueOf(s)`, typed at its `extern type`) is its own receiver too.
    val receiverIsHostString = match rt.ty { case TExtern(h) -> isHostStringName(h.name); case _ -> false }
    val want = if receiverIsHostString {
      rt.ty
    } else if isHostStringName(site.hostType) {
      TPrim(kind = TPString)
    } else {
      TExtern(host = owner)
    }
    // A value of a type parameter's type is the host's root object for a call of one of its members.
    val recvArg = if tyEq(rt.ty, want) {
      rt
    } else if isHostObject(site.hostType) and (match rt.ty { case TParam(_, _) -> true; case _ -> false }) {
      convertNode(env, rt, want, CvBoxToHost(host = owner))
    } else {
      return uncoveredExpr(env, e, "an extern call on a receiver that is not the host type itself")
    }
    params.add(TParamTy(mode = TMIn, ty = want))
    targsOut.add(TArgIn(value = recvArg))
  }
  var i = 0
  while i < built.count {
    val want = bestParams[i]
    params.add(TParamTy(mode = TMIn, ty = want))
    val c = match hostArgConv(env, built[i], want) { case Some(x) -> x; case None -> return None }
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
  Some(value = hostResultNode(env, e, ty, ret, XCall(callee = Extern(member = member), args = targsOut)))
}

/// The host type a value of type `t` is, and its resolver, when the host metadata can be read.
func hostOf(env: in BuildEnv, t: in Ty): Option[HostTypeRef] {
  if env.ctx.tbl.externIterResolver.count == 0 {
    return None
  }
  match t {
    case TExtern(h) -> Some(value = h)
    case _ -> None
  }
}

/// `recv.name` where `recv` is a host value and `name` one of its properties or public fields: a call of the
/// getter (or a read of the field) with the receiver first.  None, counting nothing, when the host metadata has
/// no such instance member or its result is not one the checker's type fits.
func buildHostPropertyRead(env: in BuildEnv, e: in Expr, ty: in Ty, rt: in TExpr, name: in String): Option[TExpr] {
  val host = match hostOf(env, rt.ty) { case Some(h) -> h; case None -> return None }
  val cands = match env.ctx.tbl.externIterResolver[0].resolveMemberSigs(host.name, name, 0, true) {
    case Some(c) -> c
    case None -> return None
  }
  var found: Option[ExternMemberSig] = None
  for c in cands {
    if not c.isStatic and c.params.count == 0 and not isSome(found) {
      found = Some(value = c)
    }
  }
  val sig = match found { case Some(c) -> c; case None -> return None }
  val ret = match sig.ret {
    case EMTType(el) -> match hostElemTy(el, host.args, ty) { case Some(t) -> t; case None -> return None }
    case EMTVoid -> return None
  }
  val nullableString = match ty {
    case TNullable(TPrim(TPString)) -> tyEq(ret, TPrim(kind = TPString))
    case _ -> false
  }
  if not tyEq(ret, ty) and not nullableString and not hostResultIsCallType(ret, ty) {
    return None
  }
  val params: List[TParamTy] = newList()
  params.add(TParamTy(mode = TMIn, ty = rt.ty))
  val member = HostMemberRef(
    owner = host,
    name = name,
    kind = if sig.isField { HMFieldGet } else { HMPropertyGet },
    isStatic = false,
    params = params,
    ret = ret
  )
  val args: List[TArg] = newList()
  args.add(TArgIn(value = rt))
  Some(value = hostResultNode(env, e, ty, ret, XCall(callee = Extern(member = member), args = args)))
}

/// `JCharacter.TYPE`: a read of a static field or property of the host class an `extern type` names, where the
/// checker records no type.  None, counting nothing, when `recv` names no such type, the host metadata has no
/// such static member, or its result is not one the checker's type fits.
func buildHostStaticRead(env: in BuildEnv, e: in Expr, ty: in Ty, recv: in Expr, name: in String): Option[TExpr] {
  if env.ctx.tbl.externIterResolver.count == 0 {
    return None
  }
  match exprTy(env.ctx, recv.nodeId) {
    case Ok(_) -> return None
    case Err(_) -> ()
  }
  val host = match hostStaticReceiver(env, recv) { case Some(h) -> h; case None -> return None }
  val cands = match env.ctx.tbl.externIterResolver[0].resolveMemberSigs(host.name, name, 0, true) {
    case Some(c) -> c
    case None -> return None
  }
  var found: Option[ExternMemberSig] = None
  for c in cands {
    if c.isStatic and c.params.count == 0 and not isSome(found) {
      found = Some(value = c)
    }
  }
  val sig = match found { case Some(c) -> c; case None -> return None }
  val ret = match sig.ret {
    case EMTType(el) -> match hostElemTy(el, host.args, ty) { case Some(t) -> t; case None -> return None }
    case EMTVoid -> return None
  }
  val nullableString = match ty {
    case TNullable(TPrim(TPString)) -> tyEq(ret, TPrim(kind = TPString))
    case _ -> false
  }
  if not tyEq(ret, ty) and not nullableString and not hostResultIsCallType(ret, ty) {
    return None
  }
  val member = HostMemberRef(
    owner = host,
    name = name,
    kind = if sig.isField { HMFieldGet } else { HMPropertyGet },
    isStatic = true,
    params = newList(),
    ret = ret
  )
  Some(value = hostResultNode(env, e, ty, ret, XCall(callee = Extern(member = member), args = newList())))
}

/// Whether the checker typed `r` as a host value.
func isHostValue(env: in BuildEnv, r: in Expr): Bool {
  match exprTy(env.ctx, r.nodeId) {
    case Ok(t) -> match t { case TExtern(_) -> true; case _ -> false }
    case Err(_) -> false
  }
}

/// `recv.name = value` where `recv` is a host value: a call of the property's setter, or a write of
/// the public field of that name, `recv` and then the value converted to the parameter, of type
/// `Unit`.  A compound assignment (`recv.n += 1`) binds the receiver once and reads, applies the
/// operator and writes (D478).  A member the metadata gives neither a setter nor a field for is counted.
func buildHostPropertySet(
  env: in BuildEnv,
  e: in Expr,
  target: in Expr,
  recv: in Expr,
  name: in String,
  op: in AssignOp,
  value: in Expr,
): Option[TExpr] {
  val rt = match buildExpr(env, recv) { case Some(t) -> t; case None -> return None }
  val shown = renderTy(rt.ty) + "." + name
  val kind = "an assignment to a member that is not a record field"
  val host = match hostOf(env, rt.ty) {
    case Some(h) -> h
    case None -> return uncoveredExprDetail(env, target, kind, shown)
  }
  match op {
    case AssEq -> {
      val vt = match buildExpr(env, value) { case Some(t) -> t; case None -> return None }
      hostWriteCall(env, e, target, rt, host, name, vt, NodeId(id = e.nodeId), e.span)
    }
    case _ -> buildHostCompoundSet(env, e, target, rt, host, name, op, value)
  }
}

/// `recv.name op= value`: `{ val r = recv; r.name = r.name op value }`, the receiver evaluated once.
func buildHostCompoundSet(
  env: in BuildEnv,
  e: in Expr,
  target: in Expr,
  rt: in TExpr,
  host: in HostTypeRef,
  name: in String,
  op: in AssignOp,
  value: in Expr,
): Option[TExpr] {
  val shown = renderTy(rt.ty) + "." + name
  val kind = "an assignment to a member that is not a record field"
  val pty = match exprTy(env.ctx, target.nodeId) {
    case Ok(t) -> t
    case Err(_) -> return uncoveredExprDetail(env, target, kind, shown + " (a compound assignment to a member the checker did not type)")
  }
  val bop = match op {
    case AssPlus -> IoAdd
    case AssMinus -> IoSub
    case AssStar -> IoMul
    case AssSlash -> IoDiv
    case AssPercent -> IoMod
    case AssEq -> return None
  }
  if not isPrimTy(pty) {
    return uncoveredExprDetail(env, target, kind, shown + " (a compound assignment to a member that is not a primitive)")
  }
  val d = declareLocal(env, "__hostrecv" + toString(env.nextLocal[0] + 1), rt.ty, false)
  val bindPat = TPat(id = freshNodeId(env), ty = rt.ty, span = rt.span, kind = TpBind(decl = d, inner = None))
  val recvStmt = TStmt(id = freshNodeId(env), span = rt.span, kind = TsLet(pat = bindPat, init = rt))
  val readRecv = TExpr(id = freshNodeId(env), ty = rt.ty, span = rt.span, kind = XLocal(local = d.id))
  val current = match buildHostPropertyRead(env, target, pty, readRecv, name) {
    case Some(c) -> c
    case None -> return uncoveredExprDetail(env, target, kind, shown + " (the read half of a compound assignment)")
  }
  val vt = match buildExpr(env, value) { case Some(t) -> t; case None -> return None }
  val appended = match op {
    case AssPlus -> match pty { case TPrim(TPString) -> stringPart(env, vt); case _ -> vt }
    case _ -> vt
  }
  val rhs = match coerceArg(env, appended, pty) { case Some(c) -> c; case None -> return None }
  val operands: List[TExpr] = newList()
  operands.add(current)
  operands.add(rhs)
  val combined = TExpr(id = freshNodeId(env), ty = pty, span = e.span, kind = intrinsicCall(bop, operands))
  val writeRecv = TExpr(id = freshNodeId(env), ty = rt.ty, span = rt.span, kind = XLocal(local = d.id))
  val write = match hostWriteCall(env, e, target, writeRecv, host, name, combined, freshNodeId(env), e.span) {
    case Some(w) -> w
    case None -> return None
  }
  val stmts: List[TStmt] = newList()
  stmts.add(recvStmt)
  Some(value = mkExpr(e, tyUnit(), XBlock(stmts = stmts, tail = Some(value = write))))
}

/// The call that writes `vt` to the member `name` of the host value `rt`: the property's setter
/// (`set_<name>`), else the public field of that name.  `node` is the call's own node id.
func hostWriteCall(
  env: in BuildEnv,
  e: in Expr,
  target: in Expr,
  rt: in TExpr,
  host: in HostTypeRef,
  name: in String,
  vt: in TExpr,
  node: in NodeId,
  span: in Span,
): Option[TExpr] {
  val shown = renderTy(rt.ty) + "." + name
  val kind = "an assignment to a member that is not a record field"
  val resolver = env.ctx.tbl.externIterResolver[0]
  var kindOf = HMPropertySet
  var found: Option[ExternMemberSig] = None
  match resolver.resolveMemberSigs(host.name, "set_" + name, 1, false) {
    case Some(cands) -> {
      for c in cands {
        if not c.isStatic and c.params.count == 1 and not isSome(found) {
          found = Some(value = c)
        }
      }
    }
    case None -> ()
  }
  var want: Option[Ty] = None
  match found {
    case Some(sig) -> {
      want = hostElemTy(sig.params[0], host.args, vt.ty)
    }
    case None -> match resolver.resolveMemberSigs(host.name, name, 0, true) {
      case Some(cands) -> {
        for c in cands {
          if c.isField and not c.isStatic and c.params.count == 0 and not isSome(found) {
            found = Some(value = c)
          }
        }
        match found {
          case Some(sig) -> match sig.ret {
            case EMTType(el) -> {
              kindOf = HMFieldSet
              want = hostElemTy(el, host.args, vt.ty)
            }
            case EMTVoid -> ()
          }
          case None -> ()
        }
      }
      case None -> ()
    }
  }
  if not isSome(found) {
    return uncoveredExprDetail(env, target, kind, shown + " (no setter or public field)")
  }
  val ty = match want {
    case Some(t) -> t
    case None -> return uncoveredExprDetail(env, target, kind, shown + " (a member type the builder cannot type)")
  }
  val v = match hostArgConv(env, vt, ty) { case Some(x) -> x; case None -> return None }
  val params: List[TParamTy] = newList()
  params.add(TParamTy(mode = TMIn, ty = rt.ty))
  params.add(TParamTy(mode = TMIn, ty = ty))
  val member = HostMemberRef(
    owner = host,
    name = name,
    kind = kindOf,
    isStatic = false,
    params = params,
    ret = tyUnit()
  )
  val args: List[TArg] = newList()
  args.add(TArgIn(value = rt))
  args.add(TArgIn(value = v))
  Some(
    value = TExpr(id = node, ty = tyUnit(), span = span, kind = XCall(callee = Extern(member = member), args = args))
  )
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
      var k = 0
      for fd in ownOpaqueFields(env.ctx.tbl, sym) {
        if fd.name == name {
          return Some(value = FieldRef(owner = sym, name = name, index = k))
        }
        k = k + 1
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
  match buildHostStaticRead(env, e, ty, recv, name) {
    case Some(x) -> return Some(value = x)
    case None -> ()
  }
  val rt = match buildExpr(env, recv) { case Some(t) -> t; case None -> return None }
  match fieldRefOf(env, rt.ty, name) {
    case Some(f) -> Some(value = mkExpr(e, ty, XField(recv = rt, field = f)))
    case None -> match buildHostPropertyRead(env, e, ty, rt, name) {
      case Some(x) -> Some(value = x)
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
        case None -> match buildAccessorCall(env, e, ty, rt, name) {
          case Some(x) -> Some(value = x)
          case None -> uncoveredExprDetail(
            env,
            e,
            "a member access that is not a record field",
            renderTy(rt.ty) + "." + name
          )
        }
      }
    }
  }
}

/// The member forms that read a value through no field: `d.value` of a distinct type is the
/// value unwrapped, and `o.isSome` / `o.isNone` / `r.isOk` / `r.isErr` on a `Std.Core` `Option`
/// or `Result` is the call of the module's function of that name, recorded by the checker
/// under the member's node (D463).
func buildAccessorCall(env: in BuildEnv, e: in Expr, ty: in Ty, rt: in TExpr, name: in String): Option[TExpr] {
  val tbl = env.ctx.tbl
  match rt.ty {
    case TNamed(did, targs) -> if name == "value" and targs.count == 0 {
      val isDistinct = match symbolOfDefId(tbl, did) {
        case Some(s) -> match s.kind { case DKDistinctType(_, _) -> true; case _ -> false }
        case None -> false
      }
      if isDistinct {
        return Some(value = mkExpr(e, ty, XConvert(kind = CvUnwrapDistinct(sym = did), inner = rt)))
      }
    }
    case _ -> ()
  }
  match mapGet(tbl.callSigByNode, e.nodeId) {
    case Some(sig) -> match mapGet(tbl.calleeByNode, e.nodeId) {
      case Some(sym) -> match mapGet(tbl.genericArgsByNode, e.nodeId) {
        case Some(cargs) -> {
          val tyArgs: List[Ty] = newList()
          for ta in cargs {
            match tyOfType(env.ctx, ta) {
              case Ok(t) -> tyArgs.add(t)
              case Err(msg) -> {
                env.errors.add(msg)
                return None
              }
            }
          }
          noteFuncSym(env, sym, sig, None, None, TSkFunc)
          return Some(
            value = mkExpr(e, ty, XCall(callee = Direct(sym = sym, typeArgs = tyArgs), args = inArgs(singleTExpr(rt))))
          )
        }
        case None -> ()
      }
      case None -> ()
    }
    case None -> ()
  }
  None
}

func singleTExpr(t: in TExpr): List[TExpr] {
  val xs: List[TExpr] = newList()
  xs.add(t)
  xs
}

/// Whether `name` is the contract projection of the real `Std.Core` `Result` (`value`, `error`) or `Option`
/// (`value`): a read of the payload of the `Ok`, `Err` or `Some` case that holds the receiver.
func stdCoreProjection(env: in BuildEnv, id: in SymbolId, hd: in String, name: in String): Bool {
  val wanted = (hd == "Result" and (name == "value" or name == "error")) or (hd == "Option" and name == "value")
  if not wanted {
    return false
  }
  match symTableTypeSymbolOf(env.ctx.tbl, id) {
    case Some(ts) -> ts.originPackage == "Std.Core"
    case None -> false
  }
}

/// `length` of a local the checker left untyped at the read (`var chunk = fis.readNBytes(n)`: a host
/// array result), by the type the local was declared at.
func openLocalBuiltinProperty(env: in BuildEnv, recv: in Expr, name: in String): Option[String] {
  if name != "length" {
    return None
  }
  match openLocalTy(env, recv) {
    case Some(t) -> match t {
      case TSlice(_) -> Some(value = "slice.length")
      case TArray(_, _) -> Some(value = "array.length")
      case TPrim(k) -> match k {
        case TPString -> Some(value = "String.length")
        case _ -> None
      }
      case _ -> None
    }
    case None -> None
  }
}

/// The built-in a property read names: a stdlib collection's `count` and a string's
/// `length`, as the checker names the built-in members (`List.count`).  A user type
/// that happens to be named `List` is not the stdlib's.
func builtinPropertyName(env: in BuildEnv, recv: in Expr, name: in String): Option[String] {
  val rty = match mapGet(env.ctx.tbl.exprTypes, recv.nodeId) {
    case Some(t) -> t
    case None -> return openLocalBuiltinProperty(env, recv, name)
  }
  match rty {
    case TyPrim(PtString) -> if name == "length" { return Some(value = "String.length") }
    case TySlice(_) -> if name == "length" { return Some(value = "slice.length") }
    case TyArray(_, _, _) -> if name == "length" { return Some(value = "array.length") }
    case TyException -> if name == "message" {
      return Some(value = "Exception.message")
    } else if name == "typeName" {
      return Some(value = "Exception.typeName")
    }
    case TyUser(id, hd, _) -> if name == "length" and symbolIdEq(id, builtinBufferTypeId()) {
      return Some(value = "buffer.length")
    } else if stdCoreProjection(env, id, hd, name) {
      // `r.value`, `r.error` and `o.value`: the partial projection a contract states under `isOk`/`isSome`.
      return Some(value = hd + "." + name)
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
  openLocalBuiltinProperty(env, recv, name)
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

func isIntPrimTy(t: in Ty): Bool {
  match t {
    case TPrim(TPInt) -> true
    case _ -> false
  }
}

/// An index of a range subtype or a distinct type over an integer, as that integer: the
/// operand unwrapped (`CvUnrefine`, `CvUnwrapDistinct`) until it is a primitive, or as it was
/// when it is neither.
func unwrapIndexOperand(env: in BuildEnv, t: in TExpr): TExpr {
  match t.ty {
    case TRefined(u, _, _, _) -> unwrapIndexOperand(env, convertNode(env, t, u, CvUnrefine))
    case TNamed(did, targs) -> {
      if targs.count != 0 {
        return t
      }
      val under = match symbolOfDefId(env.ctx.tbl, did) {
        case Some(sym) -> match sym.kind {
          case DKDistinctType(_, _) -> distinctUnderlyingOf(
            env.ctx.tbl,
            TyUser(id = did, name = sym.name, args = newList())
          )
          case _ -> None
        }
        case None -> None
      }
      match under {
        case Some(u) -> match tyOfType(env.ctx, u) {
          case Ok(uty) -> unwrapIndexOperand(env, convertNode(env, t, uty, CvUnwrapDistinct(sym = did)))
          case Err(_) -> t
        }
        case None -> t
      }
    }
    case _ -> t
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
  val it0 = match buildExpr(env, idxs[0]) { case Some(t) -> t; case None -> return None }
  val keyTy = match indexKeyTy(how, rt.ty) {
    case Some(k) -> k
    case None -> {
      val _ = uncoveredExpr(env, e, "an index with an unknown key type")
      return None
    }
  }
  // An array, slice, string or list index may be any integer type (docs/01 section on arrays: a
  // non-Int index is range checked as a Long before it is narrowed), so it keeps its own type.
  val it = if isIntPrimTy(keyTy) { unwrapIndexOperand(env, it0) } else { it0 }
  val keepsOwnType = match keyTy {
    case TPrim(TPInt) -> match it.ty { case TPrim(k) -> isIntegerPrim(k); case _ -> false }
    case _ -> false
  }
  val idx = if keepsOwnType {
    it
  } else {
    match coerceArg(env, it, keyTy) {
      case Some(c) -> c
      case None -> return None
    }
  }
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
  // A local is assigned at the type it was declared at, whether or not the checker recorded a type
  // for the target (a local bound to an unchecked host result, `chunk = s.readNBytes(4)`).
  match target.kind {
    case EPath(p) -> if p.segments.count == 1 {
      match lookupLocal(env, p.segments[0]) {
        case Some(d) -> {
          if d.id.id >= 0 {
            return Some(value = TPlace(ty = d.ty, kind = PlLocal(local = d.id)))
          }
        }
        case None -> ()
      }
    }
    case _ -> ()
  }
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
          val _ = uncoveredExprDetail(
            env,
            target,
            "an assignment to a member that is not a record field",
            renderTy(rt.ty) + "." + name
          )
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
    // `self = ...` in a method that takes `self: inout T`: the receiver is the parameter named `self`.
    case ESelf -> match lookupLocal(env, "self") {
      case Some(d) -> {
        if d.id.id < 0 {
          return None
        }
        Some(value = TPlace(ty = d.ty, kind = PlLocal(local = d.id)))
      }
      case None -> {
        val _ = uncoveredExpr(env, target, "an assignment to self outside a method")
        None
      }
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
  match target.kind {
    case EMember(r, name) -> if isHostValue(env, r) { return buildHostPropertySet(env, e, target, r, name, op, value) }
    case _ -> ()
  }
  val place = match buildPlace(env, target) { case Some(p) -> p; case None -> return None }
  val vt = match buildExpr(env, value) { case Some(t) -> t; case None -> return None }
  // `s += x` on a `String` takes any value, which is appended as its `toString`.
  val appended = match op {
    case AssPlus -> match place.ty { case TPrim(TPString) -> stringPart(env, vt); case _ -> vt }
    case _ -> vt
  }
  val v = match coerceArg(env, appended, place.ty) { case Some(c) -> c; case None -> return None }
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
  // A float literal where a `Float` is expected is a `Float` literal (the checker accepts it as
  // one): the same literal retyped, which a backend rounds to 32 bits, not a conversion.
  match t.kind {
    case XLit(TLFloat(_)) -> match t.ty {
      case TPrim(TPDouble) -> match ty {
        case TPrim(TPFloat) -> return Some(value = TExpr(id = t.id, ty = ty, span = t.span, kind = t.kind))
        case _ -> ()
      }
      case _ -> ()
    }
    case _ -> ()
  }
  if isCallbackOf(t.ty, ty) {
    return Some(value = convertNode(env, t, ty, CvCallback))
  }
  if isNeverFnOf(t.ty, ty) {
    return Some(value = convertNode(env, t, ty, CvNeverFn))
  }
  if isClosureAsPointer(t.ty, ty) {
    return Some(value = convertNode(env, t, ty, CvClosureAsPointer))
  }
  match retypeListLiteral(env, t, ty) {
    case Some(c) -> return Some(value = c)
    case None -> ()
  }
  match convKindOf(t.ty, ty) {
    case Some(k) -> Some(value = convertNode(env, t, ty, k))
    case None -> match upcastKind(env, t.ty, ty) {
      case Some(k) -> Some(value = convertNode(env, t, ty, k))
      case None -> match hostUpcastKind(env, t.ty, ty) {
        case Some(k) -> Some(value = convertNode(env, t, ty, k))
        case None -> match retypeConstruct(env, t, ty) {
          case Some(c) -> Some(value = c)
          case None -> match retypeValue(env, t, ty) {
            case Some(c) -> Some(value = c)
            case None -> match covariantKind(env, t.ty, ty) {
              case Some(k) -> Some(
                value = convertNode(
                  env,
                  t,
                  ty,
                  k
                )
              )
              case None -> match erasedHostKind(t.ty, ty) {
                case Some(k) -> Some(
                  value = convertNode(
                    env,
                    t,
                    ty,
                    k
                  )
                )
                case None -> None
              }
            }
          }
        }
      }
    }
  }
}

/// A host value used where the language names its erased generic type (D444): the host's `Object` for a
/// type parameter, a host generic class as the same class applied to type arguments, and the host's `Object`
/// array as a slice of a type parameter, or the slice of host `Object`s a host array result was typed as
/// (`hostArrayAsSlice`) used as the slice of a type parameter.  The host's erasure makes the representation
/// the same, so the conversion is `CvFromHost`.
pub func erasedHostKind(from: in Ty, to: in Ty): Option[ConvKind] {
  match from {
    case TExtern(a) -> match to {
      case TParam(_, _) -> if isHostObject(a.name) { Some(value = CvFromHost) } else { None }
      // The host's `Object` where a Lyric primitive or string is wanted (`action(e.getKey(), e.getValue())`
      // on a raw `Map.Entry`): the checker leaves a host result unchecked (docs/01 section 2.11) and
      // types it at the type its context wants, as D433 reads a local.
      case TPrim(_) -> if isHostObject(a.name) { Some(value = CvFromHost) } else { None }
      case TExtern(b) -> if externHostBase(a.name) == externHostBase(b.name) and not tyEq(from, to) {
        Some(value = CvFromHost)
      } else {
        None
      }
      case TSlice(el) -> match el {
        case TParam(_, _) -> if a.name == hostArrayName() {
          Some(value = CvFromHost)
        } else {
          None
        }
        case _ -> None
      }
      case _ -> None
    }
    case TSlice(fromEl) -> match fromEl {
      case TExtern(a) -> match to {
        case TSlice(toEl) -> match toEl {
          case TParam(_, _) -> if isHostObject(a.name) {
            Some(value = CvFromHost)
          } else {
            None
          }
          case _ -> None
        }
        case _ -> None
      }
      case _ -> None
    }
    case _ -> None
  }
}

/// Whether a value of `from` is used at `to`: equal, an interface upcast, a nullable of such,
/// or covariantly converted (`covariantKind`).
func argRelated(env: in BuildEnv, from: in Ty, to: in Ty): Bool {
  if tyEq(from, to) {
    return true
  }
  match upcastKind(env, from, to) {
    case Some(_) -> return true
    case None -> ()
  }
  match from {
    case TNullable(a) -> match to { case TNullable(b) -> return argRelated(env, a, b); case _ -> () }
    case _ -> ()
  }
  isSome(covariantKind(env, from, to))
}

/// The conversion of a value of the generic type `from` to the same type at other arguments
/// that each convert (a recursive union such as `Tree[English]` as `Tree[Greeter]`, which has no
/// finite `match`, or a host collection such as `List[Result[English, String]]`).  A record with
/// a `var` field has identity and stays counted, as in `retypeRecord`.
func covariantKind(env: in BuildEnv, from: in Ty, to: in Ty): Option[ConvKind] {
  var haveArgs: List[Ty] = newList()
  var wantArgs: List[Ty] = newList()
  match from {
    case TNamed(a, xs) -> match to {
      case TNamed(b, ys) -> {
        if a.id != b.id or xs.count == 0 or xs.count != ys.count {
          return None
        }
        val sym = match symbolOfDefId(env.ctx.tbl, a) { case Some(x) -> x; case None -> return None }
        match sym.kind {
          case DKUnion(_, _) -> ()
          case DKRecord(_, _) -> if varFieldNames(env.ctx.tbl, a).count > 0 { return None }
          case _ -> return None
        }
        haveArgs = xs
        wantArgs = ys
      }
      case _ -> return None
    }
    case TExtern(h) -> match to {
      case TExtern(g) -> {
        if h.name != g.name or h.args.count == 0 or h.args.count != g.args.count {
          return None
        }
        if not h.name.startsWith("System.Collections.Generic.") {
          return None
        }
        haveArgs = h.args
        wantArgs = g.args
      }
      case _ -> return None
    }
    case _ -> return None
  }
  var i = 0
  while i < haveArgs.count {
    if not argRelated(env, haveArgs[i], wantArgs[i]) {
      return None
    }
    i = i + 1
  }
  Some(value = CvCovariant)
}

/// A list literal the checker typed as a slice (an explicit type argument or a hoisted operand
/// gave it no array context) used where a fixed-length array is wanted: the same elements
/// as an array literal of that type, each converted to the element type.  None unless the
/// literal has exactly the array's known length and its elements convert.
func retypeListLiteral(env: in BuildEnv, t: in TExpr, ty: in Ty): Option[TExpr] {
  val elems = match t.kind { case XListLit(es) -> es; case _ -> return None }
  match t.ty {
    case TSlice(_) -> ()
    case _ -> return None
  }
  val el = match ty {
    case TArray(len, element) -> match len {
      case ALKnown(n) -> if n == elems.count { element } else { return None }
      case _ -> return None
    }
    case _ -> return None
  }
  val converted: List[TExpr] = newList()
  for x in elems {
    match convertValue(env, x, el) {
      case Some(c) -> converted.add(c)
      case None -> return None
    }
  }
  Some(value = TExpr(id = t.id, ty = ty, span = t.span, kind = XListLit(elems = converted)))
}

/// A union-case construction used at the same union with other type arguments (`Some(value = x)`
/// of an `Option[Sub]` where an `Option[Iface]` is expected, `None` of any `Option`): the case
/// is built again at the arguments of `ty`, each field converted to its type there.  None for a
/// value that is not a construction, or whose fields do not convert.
func retypeConstruct(env: in BuildEnv, t: in TExpr, ty: in Ty): Option[TExpr] {
  match t.kind {
    case XConstruct(sym, fields) -> {
      val parent = match t.ty { case TNamed(p, _) -> p; case _ -> return None }
      val haveArgs = match t.ty { case TNamed(_, a) -> a; case _ -> return None }
      val wantParent = match ty { case TNamed(p, _) -> p; case _ -> return None }
      val want = match ty { case TNamed(_, a) -> a; case _ -> return None }
      if parent.id != wantParent.id or haveArgs.count != want.count or want.count == 0 {
        return None
      }
      val en = match mapGet(env.syms, sym.id) { case Some(e) -> e; case None -> return None }
      val sig = match en.sig { case Some(s) -> s; case None -> return None }
      if sig.params.count != fields.count {
        return None
      }
      val nf: List[TExpr] = newList()
      var i = 0
      while i < fields.count {
        val target = substOwnerArgs(sig.params[i].ty, parent, want)
        match convertValue(env, fields[i], target) {
          case Some(c) -> nf.add(c)
          case None -> return None
        }
        i = i + 1
      }
      Some(value = TExpr(id = t.id, ty = ty, span = t.span, kind = XConstruct(sym = sym, fields = nf)))
    }
    case _ -> None
  }
}

/// A value of a union used at the same union with other type arguments (a `Result[English, String]`
/// where a `Result[Greeter, String]` is wanted): a `match` over every case of the union that builds
/// the case again at the arguments of `ty`, each payload converted to its type there.  None when
/// the types are not one union at different arguments, or a payload does not convert.
func retypeValue(env: in BuildEnv, t: in TExpr, ty: in Ty): Option[TExpr] {
  val outer = match t.ty { case TNamed(p, _) -> p; case _ -> return None }
  for u in env.retyping {
    if u == outer.id {
      return None
    }
  }
  env.retyping.add(outer.id)
  val built = retypeValueCases(env, t, ty)
  env.retyping.removeAt(env.retyping.count - 1)
  built
}

func retypeValueCases(env: in BuildEnv, t: in TExpr, ty: in Ty): Option[TExpr] {
  val parent = match t.ty { case TNamed(p, _) -> p; case _ -> return None }
  val haveArgs = match t.ty { case TNamed(_, a) -> a; case _ -> return None }
  val wantParent = match ty { case TNamed(p, _) -> p; case _ -> return None }
  val want = match ty { case TNamed(_, a) -> a; case _ -> return None }
  if parent.id != wantParent.id or haveArgs.count != want.count or want.count == 0 {
    return None
  }
  val cases = match mapGet(caseSymbolsByParent(env.ctx.tbl), parent.id) { case Some(c) -> c; case None -> newList() }
  if cases.count == 0 {
    return retypeRecord(env, t, ty, parent, haveArgs, want)
  }
  val arms: List[TArm] = newList()
  for cs in cases {
    noteCaseSym(env, cs)
    val en = match mapGet(env.syms, cs.id) { case Some(x) -> x; case None -> return None }
    val sig = match en.sig { case Some(x) -> x; case None -> return None }
    pushScope(env)
    val pats: List[TPat] = newList()
    val fields: List[TExpr] = newList()
    var i = 0
    while i < sig.params.count {
      val haveTy = substOwnerArgs(sig.params[i].ty, parent, haveArgs)
      val wantTy = substOwnerArgs(sig.params[i].ty, parent, want)
      val d = declareLocal(env, "__covariant" + toString(i), haveTy, false)
      pats.add(TPat(id = freshNodeId(env), ty = haveTy, span = t.span, kind = TpBind(decl = d, inner = None)))
      val read = TExpr(id = freshNodeId(env), ty = haveTy, span = t.span, kind = XLocal(local = d.id))
      match convertValue(env, read, wantTy) {
        case Some(c) -> fields.add(c)
        case None -> {
          popScope(env)
          return None
        }
      }
      i = i + 1
    }
    popScope(env)
    val pat = TPat(id = freshNodeId(env), ty = t.ty, span = t.span, kind = TpCtor(sym = cs, args = pats))
    val body = TExpr(id = freshNodeId(env), ty = ty, span = t.span, kind = XConstruct(sym = cs, fields = fields))
    arms.add(TArm(pat = pat, guard = None, body = body))
  }
  Some(
    value = TExpr(
      id = freshNodeId(env),
      ty = ty,
      span = t.span,
      kind = XMatch(scrutinee = t, arms = arms, exhaustive = true)
    )
  )
}

/// A record value used at the same record with other type arguments (`Box[English]` where a
/// `Box[Greeter]` is wanted): the value is bound once and the record built again at the arguments
/// of `ty`, each field read and converted to its type there.  A record with a `var` field has
/// identity, so a copy would change what an alias sees: it stays counted.
func retypeRecord(
  env: in BuildEnv,
  t: in TExpr,
  ty: in Ty,
  parent: in SymbolId,
  haveArgs: in List[Ty],
  want: in List[Ty],
): Option[TExpr] {
  val sym = match symbolOfDefId(env.ctx.tbl, parent) { case Some(x) -> x; case None -> return None }
  match sym.kind {
    case DKRecord(_, _) -> ()
    case _ -> return None
  }
  val names = recordGenericNamesOf(env.ctx.tbl, parent)
  if names.count != want.count {
    return None
  }
  val ctx = newTyConvCtx(env.ctx.tbl)
  tyConvBind(ctx, sym.name, parent, names)
  val vars = varFieldNames(env.ctx.tbl, parent)
  val fs: List[TFieldSig] = newList()
  for f in fieldsOfRecord(env.ctx.tbl, parent) {
    if vars.containsKey(f.name) {
      return None
    }
    match tyOfType(ctx, f.ty) {
      case Ok(ft) -> fs.add(TFieldSig(name = f.name, ty = ft, mutable = false))
      case Err(_) -> return None
    }
  }
  if fs.count == 0 {
    return None
  }
  if not env.syms.containsKey(parent.id) {
    env.syms.add(parent.id, typeEntry(parent, names.count, fs))
  }
  pushScope(env)
  val d = declareLocal(env, "__covariant_record", t.ty, false)
  val bound = TStmt(
    id = freshNodeId(env),
    span = t.span,
    kind = TsLet(
      pat = TPat(
        id = freshNodeId(env),
        ty = t.ty,
        span = t.span,
        kind = TpBind(decl = d, inner = None)
      ),
      init = t
    )
  )
  val fields: List[TExpr] = newList()
  var i = 0
  while i < fs.count {
    val haveTy = substOwnerArgs(fs[i].ty, parent, haveArgs)
    val wantTy = substOwnerArgs(fs[i].ty, parent, want)
    val recv = TExpr(id = freshNodeId(env), ty = t.ty, span = t.span, kind = XLocal(local = d.id))
    val read = TExpr(
      id = freshNodeId(env),
      ty = haveTy,
      span = t.span,
      kind = XField(recv = recv, field = FieldRef(owner = parent, name = fs[i].name, index = i))
    )
    match convertValue(env, read, wantTy) {
      case Some(c) -> fields.add(c)
      case None -> {
        popScope(env)
        return None
      }
    }
    i = i + 1
  }
  popScope(env)
  val built = TExpr(id = freshNodeId(env), ty = ty, span = t.span, kind = XConstruct(sym = parent, fields = fields))
  Some(
    value = TExpr(
      id = freshNodeId(env),
      ty = ty,
      span = t.span,
      kind = XBlock(stmts = [bound], tail = Some(value = built))
    )
  )
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

/// `renderTy` with each declaration `#<id>` spelled by its DefPath key, for a message that names
/// the types a conversion could not take.
func renderTyNamed(env: in BuildEnv, t: in Ty): String {
  val raw = renderTy(t)
  var res = ""
  var i = 0
  while i < raw.length {
    val c = raw.substring(i, 1)
    if c == "#" {
      var j = i + 1
      var v = 0
      var digits = 0
      var more = true
      while more and j < raw.length {
        match "0123456789".indexOf(raw.substring(j, 1)) {
          case Some(dv) -> {
            v = v * 10 + dv
            digits = digits + 1
            j = j + 1
          }
          case None -> {
            more = false
          }
        }
      }
      val named = if digits > 0 { symTableDefPathKeyOf(env.ctx.tbl, SymbolId(id = v)) } else { None }
      match named {
        case Some(k) -> {
          res = res + k
          i = j
        }
        case None -> {
          res = res + c
          i = i + 1
        }
      }
    } else {
      res = res + c
      i = i + 1
    }
  }
  res
}

/// An argument as the parameter `pty` takes it: as is, converted by a node of its own,
/// or not at all (counted), never converted by guessing.
func coerceArg(env: in BuildEnv, t: in TExpr, pty: in Ty): Option[TExpr] {
  match convertValue(env, t, pty) {
    case Some(c) -> Some(value = c)
    case None -> {
      noteUncoveredAt(env, "an argument conversion", t.span)
      env.errors.add(
        "I0002: the builder has no case for an argument conversion from " + renderTyNamed(env, t.ty) + " to " +
          renderTyNamed(env, pty) +
          " at " +
          toString(t.span.startPos.line) +
          ":" +
          toString(t.span.startPos.column)
      )
      None
    }
  }
}

/// Whether `t` is the literal `true`.
func isTrueLiteral(t: in TExpr): Bool {
  match t.kind {
    case XLit(TLBool(v)) -> v
    case _ -> false
  }
}

/// Whether a `break` inside `t` can leave the loop labelled `lbl`: an unlabelled one at loop `depth` 0,
/// or one naming `lbl`.  Loops nested in `t` shield unlabelled breaks.
func blockMayBreak(t: in TExpr, lbl: in Option[String], depth: in Int): Bool {
  match t.kind {
    case XBlock(stmts, tail) -> {
      for s in stmts {
        if stmtMayBreak(s, lbl, depth) {
          return true
        }
      }
      match tail {
        case Some(x) -> blockMayBreak(x, lbl, depth)
        case None -> false
      }
    }
    case XIf(_, a, b) -> blockMayBreak(a, lbl, depth) or
      (match b { case Some(x) -> blockMayBreak(x, lbl, depth); case None -> false })
    case XMatch(_, arms, _) -> {
      for arm in arms {
        if blockMayBreak(arm.body, lbl, depth) {
          return true
        }
      }
      false
    }
    case XUnsafe(body) -> blockMayBreak(body, lbl, depth)
    case XAssign(_, _, v) -> blockMayBreak(v, lbl, depth)
    case _ -> false
  }
}

func breakTargetsUs(b: in Option[String], lbl: in Option[String], depth: in Int): Bool {
  match b {
    case None -> depth == 0
    case Some(n) -> match lbl { case Some(m) -> n == m; case None -> false }
  }
}

func stmtMayBreak(s: in TStmt, lbl: in Option[String], depth: in Int): Bool {
  match s.kind {
    case TsBreak(b) -> breakTargetsUs(b, lbl, depth)
    case TsExpr(x) -> blockMayBreak(x, lbl, depth)
    case TsLet(_, init) -> blockMayBreak(init, lbl, depth)
    case TsVar(_, init) -> match init { case Some(x) -> blockMayBreak(x, lbl, depth); case None -> false }
    case TsReturn(v) -> match v { case Some(x) -> blockMayBreak(x, lbl, depth); case None -> false }
    case TsScope(_, body) -> blockMayBreak(body, lbl, depth)
    case TsDefer(body) -> blockMayBreak(body, lbl, depth)
    case TsTry(body, catches, fin) -> {
      if blockMayBreak(body, lbl, depth) {
        return true
      }
      for c in catches {
        if blockMayBreak(c.body, lbl, depth) {
          return true
        }
      }
      match fin {
        case Some(x) -> blockMayBreak(x, lbl, depth)
        case None -> false
      }
    }
    case TsFor(_, _, _, body) -> blockMayBreak(body, lbl, depth + 1)
    case TsWhile(_, _, body) -> blockMayBreak(body, lbl, depth + 1)
    case TsLoop(_, body) -> blockMayBreak(body, lbl, depth + 1)
    case _ -> false
  }
}

/// Whether control never reaches the end of `t`: a block with no tail value whose last
/// statement always leaves it (`return`, `throw`, `break`, `continue`, a `scope` or an
/// expression statement that never completes), an `if` with an `else` whose branches
/// both leave, or a `match` whose arms all do.
func neverCompletes(t: in TExpr): Bool {
  match t.kind {
    case XBlock(stmts, None) -> {
      if stmts.count == 0 {
        return false
      }
      match stmts[stmts.count - 1].kind {
        case TsReturn(_) -> true
        case TsThrow(_) -> true
        case TsBreak(_) -> true
        case TsContinue(_) -> true
        case TsScope(_, body) -> neverCompletes(body)
        case TsExpr(x) -> neverCompletes(x)
        case TsLoop(l, body) -> not blockMayBreak(body, l, 0)
        case TsWhile(lbl, cond, body) -> isTrueLiteral(cond) and not blockMayBreak(body, lbl, 0)
        case _ -> false
      }
    }
    case XIf(_, a, Some(b)) -> neverCompletes(a) and neverCompletes(b)
    case XMatch(_, arms, _) -> {
      if arms.count == 0 {
        return false
      }
      for arm in arms {
        if not neverCompletes(arm.body) {
          return false
        }
      }
      true
    }
    case _ -> false
  }
}

/// `t`, which never completes, typed as `ty` all the way down: the verifier takes a branch
/// that is not `Never` only at the type of the whole, so the branches of a nested `if` or
/// `match` are retyped with it.
func retypeNeverCompleting(t: in TExpr, ty: in Ty): TExpr {
  match t.kind {
    case XIf(c, a, Some(b)) -> TExpr(
      id = t.id,
      ty = ty,
      span = t.span,
      kind = XIf(
        cond = c,
        thenBranch = retypeNeverCompleting(a, ty),
        elseBranch = Some(value = retypeNeverCompleting(b, ty))
      )
    )
    case XMatch(scrut, arms, ex) -> {
      val fresh: List[TArm] = newList()
      for arm in arms {
        fresh.add(TArm(pat = arm.pat, guard = arm.guard, body = retypeNeverCompleting(arm.body, ty)))
      }
      TExpr(id = t.id, ty = ty, span = t.span, kind = XMatch(scrutinee = scrut, arms = fresh, exhaustive = ex))
    }
    case _ -> TExpr(id = t.id, ty = ty, span = t.span, kind = t.kind)
  }
}

/// A branch of an `if` or `match` as the whole takes it: as is, widened by a node of
/// its own, or not at all (counted).  A branch that never completes fits any type.
func coerceBranch(env: in BuildEnv, t: in TExpr, ty: in Ty): Option[TExpr] {
  // A branch that never completes (see `neverCompletes`) fits any type.
  if neverCompletes(t) {
    return Some(value = retypeNeverCompleting(t, ty))
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
  match convertValue(env, t, ty) {
    case Some(c) -> Some(value = c)
    case None -> {
      noteUncoveredAt(env, "a branch conversion", t.span)
      env.errors.add(
        "I0002: the builder has no case for a branch conversion from " + renderTyNamed(env, t.ty) + " to " +
          renderTyNamed(env, ty) +
          " at " +
          toString(t.span.startPos.line) +
          ":" +
          toString(t.span.startPos.column)
      )
      None
    }
  }
}

/// The built-ins whose parameter is any `T`: no argument converts.
func genericBuiltin(name: in String): Bool {
  ffiIntrinsicName(name) or name == "println" or name == "print" or name == "toString" or name == "hashCode" or
    name == "default" or
    Str.endsWith(name, ".wrappingAdd") or
    Str.endsWith(name, ".wrappingSub") or
    Str.endsWith(name, ".wrappingMul") or
    Str.endsWith(name, ".wrappingNeg")
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

/// Whether argument `i`, a name, is read before an argument written after it that is not a literal
/// or a name (a call, which may change the local the name reads: `f(b = x, a = zero(x))` with
/// `zero(x: inout Int)`).  When names reorder the arguments, such a name is bound to a temporary in
/// source order like the call is.
func readsBeforeLaterCall(slots: in List[Option[Expr]], srcIdx: in List[Int], i: in Int): Bool {
  val x = match slots[i] { case Some(v) -> v; case None -> return false }
  val isName = match x.kind { case EPath(_) -> true; case _ -> false }
  if not isName {
    return false
  }
  var j = 0
  while j < slots.count {
    if j != i and srcIdx[j] > srcIdx[i] {
      match slots[j] {
        case Some(y) -> if not isPlainArg(y) { return true }
        case None -> ()
      }
    }
    j = j + 1
  }
  false
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

/// The type of parameter `i` (`p`) of the call being built: the one the context fixed for a call
/// with open type arguments (`ptys`, one per parameter, empty for a call with none), else the
/// signature's.
func paramTyAt(env: in BuildEnv, ptys: in List[Ty], i: in Int, p: in ResolvedParam): Result[Ty, String] {
  if i < ptys.count {
    Ok(value = ptys[i])
  } else {
    tyOfType(env.ctx, p.ty)
  }
}

/// Read the type arguments of the generic names `generics` off the signature type `t` and the
/// type `ty` the call's context fixes for it, into `acc` (the first reading of a name stands).
func unifyOpenArgs(t: in Type, ty: in Ty, generics: in List[String], acc: in Map[String, Ty]): Unit {
  match t {
    case TyParam(name, _) -> if generics.contains(name) and not acc.containsKey(name) { acc.add(name, ty) }
    case TyUser(id, _, args) -> match ty {
      case TNamed(s, targs) -> if s.id == id.id and args.count == targs.count {
        var i = 0
        while i < args.count {
          unifyOpenArgs(args[i], targs[i], generics, acc)
          i = i + 1
        }
      }
      case TExtern(h) -> if args.count == h.args.count {
        var i = 0
        while i < args.count {
          unifyOpenArgs(args[i], h.args[i], generics, acc)
          i = i + 1
        }
      }
      case _ -> ()
    }
    case TySlice(e) -> match ty { case TSlice(x) -> unifyOpenArgs(e, x, generics, acc); case _ -> () }
    case TyNullable(inner) -> match ty { case TNullable(x) -> unifyOpenArgs(inner, x, generics, acc); case _ -> () }
    case TyTuple(es) -> match ty {
      case TTuple(xs) -> if es.count == xs.count {
        var i = 0
        while i < es.count {
          unifyOpenArgs(es[i], xs[i], generics, acc)
          i = i + 1
        }
      }
      case _ -> ()
    }
    case _ -> ()
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
  val ptys: List[Ty] = newList()
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
    var openMsg = ""
    for ta in checkerArgs {
      match tyOfType(env.ctx, ta) {
        case Ok(t) -> tyArgs.add(t)
        case Err(msg) -> {
          if openMsg == "" {
            openMsg = msg
          }
        }
      }
    }
    if openMsg != "" {
      // The checker left a type argument open and the call's context fixed its type (an argument
      // `newList()` of a `List[Int]` parameter): read the arguments off that type, and the
      // parameters as the signature gives them under those arguments.
      val acc: Map[String, Ty] = newMap()
      unifyOpenArgs(sig.returnTy, ty, sig.generics, acc)
      tyArgs = newList()
      for g in sig.generics {
        match mapGet(acc, g) {
          case Some(t) -> tyArgs.add(t)
          case None -> {
            env.errors.add(openMsg)
            return None
          }
        }
      }
      val pctx = newTyConvCtx(env.ctx.tbl)
      for o in sig.genericOwners {
        tyConvBind(pctx, o, sym, sig.generics)
      }
      for p in sig.params {
        match tyOfType(pctx, p.ty) {
          case Ok(pt) -> ptys.add(substOwnerArgs(pt, sym, tyArgs))
          case Err(msg) -> {
            env.errors.add(msg)
            return None
          }
        }
      }
    } else {
      val ps: List[ResolvedParam] = newList()
      for p in sig.params {
        ps.add(p.copy(ty = substituteTyParamsOwned(p.ty, sig.generics, sig.genericOwners, checkerArgs)))
      }
      callSig = sig.copy(params = ps)
    }
  }
  val pre: List[TStmt] = newList()
  match buildCallArgs(env, e, sym, callSig, ptys, args, pre) {
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

func isMemberExpr(x: in Expr): Bool {
  match x.kind {
    case EMember(_, _) -> true
    case _ -> false
  }
}

/// The non-generic interface that declares the method `sym`, when `sym`'s DefPath is
/// `Pkg::Iface::member`.  A call of a method that a restored package's record implements resolves
/// to the interface's declaration (the package interface keeps no `impl` member of its own), so
/// the call is a dispatch on that interface from the receiver, converted up to it.
func ifaceOwnerOfMethod(env: in BuildEnv, sym: in SymbolId): Option[Type] {
  val tbl = env.ctx.tbl
  val key = match symTableDefPathKeyOf(tbl, sym) { case Some(k) -> k; case None -> return None }
  var cut = -1
  var i = 0
  while i + 1 < key.length {
    if key.substring(i, 2) == "::" {
      cut = i
    }
    i = i + 1
  }
  if cut <= 0 {
    return None
  }
  val tid = match symbolIdOfKey(tbl.interner, key.substring(0, cut)) { case Some(t) -> t; case None -> return None }
  match symTableTypeSymbolOf(tbl, tid) {
    case Some(ts) -> match ts.kind {
      case DKInterface(_, decl) -> if isSome(decl.generics) {
        None
      } else {
        Some(value = TyUser(id = tid, name = ts.name, args = newList()))
      }
      case _ -> None
    }
    case None -> None
  }
}

/// A method call `recv.m(args)` or a bare sibling call `m(args)` (on the enclosing `self`):
/// the receiver first, then the arguments placed by parameter, to the method the checker
/// resolved (`Direct`, or `Interface` for an interface-typed receiver).  A receiver passed
/// `out` or `inout` is a place argument.
func buildMethodCall(
  env: in BuildEnv,
  e: in Expr,
  ty: in Ty,
  sym: in SymbolId,
  site: in MethodCallSite,
  fn: in Expr,
  args: in List[CallArg],
): Option[TExpr] {
  // A bare call of a sibling method (`m(1)` inside a method of the same type) is called on
  // the enclosing method's own `self`.
  val bareSelf = match fn.kind { case EPath(path) -> path.segments.count == 1; case _ -> false }
  val recvExpr = match fn.kind { case EMember(r, _) -> r; case _ -> fn }
  if not bareSelf and not isMemberExpr(fn) {
    return uncoveredExpr(env, e, "a method call whose callee is not a member access")
  }
  val ifaceTy: Option[Type] = if isSome(site.iface) { None } else { ifaceOwnerOfMethod(env, sym) }
  val ifaceSym: Option[SymbolId] = match ifaceTy {
    case Some(TyUser(id, _, _)) -> Some(value = id)
    case _ -> site.iface
  }
  val recvTyDecl: Type = match ifaceTy { case Some(t) -> t; case None -> site.recvTy }
  var isEntry = false
  var isImplMember = false
  var recvMode: Option[ParamMode] = None
  match site.sig.recvMode {
    case Some(PMIn) -> ()
    case Some(m) -> {
      recvMode = Some(value = m)
    }
    // An entry or `func` of a protected type declares no receiver: the protected value is
    // the receiver, passed `in` (a reference whose lock the backend takes).
    // An interface method is declared without a receiver too: the value it is called
    // on is the receiver, dispatched on its interface.
    case None -> if recvIsProtected(env, site.recvTy) {
      isEntry = true
    } else if isSome(ifaceSym) {
      ()
    } else {
      // A member of an `impl Iface for T` block declares no receiver either: `self` is
      // implicit, so the value it is called on is the receiver, passed `in`.
      isImplMember = true
    }
  }
  val declared = match tyOfType(env.ctx, recvTyDecl) {
    case Ok(t) -> t
    case Err(msg) -> {
      env.errors.add(msg)
      return None
    }
  }
  // A receiver passed `out` or `inout` is a place, not a value.
  var recvPlace: Option[TPlace] = None
  val rt = if isSome(recvMode) {
    if bareSelf {
      match lookupLocal(env, "self") {
        case Some(d) -> {
          recvPlace = Some(value = TPlace(ty = d.ty, kind = PlLocal(local = d.id)))
          TExpr(id = freshNodeId(env), ty = d.ty, span = fn.span, kind = XLocal(local = d.id))
        }
        case None -> return uncoveredExpr(env, e, "a bare method call outside a method")
      }
    } else {
      match buildPlace(env, recvExpr) {
        case Some(pl) -> {
          recvPlace = Some(value = pl)
          TExpr(id = freshNodeId(env), ty = pl.ty, span = recvExpr.span, kind = XLocal(local = LocalId(id = 0)))
        }
        case None -> return None
      }
    }
  } else if bareSelf {
    match lookupLocal(env, "self") {
      case Some(d) -> TExpr(id = freshNodeId(env), ty = d.ty, span = fn.span, kind = XLocal(local = d.id))
      case None -> return uncoveredExpr(env, e, "a bare method call outside a method")
    }
  } else {
    match buildExpr(env, recvExpr) {
      case Some(t) -> t
      case None -> return None
    }
  }
  val recv = if isSome(recvPlace) {
    if not tyEq(rt.ty, declared) {
      return uncoveredExpr(env, e, "a method call with a mutating receiver of another type")
    }
    rt
  } else {
    match coerceArg(env, rt, declared) {
      case Some(c) -> c
      case None -> return None
    }
  }
  val inst = match instantiateMethod(env, e, sym, site, args) { case Some(i) -> i; case None -> return None }
  val pre: List[TStmt] = newList()
  val rest = match buildCallArgs(env, e, sym, inst.sig, newList(), args, pre) {
    case Some(a) -> a
    case None -> return None
  }
  val all: List[TArg] = newList()
  // The receiver is evaluated before any argument: when arguments were hoisted ahead of
  // the call, a receiver that is not a literal or a name is hoisted ahead of them.
  var recvArg = recv
  val stmts: List[TStmt] = newList()
  if pre.count > 0 and isSome(recvPlace) and not bareSelf and not isPlainArg(recvExpr) {
    return uncoveredExpr(env, e, "a method call with a mutating receiver after hoisted arguments")
  }
  if pre.count > 0 and not isSome(recvPlace) and not bareSelf and not isPlainArg(recvExpr) {
    val d = declareLocal(env, "__recv" + toString(env.nextLocal[0] + 1), recv.ty, false)
    val bindPat = TPat(id = freshNodeId(env), ty = recv.ty, span = recv.span, kind = TpBind(decl = d, inner = None))
    stmts.add(TStmt(id = freshNodeId(env), span = recv.span, kind = TsLet(pat = bindPat, init = recv)))
    recvArg = TExpr(id = freshNodeId(env), ty = recv.ty, span = recv.span, kind = XLocal(local = d.id))
  }
  for st in pre {
    stmts.add(st)
  }
  match recvPlace {
    case Some(pl) -> match recvMode {
      case Some(PMOut) -> all.add(TArgOut(place = pl))
      case _ -> all.add(TArgInout(place = pl))
    }
    case None -> all.add(TArgIn(value = recvArg))
  }
  for a in rest {
    all.add(a)
  }
  val callee = match ifaceSym {
    case Some(i) -> Interface(iface = i, ifaceArgs = newList(), method = sym, typeArgs = newList())
    case None -> Direct(sym = sym, typeArgs = inst.tyArgs)
  }
  noteFuncSymN(
    env,
    sym,
    site.sig,
    Some(value = recvTyDecl),
    if isEntry or isImplMember or (isSome(ifaceSym) and not isSome(site.sig.recvMode)) {
      Some(value = PMIn)
    } else {
      site.sig.recvMode
    },
    if isEntry { TSkEntry } else if isSome(ifaceSym) { TSkInterfaceMethod } else { TSkFunc },
    inst.tyArgs.count
  )
  Some(value = withPrelude(env, e, stmts, mkExpr(e, ty, XCall(callee = callee, args = all))))
}

/// `forall` and `exists`: the binders are locals of the quantifier's own scope, typed by their
/// annotations, the `where` guard and the body are `Bool` expressions over them.
func buildQuantifier(
  env: in BuildEnv,
  e: in Expr,
  ty: in Ty,
  binders: in List[PropertyBinder],
  whereExpr: in Option[Expr],
  body: in Expr,
  isForall: in Bool,
): Option[TExpr] {
  pushScope(env)
  val decls: List[LocalDecl] = newList()
  for b in binders {
    match annotatedTy(env, b.ty) {
      case Some(t) -> decls.add(declareLocal(env, b.name, t, false))
      case None -> {
        popScope(env)
        return None
      }
    }
  }
  var guard: Option[TExpr] = None
  match whereExpr {
    case Some(we) -> match buildExpr(env, we) {
      case Some(g) -> {
        guard = Some(value = g)
      }
      case None -> {
        popScope(env)
        return None
      }
    }
    case None -> ()
  }
  val b = match buildExpr(env, body) { case Some(x) -> x; case None -> { popScope(env); return None } }
  popScope(env)
  if isForall {
    Some(value = mkExpr(e, ty, XForall(binders = decls, whereExpr = guard, body = b)))
  } else {
    Some(value = mkExpr(e, ty, XExists(binders = decls, whereExpr = guard, body = b)))
  }
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
  match buildCallArgs(env, e, sym, sig, newList(), args, pre) {
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

/// `t` with every node numbered afresh and its spans set to `at`, so that a default
/// argument built from the declaration's nodes can stand at several calls of one body
/// (the verifier requires node ids unique within a body).  None after counting why not:
/// only the kinds a default is made of are handled (literals, names, calls by value,
/// constructions, conversions, lists and tuples).
func refreshDefaultIds(env: in BuildEnv, t: in TExpr, at: in Span): Option[TExpr] {
  val kind: TExprKind = match t.kind {
    case XLit(_) -> t.kind
    case XGlobal(_, _) -> t.kind
    case XLocal(_) -> return noteUncoveredAtSpan(env, at, "a default argument naming a local")
    case XCall(callee, args) -> {
      val fresh: List[TArg] = newList()
      for a in args {
        match a {
          case TArgIn(v) -> match refreshDefaultIds(env, v, at) {
            case Some(r) -> fresh.add(TArgIn(value = r))
            case None -> return None
          }
          case _ -> return noteUncoveredAtSpan(env, at, "a default argument passing a place")
        }
      }
      match callee {
        case Indirect(_) -> return noteUncoveredAtSpan(env, at, "a default argument calling a function value")
        case _ -> XCall(callee = callee, args = fresh)
      }
    }
    case XConstruct(sym, fields) -> {
      val fresh: List[TExpr] = newList()
      for f in fields {
        match refreshDefaultIds(env, f, at) {
          case Some(r) -> fresh.add(r)
          case None -> return None
        }
      }
      XConstruct(sym = sym, fields = fresh)
    }
    case XConvert(k, inner) -> match refreshDefaultIds(env, inner, at) {
      case Some(r) -> XConvert(kind = k, inner = r)
      case None -> return None
    }
    case XListLit(elems) -> {
      val fresh: List[TExpr] = newList()
      for x in elems {
        match refreshDefaultIds(env, x, at) {
          case Some(r) -> fresh.add(r)
          case None -> return None
        }
      }
      XListLit(elems = fresh)
    }
    case XTuple(elems) -> {
      val fresh: List[TExpr] = newList()
      for x in elems {
        match refreshDefaultIds(env, x, at) {
          case Some(r) -> fresh.add(r)
          case None -> return None
        }
      }
      XTuple(elems = fresh)
    }
    case _ -> return noteUncoveredAtSpan(env, at, "a default argument of a shape not yet built")
  }
  Some(value = TExpr(id = freshNodeId(env), ty = t.ty, span = at, kind = kind))
}

/// `noteUncovered` at a span rather than an expression, answering None.
func noteUncoveredAtSpan(env: in BuildEnv, at: in Span, why: in String): Option[TExpr] {
  noteUncoveredAt(env, why, at)
  env.errors.add("I0002: the builder has no case for " + why)
  None
}

/// The argument for a parameter the call leaves out: its declared default, placed at
/// the call under fresh node ids (the declaration's own nodes stay the parameter's).
/// A default of the checked package is built from the checker's record of its nodes.  One
/// declared in another package of the build is read from the defaults that package carried
/// (`DepDefaults`, D482), re-numbered into this package's symbols; one with no carried default
/// (a restored package whose interface does not record it) has no case yet.
func buildDefaultArg(
  env: in BuildEnv,
  call: in Expr,
  callee: in SymbolId,
  origin: in String,
  p: in ResolvedParam,
  ptys: in List[Ty],
  index: in Int,
): Option[TExpr] {
  val here = if env.ctx.tbl.scopePkg.count > 0 { env.ctx.tbl.scopePkg[0] } else { "" }
  if origin != "" and origin != here {
    return buildForeignDefaultArg(env, call, callee, p, ptys, index)
  }
  val d = match p.dfltExpr { case Some(x) -> x; case None -> return uncoveredExpr(env, call, "a defaulted argument") }
  val pty = match paramTyAt(env, ptys, index, p) {
    case Ok(t) -> t
    case Err(msg) -> {
      env.errors.add(msg)
      return None
    }
  }
  val simple = match d.kind { case ELiteral(_) -> true; case EPath(_) -> true; case _ -> false }
  val ty = match exprTy(env.ctx, d.nodeId) { case Ok(t) -> t; case Err(msg) -> { env.errors.add(msg); return None } }
  val built = match d.kind {
    case ELiteral(_) -> buildExpr(env, d)
    case EPath(_) -> buildRefPath(env, d, ty)
    case _ -> {
      // The declaration's node is shared by every call that takes the default, each at
      // its own instantiation: the parameter's type settles it for this call only.
      env.settled.remove(d.nodeId)
      env.settled.add(d.nodeId, pty)
      val b = buildExpr(env, d)
      env.settled.remove(d.nodeId)
      b
    }
  }
  match built {
    case Some(t0) -> {
      val t = if simple {
        Some(value = TExpr(id = freshNodeId(env), ty = t0.ty, span = call.span, kind = t0.kind))
      } else {
        refreshDefaultIds(env, t0, call.span)
      }
      match t {
        case Some(t1) -> match coerceArg(env, t1, pty) {
          case Some(c) -> Some(value = c)
          case None -> uncoveredExpr(env, call, "a default argument needing a conversion")
        }
        case None -> None
      }
    }
    case None -> None
  }
}

/// A default declared in another package: the carried expression, its declarations added to
/// this body's, placed at the call and converted to the parameter's type.
func buildForeignDefaultArg(
  env: in BuildEnv,
  call: in Expr,
  callee: in SymbolId,
  p: in ResolvedParam,
  ptys: in List[Ty],
  index: in Int,
): Option[TExpr] {
  val pty = match paramTyAt(env, ptys, index, p) {
    case Ok(t) -> t
    case Err(msg) -> {
      env.errors.add(msg)
      return None
    }
  }
  val key = match symTableDefPathKeyOf(env.ctx.tbl, callee) {
    case Some(k) -> k
    case None -> return uncoveredExpr(env, call, "a default argument declared in another package")
  }
  val rd = match readCarriedDefault(env.ctx.dep, env.ctx.depRead, key, p.name, env.ctx.tbl.interner) {
    case Some(x) -> x
    case None -> return buildForeignLiteralDefault(env, call, p, pty)
  }
  for en in rd.entries {
    if not env.syms.containsKey(en.sym.id) {
      env.syms.add(en.sym.id, en)
    }
  }
  match refreshDefaultIds(env, rd.expr, call.span) {
    case Some(t1) -> match coerceArg(env, t1, pty) {
      case Some(c) -> Some(value = c)
      case None -> uncoveredExpr(env, call, "a default argument needing a conversion")
    }
    case None -> None
  }
}

/// The default of a package no interface of the build carries (the standard library, which is
/// loaded as source): when it is a plain literal its type is the literal's own, so it needs no
/// checker table of the declaring package; the conversion to the parameter's type is the call's.
/// Any other default is counted.
func buildForeignLiteralDefault(env: in BuildEnv, call: in Expr, p: in ResolvedParam, pty: in Ty): Option[TExpr] {
  val d = match p.dfltExpr {
    case Some(x) -> x
    case None -> return uncoveredExpr(env, call, "a default argument declared in another package")
  }
  val natural: Option[Ty] = match d.kind {
    case ELiteral(l) -> match l {
      case LInt(_, sfx, _) -> match sfx {
        case NoIntSuffix -> Some(value = tyInt())
        case I32 -> Some(value = tyInt())
        case I64 -> Some(
          value = TPrim(kind = TPLong)
        )
        case U8 -> Some(
          value = TPrim(kind = TPByte)
        )
        case U32 -> Some(
          value = TPrim(kind = TPUInt)
        )
        case U64 -> Some(
          value = TPrim(
            kind = TPULong
          )
        )
        case _ -> None
      }
      case LFloat(_, sfx, _) -> match sfx {
        case NoFloatSuffix -> Some(
          value = TPrim(
            kind = TPDouble
          )
        )
        case F64 -> Some(
          value = TPrim(
            kind = TPDouble
          )
        )
        case _ -> None
      }
      case LChar(_) -> Some(value = TPrim(kind = TPChar))
      case LString(_) -> Some(value = tyString())
      case LTripleString(_) -> Some(value = tyString())
      case LRawString(_) -> Some(value = tyString())
      case LBool(_) -> Some(value = tyBool())
      case LUnit -> Some(value = tyUnit())
    }
    case _ -> None
  }
  val lit = match d.kind { case ELiteral(l) -> l; case _ -> return buildForeignCaseDefault(env, call, d, pty) }
  match natural {
    case Some(nt) -> {
      val t = TExpr(id = freshNodeId(env), ty = nt, span = call.span, kind = XLit(lit = litOf(lit)))
      match coerceArg(env, t, pty) {
        case Some(c) -> Some(value = c)
        case None -> uncoveredExpr(env, call, "a default argument needing a conversion")
      }
    }
    case None -> uncoveredExpr(env, call, "a default argument declared in another package")
  }
}

/// A source-loaded default that is a bare payload-free case (`None`, `Tls12`): the case of the
/// parameter's own union or enum, constructed at the parameter's type.  Any other shape is counted.
func buildForeignCaseDefault(env: in BuildEnv, call: in Expr, d: in Expr, pty: in Ty): Option[TExpr] {
  val name = match d.kind { case EPath(p) -> if p.segments.count == 1 { p.segments[0] } else { "" }; case _ -> "" }
  val parent = match pty { case TNamed(sym, _) -> Some(value = sym); case _ -> None }
  if name != "" {
    match parent {
      case Some(par) -> match nullaryCaseOf(env, par, name) {
        case Some(cs) -> {
          noteCaseSym(env, cs)
          return Some(
            value = TExpr(
              id = freshNodeId(env),
              ty = pty,
              span = call.span,
              kind = XConstruct(sym = cs, fields = newList())
            )
          )
        }
        case None -> ()
      }
      case None -> ()
    }
  }
  uncoveredExpr(env, call, "a default argument declared in another package")
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
  env: in BuildEnv,
  e: in Expr,
  callee: in SymbolId,
  sig: in ResolvedSignature,
  ptys: in List[Ty],
  args: in List[CallArg],
  pre: in List[TStmt],
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
          match buildDefaultArg(env, e, callee, sig.originPackage, p, ptys, i) {
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
        case PMIn -> match paramTyAt(env, ptys, i, p) {
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
                if reordered and (not isPlainArg(x) or readsBeforeLaterCall(slots, srcIdx, i)) {
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
