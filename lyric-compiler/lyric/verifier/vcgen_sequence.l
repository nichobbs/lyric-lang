//! verifier/vcgen_sequence.l — evaluation-order sequencing: hoisting of propagating (?) operands.
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

// A statement rewritten so its `?`s are bindings of their own: the
// statements to walk in its place, or why it cannot be (`reason`).
record Hoisted {
  stmts: List[Statement]
  reason: String
}

// The bindings a statement's `?`s are hoisted into, in order.
record HoistCtx {
  env: VEnv
  prefix: List[Statement]
}

// `st` with its `?`s hoisted, or `None` when it has none this pass splits
// (a loop's are left to the loop, which fails closed on them).
func hoistPropagates(env: in VEnv, st: in Statement): Option[Hoisted] {
  if not stmtOwnsPropagate(st) {
    return None
  }
  val pre: List[Statement] = newList()
  val ctx = HoistCtx(env = env, prefix = pre)
  val rebuilt: Result[StatementKind, String] = match st.kind {
    case SLocal(binding) -> match binding {
      case LBVal(pat, ty, init) -> match hoistExpr(ctx, init) {
        case Ok(x) -> Ok(
          value = SLocal(
            binding = LBVal(
              pat = pat,
              ty = ty,
              init = x
            )
          )
        )
        case Err(r) -> Err(
          error = r
        )
      }
      case LBLet(n, ty, init) -> match hoistExpr(ctx, init) {
        case Ok(x) -> Ok(
          value = SLocal(
            binding = LBLet(
              name = n,
              ty = ty,
              init = x
            )
          )
        )
        case Err(r) -> Err(
          error = r
        )
      }
      case LBVar(n, ty, Some(init)) -> match hoistExpr(ctx, init) {
        case Ok(x) -> Ok(
          value = SLocal(
            binding = LBVar(
              name = n,
              ty = ty,
              init = Some(
                value = x
              )
            )
          )
        )
        case Err(r) -> Err(
          error = r
        )
      }
      case LBVar(_, _, None) -> Err(
        error = "a `?` in an uninitialized binding"
      )
    }
    case SAssign(target, op, value) -> match hoistAssign(ctx, target, op, value) {
      case Ok(v) -> Ok(
        value = SAssign(
          target = target,
          op = op,
          value = v
        )
      )
      case Err(r) -> Err(error = r)
    }
    case SReturn(Some(e)) -> match hoistExpr(ctx, e) {
      case Ok(x) -> Ok(
        value = SReturn(
          value = Some(
            value = x
          )
        )
      )
      case Err(r) -> Err(error = r)
    }
    case SExpr(e) -> match e.kind {
      // A statement `if` walks its branches as statements, which split
      // their own `?`s; only its condition is this statement's.
      case EIf(cond, thenBranch, elseBranch, thenForm) -> match hoistExpr(ctx, cond) {
        case Ok(c2) -> Ok(
          value = SExpr(
            expr = Expr(
              kind = EIf(
                cond = c2,
                thenBranch = thenBranch,
                elseBranch = elseBranch,
                thenForm = thenForm
              ),
              span = e.span
            )
          )
        )
        case Err(r) -> Err(
          error = r
        )
      }
      case EAssign(target, op, value) -> match hoistAssign(ctx, target, op, value) {
        case Ok(v) -> Ok(
          value = SExpr(
            expr = Expr(
              kind = EAssign(
                target = target,
                op = op,
                value = v
              ),
              span = e.span
            )
          )
        )
        case Err(r) -> Err(
          error = r
        )
      }
      case _ -> match hoistExpr(ctx, e) {
        case Ok(x) -> Ok(
          value = SExpr(expr = x)
        )
        case Err(r) -> Err(error = r)
      }
    }
    case _ -> Err(
      error = "a `?` in a statement the verifier does not split at"
    )
  }
  match rebuilt {
    case Ok(kind) -> {
      val outList: List[Statement] = newList()
      appendStmtList(outList, ctx.prefix)
      outList.add(Statement(kind = kind, span = st.span))
      Some(value = Hoisted(stmts = outList, reason = ""))
    }
    case Err(r) -> {
      val noStmts: List[Statement] = newList()
      Some(value = Hoisted(stmts = noStmts, reason = r))
    }
  }
}

