//! await_hoist.l — Lyric.AwaitHoist
//!
//! Statement-level ANF-style hoist for `await` in operand position (#5606).
//!
//! On `--target dotnet` an `async func` lowers to a state-machine `MoveNext`
//! whose suspension points must run with an empty CLR evaluation stack: any
//! value already pushed when an `await` suspends is lost across the resume
//! (the CLR does not preserve the operand stack between calls), so shapes
//! like `f(a, await e)` — where `a` is on the stack when `await e` suspends —
//! JIT-fail with `InvalidProgramException`, and nested awaits desync the
//! async-SM field pre-scan from emission.  The MSIL backend's binop-LHS
//! spill machinery (`phaseBSpillToLocal`) covers only the two-operand binop
//! case; call arguments, constructor arguments, method-call arguments (the
//! receiver counts as a stacked operand), list elements, index expressions,
//! and interpolation segments were all miscompiled.
//!
//! Rather than teach every call-lowering path to spill (the FieldDef budget
//! in `countSmFieldsMsil` must match emit-time spill registration EXACTLY
//! across a dozen paths — any desync corrupts every subsequent token), this
//! pass rewrites the AST once, before codegen, where the pre-scan and the
//! emitter see the same tree:
//!
//!     f(a, await e, b)   ⇒   val __lyric_hoist_0 = a
//!                            val __lyric_hoist_1 = await e
//!                            f(__lyric_hoist_0, __lyric_hoist_1, b)
//!
//! Every operand evaluated before the last await-bearing one is bound to a
//! fresh local first (preserving left-to-right evaluation order), so no
//! await remains in a position with operands already stacked.  `val x =
//! await t` is exactly the shape the async-SM machinery already compiles
//! correctly on both targets.
//!
//! The pass runs as the LAST middle-end rewrite (from
//! `Lyric.Pipeline.pipeWeave`, after aspect weaving) on every backend: the
//! rewrite is semantics-preserving on JVM and native (evaluation order is
//! unchanged), and keeping one tree across backends means the MSIL pre-scan,
//! MSIL emission, and the other targets can never diverge on these shapes.
//!
//! Scope — deliberately minimal (hoisting changes debug shape):
//!
//!   * Only `async func` bodies are rewritten (plain functions and lambdas
//!     resolve `await` with a blocking `GetAwaiter().GetResult()` shim that
//!     has no suspension, so their operand stacks are never at risk).
//!   * Only statements containing a QUALIFYING await are rewritten; shapes
//!     that already compile correctly — `await t` as a whole statement /
//!     initializer, first-argument awaits of free calls, plain binop
//!     operands (the spill path), `if`/`match` with awaits in arms bound to
//!     a `val` — are left byte-identical.
//!   * Awaits under `ELambda` and `ESpawn` bodies are deferred computations,
//!     not operands of the enclosing expression; the pass never descends
//!     into them.  `ETry` cannot contain an await in an async function
//!     (V0012), and hoisting out of it would change exception scoping, so it
//!     is opaque too.
//!   * A `while` condition with a qualifying await is rewritten into the
//!     equivalent `loop { <hoisted>; if cond { body } else { break } }` so
//!     the hoisted bindings re-evaluate on every iteration; `continue`
//!     re-enters at the loop head, preserving `while` semantics.
//!
//! Known non-goals (unchanged behaviour, still resolved by later emission
//! machinery or currently-rejected shapes): awaits in the RHS of the
//! short-circuit operators `and` / `or` / `??` are left in place inside a
//! bound temp (the branchy lowering evaluates them on an empty stack), and
//! `for`-iterable ranges keep their existing lowering.
//!
//! Public surface:
//!
//!   pub func hoistAwaitsFile(file: in SourceFile): SourceFile
//!
//!     Returns the file with every qualifying await hoisted.  The input is
//!     not mutated; items with nothing to hoist are returned as-is.
package Lyric.AwaitHoist

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// Fresh-name state threaded through the walk.  `counter` is a growable cell:
// its `.count` is the next fresh-name index (the `slotTicker` idiom), so a
// plain `in` reference suffices to mutate it.  The counter is per-file so
// hoist locals are unique across a whole function even when hoists occur in
// sibling blocks — the async-SM local promotion is keyed by NAME, so two
// same-named locals of different types would share one SM field.
record HoistState {
  counter: List[Int]
}

func ahFresh(st: in HoistState): String {
  val n = st.counter.count
  st.counter.add(0)
  "__lyric_hoist_" + toString(n)
}

// ─────────────────────────────────────────────────────────────────────────────
// §1. AST builders (span-stamped at the hoisted expression's span).
// ─────────────────────────────────────────────────────────────────────────────
func ahPath(name: in String, sp: in Span): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  mkExpr(EPath(path = ModulePath(segments = segs, span = sp)), sp)
}

// Bind `e` to a fresh `val` appended to `acc` and return a path expression
// reading it.  Literals are returned unchanged — re-evaluating a literal
// after the hoisted awaits is identical and binding it is pure noise.
func ahBind(e: in Expr, acc: in List[Statement], st: in HoistState): Expr {
  match e.kind {
    case ELiteral(_) -> e
    case _ -> {
      val name = ahFresh(st)
      val noTy: Option[TypeExpr] = None
      val noInner: Option[Pattern] = None
      val pat = mkPat(PBinding(name = name, inner = noInner), e.span)
      acc.add(mkStmt(SLocal(binding = LBVal(pat = pat, ty = noTy, init = e)), e.span))
      ahPath(name, e.span)
    }
  }
}