// Whether `st` evaluates a `?` itself, unconditionally: in a binding's
// initializer, an assignment, a `return`, an expression statement, or a
// statement `if`'s condition (its branches are statements of their own).
// A loop's `?`s are the loop's, which fails closed on them.
func stmtOwnsPropagate(st: in Statement): Bool {
  match st.kind {
    case SLocal(binding) -> match binding {
      case LBVal(_, _, init) -> exprHasPropagate(init)
      case LBLet(_, _, init) -> exprHasPropagate(init)
      case LBVar(_, _, Some(init)) -> exprHasPropagate(init)
      case LBVar(_, _, None) -> false
    }
    case SAssign(target, _, value) -> exprHasPropagate(target) or exprHasPropagate(value)
    case SReturn(Some(e)) -> exprHasPropagate(e)
    case SExpr(e) -> match tryExtractIf(e) {
      case Some(triple) -> exprHasPropagate(triple.cond)
      case None -> exprHasPropagate(e)
    }
    case _ -> false
  }
}

// The value of `target op= value` with its `?`s hoisted.  A compound
// assignment reads its target before the value runs, so a value that
// changes the target's variable cannot be hoisted ahead of that read.
func hoistAssign(ctx: in HoistCtx, target: in Expr, op: in AssignOp, value: in Expr): Result[Expr, String] {
  if exprHasPropagate(target) {
    return Err(error = "a `?` in the target of an assignment")
  }
  val compound = match op { case AssEq -> false; case _ -> true }
  if compound {
    match rootVarOf(target) {
      case Some(root) -> {
        if effectsOfExpr(ctx.env, value).outArgs.contains(root) {
          return Err(error = "a `?` in a compound assignment whose value changes '" + root + "'")
        }
      }
      case None -> ()
    }
  }
  hoistExpr(ctx, value)
}

func pathExprOf(name: in String, sp: in Span): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  Expr(kind = EPath(path = ModulePath(segments = segs, span = sp)), span = sp)
}

func bindingStmt(name: in String, init: in Expr): Statement {
  val pat = Pattern(kind = PBinding(name = name, inner = None), span = init.span)
  Statement(kind = SLocal(binding = LBVal(pat = pat, ty = None, init = init)), span = init.span)
}

// `e` with each `?` in it, and everything evaluated before one, moved
// into `ctx.prefix` as bindings in evaluation order.
func hoistExpr(ctx: in HoistCtx, e: in Expr): Result[Expr, String] {
  if not exprHasPropagate(e) {
    return Ok(value = e)
  }
  match e.kind {
    case EPropagate(inner) -> match hoistExpr(ctx, inner) {
      case Ok(x) -> {
        val name = freshName(ctx.env, "q")
        ctx.prefix.add(bindingStmt(name, Expr(kind = EPropagate(inner = x), span = e.span)))
        Ok(value = pathExprOf(name, e.span))
      }
      case Err(r) -> Err(error = r)
    }
    case EParen(inner) -> match hoistExpr(ctx, inner) {
      case Ok(x) -> Ok(value = Expr(kind = EParen(inner = x), span = e.span))
      case Err(r) -> Err(error = r)
    }
    case EPrefix(op, operand) -> match hoistExpr(ctx, operand) {
      case Ok(x) -> Ok(value = Expr(kind = EPrefix(op = op, operand = x), span = e.span))
      case Err(r) -> Err(error = r)
    }
    case EMember(receiver, memberName) -> match hoistExpr(ctx, receiver) {
      case Ok(x) -> Ok(
        value = Expr(
          kind = EMember(
            receiver = x,
            memberName = memberName
          ),
          span = e.span
        )
      )
      case Err(r) -> Err(error = r)
    }
    case EBinop(op, lhs, rhs) -> {
      val shortCircuit = match op { case BAnd | BOr | BImplies | BCoalesce -> true; case _ -> false }
      if shortCircuit and exprHasPropagate(rhs) {
        return Err(error = "a `?` in the right operand of `and`, `or`, `implies` or `??`, which runs only conditionally")
      }
      val ops: List[Expr] = newList()
      ops.add(lhs)
      ops.add(rhs)
      match hoistOperands(ctx, ops, noPins()) {
        case Ok(xs) -> Ok(value = Expr(kind = EBinop(op = op, lhs = xs[0], rhs = xs[1]), span = e.span))
        case Err(r) -> Err(error = r)
      }
    }
    case ECall(fn, args) -> hoistCall(ctx, e, fn, args)
    case ETuple(exprs) -> match hoistOperands(ctx, exprs, noPins()) {
      case Ok(xs) -> Ok(value = Expr(kind = ETuple(exprs = xs), span = e.span))
      case Err(r) -> Err(error = r)
    }
    case EList(exprs) -> match hoistOperands(ctx, exprs, noPins()) {
      case Ok(xs) -> Ok(value = Expr(kind = EList(exprs = xs), span = e.span))
      case Err(r) -> Err(error = r)
    }
    case EIndex(receiver, indices) -> {
      val ops: List[Expr] = newList()
      ops.add(receiver)
      appendExprList(ops, indices)
      match hoistOperands(ctx, ops, noPins()) {
        case Ok(xs) -> {
          val newIndices: List[Expr] = newList()
          var i = 1
          while i < xs.count {
            newIndices.add(xs[i])
            i = i + 1
          }
          Ok(value = Expr(kind = EIndex(receiver = xs[0], indices = newIndices), span = e.span))
        }
        case Err(r) -> Err(error = r)
      }
    }
    case EInterpolated(segments) -> {
      val ops: List[Expr] = newList()
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISExpr(x) -> ops.add(x)
          case ISText(_, _) -> ()
        }
        i = i + 1
      }
      match hoistOperands(ctx, ops, noPins()) {
        case Ok(xs) -> {
          val newSegs: List[InterpolatedSegment] = newList()
          var k = 0
          var j = 0
          while j < segments.count {
            match segments[j] {
              case ISExpr(_) -> {
                newSegs.add(ISExpr(expr = xs[k]))
                k = k + 1
              }
              case ISText(text, tsp) -> newSegs.add(ISText(text = text, span = tsp))
            }
            j = j + 1
          }
          Ok(value = Expr(kind = EInterpolated(segments = newSegs), span = e.span))
        }
        case Err(r) -> Err(error = r)
      }
    }
    case EIf(cond, thenBranch, elseBranch, thenForm) -> {
      val inElse = match elseBranch { case Some(eb) -> eobHasPropagate(eb); case None -> false }
      if eobHasPropagate(thenBranch) or inElse {
        return Err(error = "a `?` in a branch of an `if` expression, which runs only conditionally")
      }
      match hoistExpr(ctx, cond) {
        case Ok(c2) -> Ok(
          value = Expr(
            kind = EIf(
              cond = c2,
              thenBranch = thenBranch,
              elseBranch = elseBranch,
              thenForm = thenForm
            ),
            span = e.span
          )
        )
        case Err(r) -> Err(error = r)
      }
    }
    case EMatch(scrutinee, arms) -> {
      var ai = 0
      while ai < arms.count {
        val inGuard = match arms[ai].guard { case Some(g) -> exprHasPropagate(g); case None -> false }
        if inGuard or eobHasPropagate(arms[ai].body) {
          return Err(error = "a `?` in an arm of a `match` expression, which runs only conditionally")
        }
        ai = ai + 1
      }
      match hoistExpr(ctx, scrutinee) {
        case Ok(s2) -> Ok(value = Expr(kind = EMatch(scrutinee = s2, arms = arms), span = e.span))
        case Err(r) -> Err(error = r)
      }
    }
    case ELambda(_, _) -> Err(error = "a `?` inside a lambda")
    case EBlock(_) -> Err(error = "a `?` inside a block used as a value")
    case EUnsafe(_) -> Err(error = "a `?` inside an `unsafe` block used as a value")
    case _ -> Err(error = "a `?` inside an expression the verifier does not split at")
  }
}

// `ops`, evaluated left to right, with the `?`s in them hoisted: every
// operand before the last one holding a `?` is bound first, so it is still
// evaluated before that `?` runs.  A literal, or a `val` the code cannot
// change, reads the same wherever it is evaluated and stays in place, as
// does an operand `pinned` marks: a place the call writes or reads in
// place — an `out`/`inout` argument, a method's receiver — which must stay
// the variable itself, never a copy (D171).
func hoistOperands(ctx: in HoistCtx, ops: in List[Expr], pinned: in List[Bool]): Result[List[Expr], String] {
  var last = -1
  var i = 0
  while i < ops.count {
    if exprHasPropagate(ops[i]) {
      last = i
    }
    i = i + 1
  }
  val outList: List[Expr] = newList()
  i = 0
  while i < ops.count {
    if i < last {
      match hoistExpr(ctx, ops[i]) {
        case Ok(x) -> outList.add(if i < pinned.count and pinned[i] { x } else { spillOperand(ctx, x) })
        case Err(r) -> {
          return Err(error = r)
        }
      }
    } else if i == last {
      match hoistExpr(ctx, ops[i]) {
        case Ok(x) -> outList.add(x)
        case Err(r) -> {
          return Err(error = r)
        }
      }
    } else {
      outList.add(ops[i])
    }
    i = i + 1
  }
  Ok(value = outList)
}