func ahArgExpr(a: in CallArg): Expr {
  match a {
    case CAPositional(v) -> v
    case CANamed(_, v, _) -> v
  }
}

func ahRebuildArg(a: in CallArg, e2: in Expr): CallArg {
  match a {
    case CAPositional(_) -> CAPositional(expr = e2)
    case CANamed(n, _, asp) -> CANamed(name = n, value = e2, span = asp)
  }
}

// A receiver that is just a (possibly dotted) name: a package/type qualifier
// or a plain local read.  Neither needs hoisting for order preservation —
// re-reading a name after the hoisted awaits is equivalent — and a package
// qualifier MUST NOT be bound to a local (it is not a value).
func ahIsNameLike(e: in Expr): Bool {
  match e.kind {
    case EPath(_) -> true
    case ESelf -> true
    case ELiteral(_) -> true
    case EMember(recv, _) -> ahIsNameLike(recv)
    case EParen(inner) -> ahIsNameLike(inner)
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Await presence.  True when evaluating `e` can execute an `await`.
//     Lambda and spawn operands are deferred computations (a lambda body runs
//     at call time, a spawned expression inside a task); `try` is opaque
//     (V0012 rejects awaits inside it in async functions).
// ─────────────────────────────────────────────────────────────────────────────
func ahHasAwait(e: in Expr): Bool {
  match e.kind {
    case EAwait(_) -> true
    case ELambda(_, _) -> false
    case ESpawn(_) -> false
    case ETry(_) -> false
    case EParen(inner) -> ahHasAwait(inner)
    case ETuple(exprs) -> ahHasAwaitList(exprs)
    case EList(exprs) -> ahHasAwaitList(exprs)
    case EIf(cond, thenB, elseO, _) -> {
      if ahHasAwait(cond) or ahHasAwaitEob(thenB) {
        true
      } else {
        match elseO {
          case Some(eb) -> ahHasAwaitEob(eb)
          case None -> false
        }
      }
    }
    case EMatch(scrutinee, arms) -> {
      if ahHasAwait(scrutinee) {
        return true
      }
      var i = 0
      while i < arms.count {
        val g = match arms[i].guard { case Some(ge) -> ahHasAwait(ge); case None -> false }
        if g or ahHasAwaitEob(arms[i].body) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EYield(inner) -> ahHasAwait(inner)
    case ECall(fn, args) -> {
      if ahHasAwait(fn) {
        return true
      }
      var i = 0
      while i < args.count {
        if ahHasAwait(ahArgExpr(args[i])) {
          return true
        }
        i = i + 1
      }
      false
    }
    case ETypeApp(fn, _) -> ahHasAwait(fn)
    case EIndex(receiver, indices) -> ahHasAwait(receiver) or ahHasAwaitList(indices)
    case EMember(receiver, _) -> ahHasAwait(receiver)
    case EPropagate(inner) -> ahHasAwait(inner)
    case EPrefix(_, operand) -> ahHasAwait(operand)
    case EBinop(_, lhs, rhs) -> ahHasAwait(lhs) or ahHasAwait(rhs)
    case ERange(bound) -> {
      match bound {
        case RBClosed(lo, hi) -> ahHasAwait(lo) or ahHasAwait(hi)
        case RBHalfOpen(lo, hi) -> ahHasAwait(lo) or ahHasAwait(hi)
        case RBLowerOpen(hi) -> ahHasAwait(hi)
        case RBUpperOpen(lo) -> ahHasAwait(lo)
      }
    }
    case EAssign(target, _, value) -> ahHasAwait(target) or ahHasAwait(value)
    case EBlock(blk) -> ahHasAwaitBlock(blk)
    case EUnsafe(blk) -> ahHasAwaitBlock(blk)
    case EInterpolated(segments) -> {
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISText(_, _) -> ()
          case ISExpr(ex) -> {
            if ahHasAwait(ex) {
              return true
            }
          }
        }
        i = i + 1
      }
      false
    }
    case _ -> false
  }
}

func ahHasAwaitList(es: in List[Expr]): Bool {
  var i = 0
  while i < es.count {
    if ahHasAwait(es[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func ahHasAwaitEob(eob: in ExprOrBlock): Bool {
  match eob {
    case EOBExpr(e) -> ahHasAwait(e)
    case EOBBlock(blk) -> ahHasAwaitBlock(blk)
  }
}

func ahHasAwaitBlock(blk: in Block): Bool {
  var i = 0
  while i < blk.statements.count {
    if ahHasAwaitStmt(blk.statements[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func ahHasAwaitStmt(s: in Statement): Bool {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> ahHasAwait(init)
        case LBLet(_, _, init) -> ahHasAwait(init)
        case LBVar(_, _, initOpt) -> {
          match initOpt {
            case Some(init) -> ahHasAwait(init)
            case None -> false
          }
        }
      }
    }
    case SAssign(target, _, value) -> ahHasAwait(target) or ahHasAwait(value)
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> ahHasAwait(e)
        case None -> false
      }
    }
    case SThrow(e) -> ahHasAwait(e)
    case SExpr(e) -> ahHasAwait(e)
    case SWhile(_, cond, body) -> ahHasAwait(cond) or ahHasAwaitBlock(body)
    case SFor(_, _, iter, body) -> ahHasAwait(iter) or ahHasAwaitBlock(body)
    case SLoop(_, body) -> ahHasAwaitBlock(body)
    case SScope(_, body) -> ahHasAwaitBlock(body)
    case SDefer(body) -> ahHasAwaitBlock(body)
    case STry(body, catches, finallyOpt) -> {
      if ahHasAwaitBlock(body) {
        return true
      }
      var i = 0
      while i < catches.count {
        if ahHasAwaitBlock(catches[i].body) {
          return true
        }
        i = i + 1
      }
      match finallyOpt {
        case Some(fb) -> ahHasAwaitBlock(fb)
        case None -> false
      }
    }
    case SInvariant(e) -> ahHasAwait(e)
    case SRule(lhs, rhs) -> ahHasAwait(lhs) or ahHasAwait(rhs)
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Qualification: does this subtree contain an await in a position that
//     leaves operands stacked across the suspension (or a nested await that
//     desyncs the pre-scan)?  Everything this predicate rejects is left
//     byte-identical by the rewrite.
// ─────────────────────────────────────────────────────────────────────────────
func ahLastAwaitArgIdx(args: in List[CallArg]): Int {
  var last = -1
  var i = 0
  while i < args.count {
    if ahHasAwait(ahArgExpr(args[i])) {
      last = i
    }
    i = i + 1
  }
  last
}

func ahNeedsHoist(e: in Expr): Bool {
  match e.kind {
    // A nested await: the inner await's completion is an operand of the
    // outer await's expression AND the pre-scan undercounts it (#5606).
    case EAwait(inner) -> ahHasAwait(inner) or ahNeedsHoist(inner)
    case ECall(fn, args) -> {
      val last = ahLastAwaitArgIdx(args)
      val memberCallee = match fn.kind { case EMember(_, _) -> true; case _ -> false }
      // Method calls stack the receiver before any argument, so ANY
      // await-bearing argument qualifies; free calls only stack earlier
      // arguments, so a first-and-only-await argument is already safe.
      if memberCallee and last >= 0 {
        return true
      }
      if last > 0 {
        return true
      }
      if ahNeedsHoist(fn) {
        return true
      }
      var i = 0
      while i < args.count {
        if ahNeedsHoist(ahArgExpr(args[i])) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EIndex(receiver, indices) -> {
      // The receiver is stacked before the index expressions evaluate.
      if ahHasAwaitList(indices) {
        return true
      }
      if ahNeedsHoist(receiver) {
        return true
      }
      var i = 0
      while i < indices.count {
        if ahNeedsHoist(indices[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    // List/tuple construction stacks the collection/earlier elements.
    case EList(exprs) -> ahHasAwaitList(exprs) or ahNeedsHoistList(exprs)
    case ETuple(exprs) -> ahHasAwaitList(exprs) or ahNeedsHoistList(exprs)
    // Interpolation stacks the accumulating string across segments.
    case EInterpolated(segments) -> {
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISText(_, _) -> ()
          case ISExpr(ex) -> {
            if ahHasAwait(ex) or ahNeedsHoist(ex) {
              return true
            }
          }
        }
        i = i + 1
      }
      false
    }
    // Plain binop awaits are covered by the emitter's LHS spill; only a
    // qualifying shape INSIDE an operand needs the hoist.
    case EBinop(_, lhs, rhs) -> ahNeedsHoist(lhs) or ahNeedsHoist(rhs)
    case EParen(inner) -> ahNeedsHoist(inner)
    case EPrefix(_, operand) -> ahNeedsHoist(operand)
    case EMember(receiver, _) -> ahNeedsHoist(receiver)
    case EYield(inner) -> ahNeedsHoist(inner)
    case ETypeApp(fn, _) -> ahNeedsHoist(fn)
    case EPropagate(inner) -> ahNeedsHoist(inner)
    case EAssign(_, _, value) -> ahNeedsHoist(value)
    case EIf(cond, thenB, elseO, _) -> {
      if ahNeedsHoist(cond) or ahNeedsHoistEob(thenB) {
        true
      } else {
        match elseO {
          case Some(eb) -> ahNeedsHoistEob(eb)
          case None -> false
        }
      }
    }
    case EMatch(scrutinee, arms) -> {
      if ahNeedsHoist(scrutinee) {
        return true
      }
      var i = 0
      while i < arms.count {
        if ahNeedsHoistEob(arms[i].body) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EBlock(blk) -> ahNeedsHoistBlock(blk)
    case EUnsafe(blk) -> ahNeedsHoistBlock(blk)
    case ERange(bound) -> {
      match bound {
        case RBClosed(lo, hi) -> ahNeedsHoist(lo) or ahNeedsHoist(hi)
        case RBHalfOpen(lo, hi) -> ahNeedsHoist(lo) or ahNeedsHoist(hi)
        case RBLowerOpen(hi) -> ahNeedsHoist(hi)
        case RBUpperOpen(lo) -> ahNeedsHoist(lo)
      }
    }
    case _ -> false
  }
}

func ahNeedsHoistList(es: in List[Expr]): Bool {
  var i = 0
  while i < es.count {
    if ahNeedsHoist(es[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func ahNeedsHoistEob(eob: in ExprOrBlock): Bool {
  match eob {
    case EOBExpr(e) -> ahNeedsHoist(e)
    case EOBBlock(blk) -> ahNeedsHoistBlock(blk)
  }
}

func ahNeedsHoistBlock(blk: in Block): Bool {
  var i = 0
  while i < blk.statements.count {
    if ahNeedsHoistStmt(blk.statements[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func ahNeedsHoistStmt(s: in Statement): Bool {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> ahNeedsHoist(init)
        case LBLet(_, _, init) -> ahNeedsHoist(init)
        case LBVar(_, _, initOpt) -> {
          match initOpt {
            case Some(init) -> ahNeedsHoist(init)
            case None -> false
          }
        }
      }
    }
    case SAssign(_, _, value) -> ahNeedsHoist(value)
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> ahNeedsHoist(e)
        case None -> false
      }
    }
    case SThrow(e) -> ahNeedsHoist(e)
    case SExpr(e) -> ahNeedsHoist(e)
    case SWhile(_, cond, body) -> ahNeedsHoist(cond) or ahNeedsHoistBlock(body)
    case SFor(_, _, iter, body) -> ahNeedsHoist(iter) or ahNeedsHoistBlock(body)
    case SLoop(_, body) -> ahNeedsHoistBlock(body)
    case SScope(_, body) -> ahNeedsHoistBlock(body)
    case SDefer(body) -> ahNeedsHoistBlock(body)
    case STry(body, catches, finallyOpt) -> {
      if ahNeedsHoistBlock(body) {
        return true
      }
      var i = 0
      while i < catches.count {
        if ahNeedsHoistBlock(catches[i].body) {
          return true
        }
        i = i + 1
      }
      match finallyOpt {
        case Some(fb) -> ahNeedsHoistBlock(fb)
        case None -> false
      }
    }
    case SItem(item) -> ahItemNeedsHoist(item)
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. The spine hoist.  `ahHoistSpine(e, acc, st)` appends bindings to `acc`
//     and returns a residual expression whose evaluation executes no await
//     (awaits under lambda/spawn/try are deferred, not executed).  Every
//     operand evaluated before a hoisted await is bound first, preserving
//     left-to-right evaluation order exactly.
// ─────────────────────────────────────────────────────────────────────────────
func ahHoistSpine(e: in Expr, acc: in List[Statement], st: in HoistState): Expr {
  if not ahHasAwait(e) {
    return e
  }
  match e.kind {
    case EAwait(inner) -> {
      val inner2 = ahHoistSpine(inner, acc, st)
      ahBind(mkExpr(EAwait(inner = inner2), e.span), acc, st)
    }
    case EParen(inner) -> mkExpr(EParen(inner = ahHoistSpine(inner, acc, st)), e.span)
    case ECall(fn, args) -> {
      val last = ahLastAwaitArgIdx(args)
      val fn2 = match fn.kind {
        case EMember(recv, nm) -> {
          val recv2 = if ahHasAwait(recv) {
            ahBind(ahHoistSpine(recv, acc, st), acc, st)
          } else if last >= 0 and not ahIsNameLike(recv) {
            ahBind(recv, acc, st)
          } else {
            recv
          }
          mkExpr(EMember(receiver = recv2, memberName = nm), fn.span)
        }
        case EPath(_) -> fn
        case _ -> {
          if ahHasAwait(fn) {
            ahBind(ahHoistSpine(fn, acc, st), acc, st)
          } else if last >= 0 {
            ahBind(fn, acc, st)
          } else {
            fn
          }
        }
      }
      val newArgs: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        val ae = ahArgExpr(args[i])
        var ae2 = ae
        if i < last {
          val h = if ahHasAwait(ae) { ahHoistSpine(ae, acc, st) } else { ae }
          ae2 = ahBind(h, acc, st)
        } else if i == last {
          ae2 = ahHoistSpine(ae, acc, st)
        }
        newArgs.add(ahRebuildArg(args[i], ae2))
        i = i + 1
      }
      mkExpr(ECall(fn = fn2, args = newArgs), e.span)
    }
    case EIndex(receiver, indices) -> {
      var last = -1
      var li = 0
      while li < indices.count {
        if ahHasAwait(indices[li]) {
          last = li
        }
        li = li + 1
      }
      val recv2 = if ahHasAwait(receiver) {
        ahBind(ahHoistSpine(receiver, acc, st), acc, st)
      } else if last >= 0 and not ahIsNameLike(receiver) {
        ahBind(receiver, acc, st)
      } else {
        receiver
      }
      val newIdx: List[Expr] = newList()
      var i = 0
      while i < indices.count {
        var ix2 = indices[i]
        if i < last {
          val h = if ahHasAwait(ix2) { ahHoistSpine(ix2, acc, st) } else { ix2 }
          ix2 = ahBind(h, acc, st)
        } else if i == last {
          ix2 = ahHoistSpine(ix2, acc, st)
        }
        newIdx.add(ix2)
        i = i + 1
      }
      mkExpr(EIndex(receiver = recv2, indices = newIdx), e.span)
    }
    case ETuple(exprs) -> mkExpr(ETuple(exprs = ahHoistElems(exprs, acc, st)), e.span)
    case EList(exprs) -> mkExpr(EList(exprs = ahHoistElems(exprs, acc, st)), e.span)
    case EInterpolated(segments) -> {
      var last = -1
      var si = 0
      while si < segments.count {
        match segments[si] {
          case ISText(_, _) -> ()
          case ISExpr(ex) -> {
            if ahHasAwait(ex) {
              last = si
            }
          }
        }
        si = si + 1
      }
      val newSegs: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISText(t, tsp) -> newSegs.add(ISText(text = t, span = tsp))
          case ISExpr(ex) -> {
            var ex2 = ex
            if i < last {
              val h = if ahHasAwait(ex) { ahHoistSpine(ex, acc, st) } else { ex }
              ex2 = ahBind(h, acc, st)
            } else if i == last {
              ex2 = ahHoistSpine(ex, acc, st)
            }
            newSegs.add(ISExpr(expr = ex2))
          }
        }
        i = i + 1
      }
      mkExpr(EInterpolated(segments = newSegs), e.span)
    }
    case EBinop(op, lhs, rhs) -> {
      val shortCircuit = match op {
        case BAnd -> true
        case BOr -> true
        case BCoalesce -> true
        case BImplies -> true
        case _ -> false
      }
      if shortCircuit {
        // The RHS is conditionally evaluated: awaits inside it cannot move
        // out.  Binding the whole (LHS-hoisted) operator expression to a
        // `val` makes its awaits run against an empty stack — the shape the
        // emitter already compiles correctly.
        val l2 = if ahHasAwait(lhs) { ahHoistSpine(lhs, acc, st) } else { lhs }
        if ahHasAwait(rhs) {
          ahBind(mkExpr(EBinop(op = op, lhs = l2, rhs = rhs), e.span), acc, st)
        } else {
          mkExpr(EBinop(op = op, lhs = l2, rhs = rhs), e.span)
        }
      } else if ahHasAwait(rhs) {
        val l2 = if ahHasAwait(lhs) { ahHoistSpine(lhs, acc, st) } else { lhs }
        val l3 = ahBind(l2, acc, st)
        val r2 = ahHoistSpine(rhs, acc, st)
        mkExpr(EBinop(op = op, lhs = l3, rhs = r2), e.span)
      } else {
        mkExpr(EBinop(op = op, lhs = ahHoistSpine(lhs, acc, st), rhs = rhs), e.span)
      }
    }
    case EPrefix(op, operand) -> mkExpr(EPrefix(op = op, operand = ahHoistSpine(operand, acc, st)), e.span)
    case EMember(receiver, memberName) -> mkExpr(EMember(receiver = ahHoistSpine(receiver, acc, st), memberName = memberName), e.span)
    case EYield(inner) -> mkExpr(EYield(inner = ahHoistSpine(inner, acc, st)), e.span)
    case ETypeApp(fn, targs) -> mkExpr(ETypeApp(fn = ahHoistSpine(fn, acc, st), args = targs), e.span)
    case EPropagate(inner) -> mkExpr(EPropagate(inner = ahHoistSpine(inner, acc, st)), e.span)
    case EAssign(target, op, value) -> mkExpr(EAssign(target = target, op = op, value = ahHoistSpine(value, acc, st)), e.span)
    case EIf(cond, thenB, elseO, thenForm) -> {
      // Arms are conditionally evaluated; rewrite them internally and bind
      // the whole `if` to a `val` — awaits inside a val-bound if/match arm
      // evaluate on an empty stack (the already-working shape).
      val cond2 = if ahHasAwait(cond) { ahHoistSpine(cond, acc, st) } else { cond }
      val then2 = ahHoistArm(thenB, st)
      val else2: Option[ExprOrBlock] = match elseO { case Some(eb) -> Some(value = ahHoistArm(eb, st)); case None -> None }
      val armsAwait = ahHasAwaitEob(thenB) or (match elseO { case Some(eb0) -> ahHasAwaitEob(eb0); case None -> false })
      val rebuilt = mkExpr(EIf(cond = cond2, thenBranch = then2, elseBranch = else2, thenForm = thenForm), e.span)
      if armsAwait {
        ahBind(rebuilt, acc, st)
      } else {
        rebuilt
      }
    }
    case EMatch(scrutinee, arms) -> {
      val scr2 = if ahHasAwait(scrutinee) { ahHoistSpine(scrutinee, acc, st) } else { scrutinee }
      var armsAwait = false
      val newArms: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        if ahHasAwaitEob(arm.body) {
          armsAwait = true
        }
        newArms.add(MatchArm(pattern = arm.pattern, guard = arm.guard, body = ahHoistArm(arm.body, st), span = arm.span))
        i = i + 1
      }
      val rebuilt = mkExpr(EMatch(scrutinee = scr2, arms = newArms), e.span)
      if armsAwait {
        ahBind(rebuilt, acc, st)
      } else {
        rebuilt
      }
    }
    case EBlock(blk) -> ahBind(mkExpr(EBlock(block = ahBlock(blk, st)), e.span), acc, st)
    case EUnsafe(blk) -> ahBind(mkExpr(EUnsafe(block = ahBlock(blk, st)), e.span), acc, st)
    case ERange(bound) -> {
      val newBound = match bound {
        case RBClosed(lo, hi) -> {
          if ahHasAwait(hi) {
            val lo2 = ahBind(ahHoistSpine(lo, acc, st), acc, st)
            RBClosed(lo = lo2, hi = ahHoistSpine(hi, acc, st))
          } else {
            RBClosed(lo = ahHoistSpine(lo, acc, st), hi = hi)
          }
        }
        case RBHalfOpen(lo, hi) -> {
          if ahHasAwait(hi) {
            val lo2 = ahBind(ahHoistSpine(lo, acc, st), acc, st)
            RBHalfOpen(lo = lo2, hi = ahHoistSpine(hi, acc, st))
          } else {
            RBHalfOpen(lo = ahHoistSpine(lo, acc, st), hi = hi)
          }
        }
        case RBLowerOpen(hi) -> RBLowerOpen(hi = ahHoistSpine(hi, acc, st))
        case RBUpperOpen(lo) -> RBUpperOpen(lo = ahHoistSpine(lo, acc, st))
      }
      mkExpr(ERange(bound = newBound), e.span)
    }
    case _ -> e
  }
}

// Positional hoist shared by tuple and list element lists.
func ahHoistElems(exprs: in List[Expr], acc: in List[Statement], st: in HoistState): List[Expr] {
  var last = -1
  var li = 0
  while li < exprs.count {
    if ahHasAwait(exprs[li]) {
      last = li
    }
    li = li + 1
  }
  val newExprs: List[Expr] = newList()
  var i = 0
  while i < exprs.count {
    var el2 = exprs[i]
    if i < last {
      val h = if ahHasAwait(el2) { ahHoistSpine(el2, acc, st) } else { el2 }
      el2 = ahBind(h, acc, st)
    } else if i == last {
      el2 = ahHoistSpine(el2, acc, st)
    }
    newExprs.add(el2)
    i = i + 1
  }
  newExprs
}

// Rewrite an if/match arm internally: block arms recurse the statement
// driver; expression arms that need hoisting become value-producing blocks
// carrying their own bindings.
func ahHoistArm(eob: in ExprOrBlock, st: in HoistState): ExprOrBlock {
  match eob {
    case EOBExpr(ae) -> {
      if ahNeedsHoist(ae) {
        val acc2: List[Statement] = newList()
        val ae2 = ahHoistTop(ae, acc2, st)
        if acc2.count == 0 {
          EOBExpr(expr = ae2)
        } else {
          acc2.add(mkStmt(SExpr(expr = ae2), ae.span))
          EOBBlock(block = Block(statements = acc2, span = ae.span))
        }
      } else {
        eob
      }
    }
    case EOBBlock(blk) -> EOBBlock(block = ahBlock(blk, st))
  }
}

// Statement-position hoist: control-flow expressions that ARE the statement
// keep their shape (arms rewritten in place, no binding); everything else
// takes the spine hoist.
func ahHoistTop(e: in Expr, acc: in List[Statement], st: in HoistState): Expr {
  match e.kind {
    case EIf(cond, thenB, elseO, thenForm) -> {
      val cond2 = if ahNeedsHoist(cond) { ahHoistSpine(cond, acc, st) } else { cond }
      val else2: Option[ExprOrBlock] = match elseO { case Some(eb) -> Some(value = ahHoistArm(eb, st)); case None -> None }
      mkExpr(EIf(cond = cond2, thenBranch = ahHoistArm(thenB, st), elseBranch = else2, thenForm = thenForm), e.span)
    }
    case EMatch(scrutinee, arms) -> {
      val scr2 = if ahNeedsHoist(scrutinee) { ahHoistSpine(scrutinee, acc, st) } else { scrutinee }
      val newArms: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        newArms.add(MatchArm(pattern = arm.pattern, guard = arm.guard, body = ahHoistArm(arm.body, st), span = arm.span))
        i = i + 1
      }
      mkExpr(EMatch(scrutinee = scr2, arms = newArms), e.span)
    }
    case EBlock(blk) -> mkExpr(EBlock(block = ahBlock(blk, st)), e.span)
    case EUnsafe(blk) -> mkExpr(EUnsafe(block = ahBlock(blk, st)), e.span)
    case EParen(inner) -> mkExpr(EParen(inner = ahHoistTop(inner, acc, st)), e.span)
    case _ -> ahHoistSpine(e, acc, st)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Statement / block drivers.
// ─────────────────────────────────────────────────────────────────────────────
func ahStmt(s: in Statement, dest: in List[Statement], st: in HoistState): Unit {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(pat, ty, init) -> {
          if ahNeedsHoist(init) {
            val init2 = ahHoistTop(init, dest, st)
            dest.add(mkStmt(SLocal(binding = LBVal(pat = pat, ty = ty, init = init2)), s.span))
          } else {
            dest.add(s)
          }
        }
        case LBLet(name, ty, init) -> {
          if ahNeedsHoist(init) {
            val init2 = ahHoistTop(init, dest, st)
            dest.add(mkStmt(SLocal(binding = LBLet(name = name, ty = ty, init = init2)), s.span))
          } else {
            dest.add(s)
          }
        }
        case LBVar(name, ty, initOpt) -> {
          match initOpt {
            case Some(init) -> {
              if ahNeedsHoist(init) {
                val init2 = ahHoistTop(init, dest, st)
                dest.add(mkStmt(SLocal(binding = LBVar(name = name, ty = ty, init = Some(value = init2))), s.span))
              } else {
                dest.add(s)
              }
            }
            case None -> dest.add(s)
          }
        }
      }
    }
    case SAssign(target, op, value) -> {
      if ahNeedsHoist(value) {
        val value2 = ahHoistTop(value, dest, st)
        dest.add(mkStmt(SAssign(target = target, op = op, value = value2), s.span))
      } else {
        dest.add(s)
      }
    }
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> {
          if ahNeedsHoist(e) {
            val e2 = ahHoistTop(e, dest, st)
            dest.add(mkStmt(SReturn(value = Some(value = e2)), s.span))
          } else {
            dest.add(s)
          }
        }
        case None -> dest.add(s)
      }
    }
    case SThrow(e) -> {
      if ahNeedsHoist(e) {
        val e2 = ahHoistTop(e, dest, st)
        dest.add(mkStmt(SThrow(expr = e2), s.span))
      } else {
        dest.add(s)
      }
    }
    case SExpr(e) -> {
      if ahNeedsHoist(e) {
        val e2 = ahHoistTop(e, dest, st)
        dest.add(mkStmt(SExpr(expr = e2), s.span))
      } else {
        dest.add(s)
      }
    }
    case SWhile(label, cond, body) -> {
      val body2 = ahBlock(body, st)
      if ahNeedsHoist(cond) {
        // The condition re-evaluates each iteration, so its bindings must
        // live inside the loop:  loop { <hoisted>; if cond { body } else
        // { break } }.  `continue` re-enters at the loop head (the hoisted
        // bindings), `break` exits — exactly `while` semantics.
        val loopStmts: List[Statement] = newList()
        val cond2 = ahHoistSpine(cond, loopStmts, st)
        val noLabel: Option[String] = None
        val breakStmts: List[Statement] = newList()
        breakStmts.add(mkStmt(SBreak(label = noLabel), s.span))
        val breakArm: ExprOrBlock = EOBBlock(block = Block(statements = breakStmts, span = s.span))
        val bodyArm: ExprOrBlock = EOBBlock(block = body2)
        val guarded = mkExpr(
          EIf(cond = cond2, thenBranch = bodyArm, elseBranch = Some(value = breakArm), thenForm = false),
          s.span
        )
        loopStmts.add(mkStmt(SExpr(expr = guarded), s.span))
        dest.add(mkStmt(SLoop(label = label, body = Block(statements = loopStmts, span = s.span)), s.span))
      } else {
        dest.add(mkStmt(SWhile(label = label, cond = cond, body = body2), s.span))
      }
    }
    case SFor(label, pat, iter, body) -> {
      val iter2 = if ahNeedsHoist(iter) { ahHoistTop(iter, dest, st) } else { iter }
      dest.add(mkStmt(SFor(label = label, pat = pat, iter = iter2, body = ahBlock(body, st)), s.span))
    }
    case SLoop(label, body) -> dest.add(mkStmt(SLoop(label = label, body = ahBlock(body, st)), s.span))
    case SScope(binding, body) -> dest.add(mkStmt(SScope(binding = binding, body = ahBlock(body, st)), s.span))
    case SDefer(body) -> dest.add(mkStmt(SDefer(body = ahBlock(body, st)), s.span))
    case STry(body, catches, finallyOpt) -> {
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val c = catches[i]
        newCatches.add(CatchClause(typeName = c.typeName, bindName = c.bindName, body = ahBlock(c.body, st), span = c.span))
        i = i + 1
      }
      val newFinally: Option[Block] = match finallyOpt { case Some(fb) -> Some(value = ahBlock(fb, st)); case None -> None }
      dest.add(mkStmt(STry(body = ahBlock(body, st), catches = newCatches, finally_ = newFinally), s.span))
    }
    case SItem(item) -> dest.add(mkStmt(SItem(item = ahRewriteItem(item, st)), s.span))
    case _ -> dest.add(s)
  }
}

func ahBlock(blk: in Block, st: in HoistState): Block {
  val dest: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    ahStmt(blk.statements[i], dest, st)
    i = i + 1
  }
  Block(statements = dest, span = blk.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Function / item drivers.  Only `async func` bodies are rewritten — a
//     blocking (non-async) await has no suspension, so its operand stack is
//     never at risk — and only when something actually qualifies, so the
//     pass is identity for everything else.
// ─────────────────────────────────────────────────────────────────────────────
func ahBodyNeedsHoist(body: in FunctionBody): Bool {
  match body {
    case FBBlock(blk) -> ahNeedsHoistBlock(blk)
    case FBExpr(e) -> ahNeedsHoist(e)
  }
}

func ahFunctionNeedsHoist(fn: in FunctionDecl): Bool {
  if not fn.isAsync {
    return false
  }
  match fn.body {
    case Some(body) -> ahBodyNeedsHoist(body)
    case None -> false
  }
}

func ahRewriteFunction(fn: in FunctionDecl, st: in HoistState): FunctionDecl {
  if not ahFunctionNeedsHoist(fn) {
    return fn
  }
  val body = match fn.body { case Some(b) -> b; case None -> return fn }
  val newBody: FunctionBody = match body {
    case FBBlock(blk) -> FBBlock(block = ahBlock(blk, st))
    case FBExpr(e) -> {
      val acc: List[Statement] = newList()
      val e2 = ahHoistTop(e, acc, st)
      if acc.count == 0 {
        FBExpr(expr = e2)
      } else {
        acc.add(mkStmt(SExpr(expr = e2), e.span))
        FBBlock(block = Block(statements = acc, span = e.span))
      }
    }
  }
  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = fn.name,
    generics = fn.generics,
    params = fn.params,
    ret = fn.ret,
    whereClause = fn.whereClause,
    contracts = fn.contracts,
    body = Some(value = newBody),
    span = fn.span
  )
}

func ahItemNeedsHoist(it: in Item): Bool {
  match it.kind {
    case IFunc(fn) -> ahFunctionNeedsHoist(fn)
    case IImpl(decl) -> {
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMplFunc(fn) -> {
            if ahFunctionNeedsHoist(fn) {
              return true
            }
          }
          case _ -> ()
        }
        i = i + 1
      }
      false
    }
    case IInterface(decl) -> {
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMFunc(fn) -> {
            if ahFunctionNeedsHoist(fn) {
              return true
            }
          }
          case _ -> ()
        }
        i = i + 1
      }
      false
    }
    case IRecord(decl) -> ahRecordNeedsHoist(decl)
    case IExposedRec(decl) -> ahRecordNeedsHoist(decl)
    case IProtected(decl) -> {
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case PMFunc(fn) -> {
            if ahFunctionNeedsHoist(fn) {
              return true
            }
          }
          case _ -> ()
        }
        i = i + 1
      }
      false
    }
    case _ -> false
  }
}

func ahRecordNeedsHoist(decl: in RecordDecl): Bool {
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMFunc(fn) -> {
        if ahFunctionNeedsHoist(fn) {
          return true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

func ahRewriteItem(it: in Item, st: in HoistState): Item {
  if not ahItemNeedsHoist(it) {
    return it
  }
  val newKind: ItemKind = match it.kind {
    case IFunc(fn) -> IFunc(decl = ahRewriteFunction(fn, st))
    case IImpl(decl) -> {
      val newMembers: List[ImplMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMplFunc(fn) -> newMembers.add(IMplFunc(fn = ahRewriteFunction(fn, st)))
          case IMplAssoc(asc) -> newMembers.add(IMplAssoc(assoc = asc))
        }
        i = i + 1
      }
      IImpl(
        decl = ImplDecl(
          generics = decl.generics,
          iface = decl.iface,
          target = decl.target,
          whereClause = decl.whereClause,
          members = newMembers,
          span = decl.span
        )
      )
    }
    case IInterface(decl) -> {
      val newMembers: List[InterfaceMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMFunc(fn) -> newMembers.add(IMFunc(fn = ahRewriteFunction(fn, st)))
          case IMSig(sig) -> newMembers.add(IMSig(sig = sig))
          case IMAssoc(a) -> newMembers.add(IMAssoc(assoc = a))
        }
        i = i + 1
      }
      IInterface(
        decl = InterfaceDecl(
          name = decl.name,
          generics = decl.generics,
          whereClause = decl.whereClause,
          members = newMembers,
          span = decl.span
        )
      )
    }
    case IRecord(decl) -> IRecord(decl = ahRewriteRecord(decl, st))
    case IExposedRec(decl) -> IExposedRec(decl = ahRewriteRecord(decl, st))
    case IProtected(decl) -> {
      val newMembers: List[ProtectedMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case PMFunc(fn) -> newMembers.add(PMFunc(fn = ahRewriteFunction(fn, st)))
          case PMEntry(ed) -> newMembers.add(PMEntry(entryDecl = ed))
          case PMField(f) -> newMembers.add(PMField(field = f))
          case PMInvariant(v) -> newMembers.add(PMInvariant(inv = v))
        }
        i = i + 1
      }
      IProtected(
        decl = ProtectedTypeDecl(
          name = decl.name,
          generics = decl.generics,
          whereClause = decl.whereClause,
          members = newMembers,
          span = decl.span
        )
      )
    }
    case _ -> it.kind
  }
  Item(
    docComments = it.docComments,
    annotations = it.annotations,
    visibility = it.visibility,
    kind = newKind,
    span = it.span
  )
}

func ahRewriteRecord(decl: in RecordDecl, st: in HoistState): RecordDecl {
  val newMembers: List[RecordMember] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMFunc(fn) -> newMembers.add(RMFunc(fn = ahRewriteFunction(fn, st)))
      case RMField(f) -> newMembers.add(RMField(field = f))
      case RMInvariant(inv) -> newMembers.add(RMInvariant(inv = inv))
    }
    i = i + 1
  }
  RecordDecl(
    name = decl.name,
    generics = decl.generics,
    whereClause = decl.whereClause,
    members = newMembers,
    span = decl.span
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Public entry point.
// ─────────────────────────────────────────────────────────────────────────────
pub func hoistAwaitsFile(file: in SourceFile): SourceFile {
  var any = false
  var i = 0
  while i < file.items.count {
    if ahItemNeedsHoist(file.items[i]) {
      any = true
      i = file.items.count
    } else {
      i = i + 1
    }
  }
  if not any {
    return file
  }
  val st = HoistState(counter = newList())
  val newItems: List[Item] = newList()
  var j = 0
  while j < file.items.count {
    newItems.add(ahRewriteItem(file.items[j], st))
    j = j + 1
  }
  SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = newItems,
    span = file.span
  )
}