func spillOperand(ctx: in HoistCtx, x: in Expr): Expr {
  if operandIsStable(ctx.env, x) {
    x
  } else {
    val name = freshName(ctx.env, "s")
    ctx.prefix.add(bindingStmt(name, x))
    pathExprOf(name, x.span)
  }
}

func operandIsStable(env: in VEnv, x: in Expr): Bool {
  match x.kind {
    case ELiteral(_) -> true
    case EParen(inner) -> operandIsStable(env, inner)
    case EPrefix(op, operand) -> match op { case PreNeg -> operandIsStable(env, operand); case _ -> false }
    case EPath(path) -> path.segments.count == 1 and isSome(envLookup(path.segments[0], env)) and
      not env.mutables.contains(path.segments[0])
    case _ -> false
  }
}

// A call: its callee — a method's receiver, or a computed function — runs
// first, then its arguments as written, named ones included (D171); the
// hoisted arguments keep their names, so they still pair by name.
func hoistCall(ctx: in HoistCtx, e: in Expr, fn: in Expr, args: in List[CallArg]): Result[Expr, String] {
  val argExprs: List[Expr] = newList()
  var i = 0
  while i < args.count {
    argExprs.add(match args[i] { case CANamed(_, v, _) -> v; case CAPositional(v) -> v })
    i = i + 1
  }
  // What the callee position evaluates, if anything.
  val calleeOperand: Option[Expr] = match fn.kind {
    case EPath(_) -> None
    case ETypeApp(_, _) -> None
    case EMember(receiver, methodName) -> {
      if isSome(resolveStaticCallee(ctx.env, receiver, methodName, args)) or isSome(distinctFromCallee(ctx.env, fn)) {
        None
      } else {
        match qualifiedPathOf(receiver) {
          case Some(segs) -> if isSome(envLookup(segs[0], ctx.env)) { Some(value = receiver) } else { None }
          case None -> Some(value = receiver)
        }
      }
    }
    case _ -> Some(value = fn)
  }
  val ops: List[Expr] = newList()
  val pinned: List[Bool] = newList()
  // The variables this call itself writes through its `out`/`inout`
  // parameters and receiver (every mutable one, for a callee it does not
  // resolve).
  val ownEff = emptyEffects()
  effOutArgs(ctx.env, fn, args, ownEff)
  match calleeOperand {
    case Some(c) -> {
      ops.add(c)
      pinned.add(isSome(rootVarOf(c)))
    }
    case None -> ()
  }
  var pi = 0
  while pi < argExprs.count {
    ops.add(argExprs[pi])
    pinned.add(match rootVarOf(argExprs[pi]) { case Some(n) -> ownEff.outArgs.contains(n); case None -> false })
    pi = pi + 1
  }
  // A place stays where it is, but the operands up to the last `?` run
  // before the call: one that changes the place's variable would then run
  // before the place is used, so fail closed.
  var lastProp = -1
  var li = 0
  while li < ops.count {
    if exprHasPropagate(ops[li]) {
      lastProp = li
    }
    li = li + 1
  }
  var ki = 0
  while ki < ops.count {
    if pinned[ki] {
      match rootVarOf(ops[ki]) {
        case Some(n) -> {
          var kj = ki + 1
          while kj <= lastProp {
            if effectsOfExpr(ctx.env, ops[kj]).outArgs.contains(n) {
              return Err(
                error = "a `?` in an argument that changes '" + n +
                  "', which an earlier operand of the same call uses in place"
              )
            }
            kj = kj + 1
          }
        }
        case None -> ()
      }
    }
    ki = ki + 1
  }
  val hoisted = match hoistOperands(ctx, ops, pinned) { case Ok(xs) -> xs; case Err(r) -> { return Err(error = r) } }
  val offset = if isSome(calleeOperand) { 1 } else { 0 }
  val newFn: Expr = match calleeOperand {
    case Some(_) -> match fn.kind {
      case EMember(_, methodName) -> Expr(
        kind = EMember(
          receiver = hoisted[0],
          memberName = methodName
        ),
        span = fn.span
      )
      case _ -> hoisted[0]
    }
    case None -> fn
  }
  val newArgs: List[CallArg] = newList()
  var j = 0
  while j < args.count {
    val v = hoisted[j + offset]
    match args[j] {
      case CANamed(n, _, nsp) -> newArgs.add(CANamed(name = n, value = v, span = nsp))
      case CAPositional(_) -> newArgs.add(CAPositional(expr = v))
    }
    j = j + 1
  }
  Ok(value = Expr(kind = ECall(fn = newFn, args = newArgs), span = e.span))
}
