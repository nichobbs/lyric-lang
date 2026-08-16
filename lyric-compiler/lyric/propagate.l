//! propagate.l — Lyric.Propagate
//!
//! Band 2 (docs/41 §9, issue #1475): error-propagation lowering for the `?`
//! operator.  Until this pass existed the MSIL backend lowered `EPropagate`
//! as a pass-through (`x?` compiled as `x`), a silent miscompile of every
//! program using `?`.
//!
//! This pass runs in the middle-end (after the contract elaborator, before
//! derive/mono/weave) and rewrites every `e?` into a `match` that unwraps the
//! success value and early-returns the failure from the enclosing function.
//! The monad is keyed off the enclosing function's declared return type, per
//! the language-reference §4.5 rule that "the signature must declare a
//! compatible return type, or the compiler rejects the use":
//!
//!   * Function returns `Result[T, E]` — `e?` becomes
//!         match e { case Ok(v)  -> v
//!                   case Err(x) -> { return Err(x) } }
//!
//!   * Function returns `Option[T]` — `e?` becomes
//!         match e { case Some(v) -> v
//!                   case None    -> { return None } }
//!
//! The synthesised AST mirrors exactly what the parser produces for a
//! hand-written `match` / `return`, so codegen lowers it through the same
//! (well-tested) machinery: `lowerMatchExprMsil` already reconciles an
//! early-return arm with a value-producing fall-through arm, and the
//! reconstructed `Err(x)` / `None` constructors pick up their concrete type
//! arguments from `fctx.declaredRetTy` exactly as a user-written
//! `return Err(x)` / `return None` does.
//!
//! Running after the elaborator (not before) keeps the `?` error path out of
//! the `ensures:` rewrite: a propagated `Err` / `None` is a short-circuit, not
//! the function's intended result, so it must not be asserted against the
//! success-shaped post-condition.
//!
//! Return types written through a same-file type alias (e.g.
//! `alias ParseResult[T] = Result[T, ParseError]`) are unfolded through the
//! file's alias declarations before classification (#1814).
//!
//! When `?` appears in a function whose return type is neither `Result` nor
//! `Option` (or inside a lambda, whose return monad the backend cannot yet
//! determine), the pass emits a hard `F0020` diagnostic instead of a silent
//! pass-through.  Nullable (`T?`) propagation is not yet lowered and takes the
//! same diagnostic; it is tracked as a follow-up.
//!
//! §2b (#6448) runs a statement-level ANF hoist BEFORE the match rewrite
//! above, for `?` found in operand position (a method-call argument — the
//! receiver is a stacked operand ahead of it — or a non-first argument of a
//! free call, a list/tuple/interpolation element, a binop/index operand, …).
//! Left alone, the synthesised match's early `return Err(x)` / `return None`
//! fires with operands already pushed on the evaluation stack:
//! `InvalidProgramException` on MSIL, inconsistent stackmap frames on JVM.
//! The hoist mirrors `Lyric.AwaitHoist` (#5606), which solved the identical
//! problem for `await`; see that section's module doc for the full design
//! and scope boundaries.  §2b also hoists a value-producing `try { … } catch
//! { … }` found in an operand position — independent of whether it contains
//! a `?` (#6471) — because entering the try's protected region with the
//! stack already non-empty is the same class of crash.
//!
//! Public surface:
//!
//!   pub func lowerPropagateFile(file: in SourceFile): PropagateResult
//!
//!     Returns a new SourceFile with every `?` desugared, plus any F0020
//!     diagnostics.  The input is not mutated.
package Lyric.Propagate

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Result type + threaded state.
// ─────────────────────────────────────────────────────────────────────────────
pub record PropagateResult {
  file: SourceFile
  diagnostics: List[Diagnostic]
  // Which propagation monad the enclosing function declares.
}

union PropKind {
  case PropResult
  case PropOption
  case PropOther
  // Lambda body — the lambda's own return monad is unknown; `?` here gets a lambda-specific F0020.
  case PropInLambda
  // Mutable state threaded through the walk by reference.  `counter` is a
  // growable cell: its `.count` is the next fresh-name index (the same idiom
  // codegen uses for `slotTicker`), so a plain `in` reference suffices to
  // mutate it — no `inout` plumbing through the recursion.
}

record PropState {
  counter: List[Int]
  diagnostics: List[Diagnostic]
  // Same-file `alias Name[...] = ...` declarations (name -> right-hand side),
  // so return types written through an alias of Result/Option classify
  // correctly instead of tripping a false F0020 (#1814).
  aliases: Map[String, TypeExpr]
}

func newPropState(diags: in List[Diagnostic], aliases: in Map[String, TypeExpr]): PropState {
  PropState(counter = newList(), diagnostics = diags, aliases = aliases)
}

func freshSuffix(st: in PropState): String {
  val n = st.counter.count
  st.counter.add(0)
  toString(n)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. AST builders.  Every fragment is stamped at the `?` operator's span so
//     downstream diagnostics keep pointing at user code.
// ─────────────────────────────────────────────────────────────────────────────
func mkPath(name: in String, sp: in Span): ModulePath {
  val segs: List[String] = newList()
  segs.add(name)
  ModulePath(segments = segs, span = sp)
}

func pathExpr(name: in String, sp: in Span): Expr {
  mkExpr(EPath(path = mkPath(name, sp)), sp)
}

// A single-binding pattern argument list, e.g. the `v` in `Ok(v)`.
func bindArg(name: in String, sp: in Span): List[Pattern] {
  val noInner: Option[Pattern] = None
  val args: List[Pattern] = newList()
  args.add(mkPat(PBinding(name = name, inner = noInner), sp))
  args
}

func posArg(e: in Expr): List[CallArg] {
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = e))
  args
}

func singleStmtBlock(s: in Statement, sp: in Span): Block {
  val stmts: List[Statement] = newList()
  stmts.add(s)
  Block(statements = stmts, span = sp)
}

// `match inner { case Ok(v) -> v; case Err(x) -> { return Err(x) } }`
func buildResultMatch(inner: in Expr, sp: in Span, st: in PropState): Expr {
  val vName = "__lyric_prop_v" + freshSuffix(st)
  val eName = "__lyric_prop_e" + freshSuffix(st)

  val okPat = mkPat(PConstructor(head = mkPath("Ok", sp), args = bindArg(vName, sp)), sp)
  val okBody: ExprOrBlock = EOBExpr(expr = pathExpr(vName, sp))
  val okArm = MatchArm(pattern = okPat, guard = None, body = okBody, span = sp)

  val errPat = mkPat(PConstructor(head = mkPath("Err", sp), args = bindArg(eName, sp)), sp)
  val errCall = mkExpr(ECall(fn = pathExpr("Err", sp), args = posArg(pathExpr(eName, sp))), sp)
  val errRet = mkStmt(SReturn(value = Some(value = errCall)), sp)
  val errBody: ExprOrBlock = EOBBlock(block = singleStmtBlock(errRet, sp))
  val errArm = MatchArm(pattern = errPat, guard = None, body = errBody, span = sp)

  val arms: List[MatchArm] = newList()
  arms.add(okArm)
  arms.add(errArm)
  mkExpr(EMatch(scrutinee = inner, arms = arms), sp)
}

// `match inner { case Some(v) -> v; case None -> { return None } }`
func buildOptionMatch(inner: in Expr, sp: in Span, st: in PropState): Expr {
  val vName = "__lyric_prop_v" + freshSuffix(st)

  val somePat = mkPat(PConstructor(head = mkPath("Some", sp), args = bindArg(vName, sp)), sp)
  val someBody: ExprOrBlock = EOBExpr(expr = pathExpr(vName, sp))
  val someArm = MatchArm(pattern = somePat, guard = None, body = someBody, span = sp)

  // A bare `case None` parses as a PBinding the codegen recognises as the
  // nullary union case (see `lowerPatternTestMsil`); mirror that exactly.
  val noneInner: Option[Pattern] = None
  val nonePat = mkPat(PBinding(name = "None", inner = noneInner), sp)
  val noneRet = mkStmt(SReturn(value = Some(value = pathExpr("None", sp))), sp)
  val noneBody: ExprOrBlock = EOBBlock(block = singleStmtBlock(noneRet, sp))
  val noneArm = MatchArm(pattern = nonePat, guard = None, body = noneBody, span = sp)

  val arms: List[MatchArm] = newList()
  arms.add(someArm)
  arms.add(noneArm)
  mkExpr(EMatch(scrutinee = inner, arms = arms), sp)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2b. Statement-level ANF hoist for `?` in operand position (#6448).
//
// Mirrors `Lyric.AwaitHoist` (#5606), which solved the identical problem for
// `await`: `e?` desugars (below, §4) into an expression-position `match`
// whose failure arm does an early `return`.  When that expression sits in a
// position with operands already pushed on the evaluation stack — a
// method-call RECEIVER counts as a stacked operand, as do earlier arguments
// of a free call, and the delegate/closure reference of a call through a
// lambda VALUE (#6460) — the early return fires with a non-empty stack:
// invalid IL on MSIL (`InvalidProgramException`), inconsistent stackmap
// frames on JVM.  `val x = e?` as a whole statement is already safe (no
// operand precedes it) and is left byte-identical; every `?`-bearing call
// ARGUMENT is hoisted regardless of callee shape, because a bare-name
// callee cannot be syntactically distinguished from a local (or
// module-level) lambda value whose invocation pushes the callee reference
// first (#6460 — see the `phNeedsHoist` `ECall` comment).
//
//     recv.m(a, e?, b)   ⇒   val __lyric_phoist_0 = a
//                            val __lyric_phoist_1 = e?
//                            recv.m(__lyric_phoist_0, __lyric_phoist_1, b)
//
// Every operand evaluated before the last qualifying `?` is bound to a fresh
// local first (preserving left-to-right evaluation order), so no `?` remains
// in a position with operands already stacked.  This hoist runs BEFORE the
// `?` -> match rewrite (§4) — the qualifying `?` is still a bare `EPropagate`
// node when this pass sees it — so the subsequent rewrite always lands its
// synthesized match as a statement-level initializer, exactly the shape both
// backends already compile correctly.
//
// Unlike `await`, `?` is legal in PLAIN functions too (not just `async
// func`), so this pass runs unconditionally over every function body — there
// is no `isAsync` gate.  There is also no "nested-target" special case: a
// bare `?` used safely (e.g. `val x = e?`) never needs hoisting on its own;
// hoisting is driven entirely by the OPERAND POSITION a `?` is found in,
// detected by the same call/index/list/interpolation/binop cases
// `Lyric.AwaitHoist` catalogues (minus its first-free-arg exemption — see
// the #6460 note above).  (`await`'s
// own nested-await rule exists only to keep its MSIL async-SM field
// pre-scan in sync with emission — a concern specific to state-machine
// field counting that has no analog for a plain `match` rewrite.)
//
// Scope boundaries, mirroring `Lyric.AwaitHoist`:
//   * `ELambda` / `ESpawn` bodies are deferred computations — a `?` inside
//     one is not an operand of the enclosing expression, so the pass never
//     descends into them (any hoist needed strictly inside such a body is a
//     separate, currently out-of-scope concern, matching `Lyric.AwaitHoist`'s
//     own non-goal).
//   * #6458 (investigated, resolved as a non-gap) / #6471 (fixed here):
//     `phHasHazard`/`phNeedsHoist` do carry a `case ETry(_) -> false` arm,
//     which reads as if a `?` inside a `try` EXPRESSION were opaque to this
//     pass the way `ELambda`/`ESpawn` bodies genuinely are.  It is not —
//     `ETry` is dead AST.  The parser never constructs it: `try { … } catch
//     … { … }` in expression position (the `KwTry` arm of the
//     primary-expression parser) desugars to `EBlock([STry(body, catches,
//     finally)])`, a block wrapping the try as a STATEMENT, exactly like
//     `if`/`match`/`{ … }` used as values.  That shape is not opaque:
//     `phHasHazard`'s `EBlock` -> `STry` walk (`phHasHazardBlock`/
//     `phHasHazardStmt`) already descends into the try body/catches/finally.
//
//     Two hazard sources reach that walk, and both are now covered by the
//     SAME mechanism:
//       - A `?` found anywhere inside the try (#6458): `phNeedsHoist`'s
//         `ECall` arm flags the whole argument, and `phHoistSpine`'s generic
//         `EBlock` case — unconditionally, for ANY block-valued operand, not
//         a `try`-specific rule — binds the ENTIRE `{ try { … } catch { … }
//         }` to a fresh `val` before the call.  Verified live (`lyric run`,
//         both targets): `xs.add(try { parse(s)? } catch Bug as b { 0 })`
//         inside a `Result`-returning function propagates Ok/Err correctly
//         on `--target dotnet` and `--target jvm` alike — see
//         `propagate_hoist_self_test.l`'s "try-expression call argument"
//         case.
//       - The `STry` statement's mere PRESENCE, independent of whether `?`
//         is anywhere inside it (#6471): entering the try's protected
//         region (MSIL) or its normal/handler stackmap merge (JVM) is
//         unsafe with operands already pushed — the general call-argument
//         codegen path has no spill for a preceding stacked operand before
//         a `newobj`/protected-region-entry inside a value-producing try.
//         `phHasHazardStmt`'s `STry` case (below) reports presence
//         unconditionally rather than only when NESTED content itself
//         qualifies, so `phHasHazard` — and every existing call site that
//         already used it to test "is this operand a stacking hazard"
//         (`phLastHazardArgIdx`'s call-argument scan, the non-short-circuit
//         `EBinop` RHS check, `EAssign`'s member/index-target value check,
//         `EIndex`/`EList`/`ETuple`/`EInterpolated`'s "last hazardous
//         element" scan) — now also flags a `?`-free try.  No NEW call
//         sites were needed: the hazard flows through the SAME recursive
//         walk and the SAME `EBlock`-binds-the-whole-block rewrite that
//         #6458 already exercised, so `xs.add(try { risky() } catch Bug as
//         b { 0 })` (no `?` anywhere) is hoisted into
//         `val __lyric_phoist_0 = { try { risky() } catch Bug as b { 0 } };
//         xs.add(__lyric_phoist_0)` — the whole protected region now starts
//         on an empty stack, on both targets.
//
//         Idempotence: `phNeedsHoist`'s OWN `STry` handling (unchanged by
//         #6471) still asks only whether the try's body/catches/finally
//         contain a NESTED need, never whether `STry` is merely present —
//         so an already-safe `val x = try { … } catch { … }` (a bare
//         statement-level initializer, nothing stacked ahead of it) is
//         never re-qualified by this pass: `phNeedsHoistStmt`'s `SLocal`
//         arm calls `phNeedsHoist(init)`, which for `EBlock([STry(...)])`
//         with no internal hazard returns `false`, so the statement stays
//         byte-identical, exactly the shape #6471's own rewrite produces.
//         A second hoist pass over already-hoisted output is therefore a
//         no-op, confirmed by re-running the hoist over its own output in
//         `propagate_hoist_self_test.l`.
//
//         Async coverage: this pass has no `isAsync` gate (see above), so a
//         no-`?` try in stacked operand position inside an `async func`
//         body is hoisted by this SAME pass, before `Lyric.AwaitHoist` ever
//         runs (`pipeCheckAndMono` calls `lowerPropagateFile` well before
//         `pipeWeave` calls `AwaitHoist.hoistAwaitsFile` — see
//         `pipeline.l`).  By the time `Lyric.AwaitHoist` sees the tree, the
//         try has already been extracted to a standalone `val`, so no
//         analogous rule was needed on the await-hoist side; verified live
//         with an `async func` repro on both targets.
//   * `await`'s own presence is a transparent pass-through in both
//     directions: `await (e?)` searches `e?` for a qualifying `?` (the
//     await_hoist pass, which runs later in `pipeWeave`, has not touched
//     this tree yet — it still sees plain `EAwait` nodes here), and `e??`
//     nested through the SPINE (never a direct `EPropagate(EPropagate(_))`
//     literal, always via an intervening `ECall`/`EIndex`/…) is handled by
//     the same generic operand-position rules, no special case needed (see
//     the module doc's nested-`?` worked example below).
//   * A `while` condition containing a qualifying `?` is rewritten into the
//     `Lyric.AwaitHoist`-style `loop { <hoisted>; if cond { body } else
//     { break } }` so the hoisted bindings re-evaluate every iteration;
//     `continue` re-enters at the loop head.  (propagate.l's pre-existing
//     `SWhile` handling in §4 just rewrites the condition expression in
//     place — it has no loop-restructuring of its own, so this hoist is the
//     only place that need worry about per-iteration re-evaluation.)
//   * #6456: an assignment to a MEMBER or INDEX target (`b.field = e?`,
//     `arr[i] = e?`, compound forms included) stacks the receiver — and any
//     index operands — before the value evaluates on MSIL
//     (`lowerAssignExprMsil` pushes them with no spill), so any `?` in the
//     value qualifies; the target's receiver/index operands are rebound to
//     temps in evaluation order and the whole value is bound out
//     (`phBindAssignTarget`).  A bare-name target is a plain local store
//     with nothing stacked and stays byte-identical.
//   * #6457: an `?` inside a `forall`/`exists` quantifier body or
//     `old(...)` is detected by `phHasHazard`/`phNeedsHoist` (walk-
//     consistency, ported to `Lyric.AwaitHoist` in the same round) but not
//     rewritten by the hoist spine — low severity, quantifiers never lower
//     to real bytecode and `EOld` at codegen is already an ICE.
// ─────────────────────────────────────────────────────────────────────────────
record PropHoistState {
  counter: List[Int]
}

func phFresh(st: in PropHoistState): String {
  val n = st.counter.count
  st.counter.add(0)
  "__lyric_phoist_" + toString(n)
}

func phArgExpr(a: in CallArg): Expr {
  match a {
    case CAPositional(v) -> v
    case CANamed(_, v, _) -> v
  }
}

func phRebuildArg(a: in CallArg, e2: in Expr): CallArg {
  match a {
    case CAPositional(_) -> CAPositional(expr = e2)
    case CANamed(n, _, asp) -> CANamed(name = n, value = e2, span = asp)
  }
}

// A receiver that is just a (possibly dotted) name: a package/type qualifier
// or a plain local read.  Neither needs hoisting for order preservation —
// re-reading a name after the hoisted `?`s is equivalent — and a package
// qualifier MUST NOT be bound to a local (it is not a value).
func phIsNameLike(e: in Expr): Bool {
  match e.kind {
    case EPath(_) -> true
    case ESelf -> true
    case ELiteral(_) -> true
    case EMember(recv, _) -> phIsNameLike(recv)
    case EParen(inner) -> phIsNameLike(inner)
    case _ -> false
  }
}

// Bind `e` to a fresh `val` appended to `acc` and return a path expression
// reading it.  Literals are returned unchanged.
func phBind(e: in Expr, acc: in List[Statement], st: in PropHoistState): Expr {
  match e.kind {
    case ELiteral(_) -> e
    case _ -> {
      val name = phFresh(st)
      val noTy: Option[TypeExpr] = None
      val noInner: Option[Pattern] = None
      val pat = mkPat(PBinding(name = name, inner = noInner), e.span)
      acc.add(mkStmt(SLocal(binding = LBVal(pat = pat, ty = noTy, init = e)), e.span))
      pathExpr(name, e.span)
    }
  }
}

// #6456: an assignment whose target is a member or index write stacks its
// receiver (and index operands) on MSIL BEFORE the value evaluates —
// `lowerAssignExprMsil`'s `EMember`/`EIndex` cases push them with no
// spill-and-reload — so ANY `?` in the value is a stacking hazard, not just
// a nested one (the same reasoning as the regular-binop RHS rule).  A
// bare-name target is a plain local store with nothing stacked.  (JVM is
// unaffected: its member/index assignment lowering already spills
// receiver/index/value to locals, #5936.)
func phAssignTargetStacks(target: in Expr): Bool {
  match target.kind {
    case EParen(inner) -> phAssignTargetStacks(inner)
    case EMember(_, _) -> true
    case EIndex(_, _) -> true
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Presence: true when evaluating `e` executes a `?` OR an `STry` statement
// (#6471) — both are stacking hazards a hoist must clear out of an operand
// position, so this predicate (renamed from `phHasProp` to `phHasHazard`
// when #6471 broadened it) and its rewrite-side consumers below treat them
// uniformly.  Everywhere this file already called `phHasProp(x)` to ask "is
// operand `x` a stacking hazard", the answer now correctly includes a bare
// try with no `?` too — no other call site needed to change.
// ─────────────────────────────────────────────────────────────────────────────
func phHasHazard(e: in Expr): Bool {
  match e.kind {
    case EPropagate(_) -> true
    case ELambda(_, _) -> false
    case ESpawn(_) -> false
    // #6458/#6471: match-exhaustiveness only — the parser never constructs
    // `ETry` for real source (a value-position `try` desugars to
    // `EBlock([STry])`, walked by the `EBlock` case below), so this arm is
    // unreachable from any parseable program.  See the §2b module doc.
    case ETry(_) -> false
    case EAwait(inner) -> phHasHazard(inner)
    case EParen(inner) -> phHasHazard(inner)
    case ETuple(exprs) -> phHasHazardList(exprs)
    case EList(exprs) -> phHasHazardList(exprs)
    case EIf(cond, thenB, elseO, _) -> {
      if phHasHazard(cond) or phHasHazardEob(thenB) {
        true
      } else {
        match elseO {
          case Some(eb) -> phHasHazardEob(eb)
          case None -> false
        }
      }
    }
    case EMatch(scrutinee, arms) -> {
      if phHasHazard(scrutinee) {
        return true
      }
      var i = 0
      while i < arms.count {
        val g = match arms[i].guard { case Some(ge) -> phHasHazard(ge); case None -> false }
        if g or phHasHazardEob(arms[i].body) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EYield(inner) -> phHasHazard(inner)
    case ECall(fn, args) -> {
      if phHasHazard(fn) {
        return true
      }
      var i = 0
      while i < args.count {
        if phHasHazard(phArgExpr(args[i])) {
          return true
        }
        i = i + 1
      }
      false
    }
    case ETypeApp(fn, _) -> phHasHazard(fn)
    case EIndex(receiver, indices) -> phHasHazard(receiver) or phHasHazardList(indices)
    case EMember(receiver, _) -> phHasHazard(receiver)
    case EPrefix(_, operand) -> phHasHazard(operand)
    case EBinop(_, lhs, rhs) -> phHasHazard(lhs) or phHasHazard(rhs)
    case ERange(bound) -> {
      match bound {
        case RBClosed(lo, hi) -> phHasHazard(lo) or phHasHazard(hi)
        case RBHalfOpen(lo, hi) -> phHasHazard(lo) or phHasHazard(hi)
        case RBLowerOpen(hi) -> phHasHazard(hi)
        case RBUpperOpen(lo) -> phHasHazard(lo)
      }
    }
    case EAssign(target, _, value) -> phHasHazard(target) or phHasHazard(value)
    case EBlock(blk) -> phHasHazardBlock(blk)
    case EUnsafe(blk) -> phHasHazardBlock(blk)
    case EInterpolated(segments) -> {
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISText(_, _) -> ()
          case ISExpr(ex) -> {
            if phHasHazard(ex) {
              return true
            }
          }
        }
        i = i + 1
      }
      false
    }
    // #6457 review: walk-consistency with `Lyric.AwaitHoist`'s identical
    // fix — these were opaque even though the contract elaborator can
    // splice a `requires:`/`ensures:` quantifier or `old(...)` verbatim
    // into a body as a runtime assert argument.  Low severity (quantifiers
    // never lower to real bytecode and `EOld` at codegen is already an
    // ICE), so only the PRESENCE/QUALIFICATION walks descend here — no
    // hoist-spine support is added; a `?` reachable only through one of
    // these stays undetected by the hoist's REWRITE side.
    case EOld(inner) -> phHasHazard(inner)
    case EForall(_, whereOpt, body) -> {
      val w = match whereOpt { case Some(we) -> phHasHazard(we); case None -> false }
      w or phHasHazard(body)
    }
    case EExists(_, whereOpt, body) -> {
      val w = match whereOpt { case Some(we) -> phHasHazard(we); case None -> false }
      w or phHasHazard(body)
    }
    case _ -> false
  }
}

func phHasHazardList(es: in List[Expr]): Bool {
  var i = 0
  while i < es.count {
    if phHasHazard(es[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func phHasHazardEob(eob: in ExprOrBlock): Bool {
  match eob {
    case EOBExpr(e) -> phHasHazard(e)
    case EOBBlock(blk) -> phHasHazardBlock(blk)
  }
}

func phHasHazardBlock(blk: in Block): Bool {
  var i = 0
  while i < blk.statements.count {
    if phHasHazardStmt(blk.statements[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func phHasHazardStmt(s: in Statement): Bool {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> phHasHazard(init)
        case LBLet(_, _, init) -> phHasHazard(init)
        case LBVar(_, _, initOpt) -> {
          match initOpt {
            case Some(init) -> phHasHazard(init)
            case None -> false
          }
        }
      }
    }
    case SAssign(target, _, value) -> phHasHazard(target) or phHasHazard(value)
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> phHasHazard(e)
        case None -> false
      }
    }
    case SThrow(e) -> phHasHazard(e)
    case SExpr(e) -> phHasHazard(e)
    case SWhile(_, cond, body) -> phHasHazard(cond) or phHasHazardBlock(body)
    case SFor(_, _, iter, body) -> phHasHazard(iter) or phHasHazardBlock(body)
    case SLoop(_, body) -> phHasHazardBlock(body)
    case SScope(_, body) -> phHasHazardBlock(body)
    case SDefer(body) -> phHasHazardBlock(body)
    // #6471: an `STry` statement is ITSELF a stacking hazard, independent of
    // whether a `?` is found anywhere inside it — entering the try's
    // protected region (MSIL) or its normal/handler merge point (JVM) is
    // unsafe with operands already on the evaluation stack, exactly like a
    // `?`'s synthesized early return.  Report presence unconditionally
    // rather than only when the try's own body/catches/finally contain a
    // NESTED hazard; see the §2b module doc's updated `#6471` note.
    case STry(_, _, _) -> true
    case SInvariant(e) -> phHasHazard(e)
    case SRule(lhs, rhs) -> phHasHazard(lhs) or phHasHazard(rhs)
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Qualification: does this subtree contain a `?` in a position that leaves
// operands stacked across it?  Everything this predicate rejects is left
// byte-identical by the rewrite.
// ─────────────────────────────────────────────────────────────────────────────
func phLastHazardArgIdx(args: in List[CallArg]): Int {
  var last = -1
  var i = 0
  while i < args.count {
    if phHasHazard(phArgExpr(args[i])) {
      last = i
    }
    i = i + 1
  }
  last
}

func phNeedsHoist(e: in Expr): Bool {
  match e.kind {
    case EPropagate(inner) -> phNeedsHoist(inner)
    case EAwait(inner) -> phNeedsHoist(inner)
    case ECall(fn, args) -> {
      val last = phLastHazardArgIdx(args)
      // #6460: ANY `?`-bearing argument qualifies, regardless of callee
      // shape.  The original rule exempted a first-and-only-`?` argument of
      // a bare-name (`EPath`) callee as a direct static call with an empty
      // stack — but a LOCAL LAMBDA value (`val f: (Int) -> Int = ...;
      // f(e?)`) parses to the identical `ECall(EPath, args)` shape and its
      // invocation pushes the delegate/closure reference before arguments
      // evaluate (both targets), and a module-level lambda-typed `pub val`
      // makes even a multi-segment path callee unprovable as a direct call.
      // A callee-expression call (`getF()(e?)`) had the same hole.  The
      // syntactic walk cannot distinguish these from genuine free
      // functions, and hoisting is always semantics-preserving, so the
      // exemption is dropped entirely (a deliberate divergence from
      // `Lyric.AwaitHoist`, whose own copy of this gap is tracked in
      // #6457/#6460).
      if last >= 0 {
        return true
      }
      if phNeedsHoist(fn) {
        return true
      }
      var i = 0
      while i < args.count {
        if phNeedsHoist(phArgExpr(args[i])) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EIndex(receiver, indices) -> {
      // The receiver is stacked before the index expressions evaluate.
      if phHasHazardList(indices) {
        return true
      }
      if phNeedsHoist(receiver) {
        return true
      }
      var i = 0
      while i < indices.count {
        if phNeedsHoist(indices[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    // List/tuple construction stacks the collection/earlier elements.
    case EList(exprs) -> phHasHazardList(exprs) or phNeedsHoistList(exprs)
    case ETuple(exprs) -> phHasHazardList(exprs) or phNeedsHoistList(exprs)
    // Interpolation stacks the accumulating string across segments.
    case EInterpolated(segments) -> {
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISText(_, _) -> ()
          case ISExpr(ex) -> {
            if phHasHazard(ex) or phNeedsHoist(ex) {
              return true
            }
          }
        }
        i = i + 1
      }
      false
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
        // The RHS's own evaluation starts on an empty stack: the branch
        // instruction CONSUMES the LHS's pushed value before RHS runs, so a
        // bare `?` directly in the RHS is not itself a stacking hazard here.
        // Only an internally-hazardous LHS or RHS (`phNeedsHoist`, e.g. a
        // nested call that itself needs hoisting) qualifies; `phHoistSpine`
        // still binds the whole expression to a temp when it does, which
        // ALSO protects it from an EXTERNAL stacking context imposed by
        // whatever enclosing call/index/etc. decided this operand needs
        // hoisting in the first place.
        phNeedsHoist(lhs) or phNeedsHoist(rhs)
      } else {
        // Regular binops push LHS unconditionally, then evaluate RHS with
        // that value still on the stack — unlike `await` (spilled by the
        // emitter's `phaseBSpillToLocal` when `exprContainsAwaitMsil(rhs)`
        // for `BEq`/`BNeq`/…, codegen.l), there is NO equivalent spill keyed
        // off `?`, so ANY hazard (`?` or a `try`, #6471) anywhere in the RHS
        // is a stacking hazard here, not just a nested one.
        phHasHazard(rhs) or phNeedsHoist(lhs) or phNeedsHoist(rhs)
      }
    }
    case EParen(inner) -> phNeedsHoist(inner)
    case EPrefix(_, operand) -> phNeedsHoist(operand)
    case EMember(receiver, _) -> phNeedsHoist(receiver)
    case EYield(inner) -> phNeedsHoist(inner)
    case ETypeApp(fn, _) -> phNeedsHoist(fn)
    case EAssign(target, _, value) -> phNeedsHoist(target) or phNeedsHoist(value) or (phAssignTargetStacks(target) and phHasHazard(value))
    case EIf(cond, thenB, elseO, _) -> {
      if phNeedsHoist(cond) or phNeedsHoistEob(thenB) {
        true
      } else {
        match elseO {
          case Some(eb) -> phNeedsHoistEob(eb)
          case None -> false
        }
      }
    }
    case EMatch(scrutinee, arms) -> {
      if phNeedsHoist(scrutinee) {
        return true
      }
      var i = 0
      while i < arms.count {
        if phNeedsHoistEob(arms[i].body) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EBlock(blk) -> phNeedsHoistBlock(blk)
    case EUnsafe(blk) -> phNeedsHoistBlock(blk)
    case ERange(bound) -> {
      match bound {
        case RBClosed(lo, hi) -> phNeedsHoist(lo) or phNeedsHoist(hi)
        case RBHalfOpen(lo, hi) -> phNeedsHoist(lo) or phNeedsHoist(hi)
        case RBLowerOpen(hi) -> phNeedsHoist(hi)
        case RBUpperOpen(lo) -> phNeedsHoist(lo)
      }
    }
    // #6457 review: walk-consistency only (see `phHasHazard`'s identical
    // note) — no hoist-spine support for these, so a qualifying `?` found
    // only here is detected but the enclosing statement's OTHER hazards
    // (if any) still get hoisted through the generic rules.
    case EOld(inner) -> phNeedsHoist(inner)
    case EForall(_, whereOpt, body) -> {
      val w = match whereOpt { case Some(we) -> phNeedsHoist(we); case None -> false }
      w or phNeedsHoist(body)
    }
    case EExists(_, whereOpt, body) -> {
      val w = match whereOpt { case Some(we) -> phNeedsHoist(we); case None -> false }
      w or phNeedsHoist(body)
    }
    case _ -> false
  }
}

func phNeedsHoistList(es: in List[Expr]): Bool {
  var i = 0
  while i < es.count {
    if phNeedsHoist(es[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func phNeedsHoistEob(eob: in ExprOrBlock): Bool {
  match eob {
    case EOBExpr(e) -> phNeedsHoist(e)
    case EOBBlock(blk) -> phNeedsHoistBlock(blk)
  }
}

func phNeedsHoistBlock(blk: in Block): Bool {
  var i = 0
  while i < blk.statements.count {
    if phNeedsHoistStmt(blk.statements[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func phNeedsHoistStmt(s: in Statement): Bool {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> phNeedsHoist(init)
        case LBLet(_, _, init) -> phNeedsHoist(init)
        case LBVar(_, _, initOpt) -> {
          match initOpt {
            case Some(init) -> phNeedsHoist(init)
            case None -> false
          }
        }
      }
    }
    case SAssign(target, _, value) -> phNeedsHoist(target) or phNeedsHoist(value) or (phAssignTargetStacks(target) and phHasHazard(value))
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> phNeedsHoist(e)
        case None -> false
      }
    }
    case SThrow(e) -> phNeedsHoist(e)
    case SExpr(e) -> phNeedsHoist(e)
    case SWhile(_, cond, body) -> phNeedsHoist(cond) or phNeedsHoistBlock(body)
    case SFor(_, _, iter, body) -> phNeedsHoist(iter) or phNeedsHoistBlock(body)
    case SLoop(_, body) -> phNeedsHoistBlock(body)
    case SScope(_, body) -> phNeedsHoistBlock(body)
    case SDefer(body) -> phNeedsHoistBlock(body)
    case STry(body, catches, finallyOpt) -> {
      if phNeedsHoistBlock(body) {
        return true
      }
      var i = 0
      while i < catches.count {
        if phNeedsHoistBlock(catches[i].body) {
          return true
        }
        i = i + 1
      }
      match finallyOpt {
        case Some(fb) -> phNeedsHoistBlock(fb)
        case None -> false
      }
    }
    case SItem(item) -> phItemNeedsHoist(item)
    // #6453 review: `phHasHazardStmt` covers these two, so the qualification
    // walk must too — a `?` in operand position INSIDE an invariant or rule
    // expression (`invariant: xs.contains(f()?)`) is the same crash class.
    case SInvariant(e) -> phNeedsHoist(e)
    case SRule(lhs, rhs) -> phNeedsHoist(lhs) or phNeedsHoist(rhs)
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The spine hoist.  `phHoistSpine(e, acc, st)` appends bindings to `acc` and
// returns a residual expression whose evaluation executes no `?` at a
// hazardous stack depth (a `?` under `ELambda`/`ESpawn`/`ETry` is deferred or
// opaque, never touched).  Every operand evaluated before a hoisted `?` is
// bound first, preserving left-to-right evaluation order exactly.
// ─────────────────────────────────────────────────────────────────────────────
func phHoistSpine(e: in Expr, acc: in List[Statement], st: in PropHoistState): Expr {
  if not phHasHazard(e) {
    return e
  }
  match e.kind {
    case EPropagate(inner) -> {
      val inner2 = phHoistSpine(inner, acc, st)
      phBind(mkExpr(EPropagate(inner = inner2), e.span), acc, st)
    }
    case EAwait(inner) -> mkExpr(EAwait(inner = phHoistSpine(inner, acc, st)), e.span)
    case EParen(inner) -> mkExpr(EParen(inner = phHoistSpine(inner, acc, st)), e.span)
    case ECall(fn, args) -> {
      val last = phLastHazardArgIdx(args)
      val fn2 = match fn.kind {
        case EMember(recv, nm) -> {
          val recv2 = if phHasHazard(recv) {
            phBind(phHoistSpine(recv, acc, st), acc, st)
          } else if last >= 0 and not phIsNameLike(recv) {
            phBind(recv, acc, st)
          } else {
            recv
          }
          mkExpr(EMember(receiver = recv2, memberName = nm), fn.span)
        }
        case EPath(_) -> fn
        case _ -> {
          if phHasHazard(fn) {
            phBind(phHoistSpine(fn, acc, st), acc, st)
          } else if last >= 0 {
            phBind(fn, acc, st)
          } else {
            fn
          }
        }
      }
      val newArgs: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        val ae = phArgExpr(args[i])
        var ae2 = ae
        if i < last {
          val h = if phHasHazard(ae) { phHoistSpine(ae, acc, st) } else { ae }
          ae2 = phBind(h, acc, st)
        } else if i == last {
          ae2 = phHoistSpine(ae, acc, st)
        }
        newArgs.add(phRebuildArg(args[i], ae2))
        i = i + 1
      }
      mkExpr(ECall(fn = fn2, args = newArgs), e.span)
    }
    case EIndex(receiver, indices) -> {
      var last = -1
      var li = 0
      while li < indices.count {
        if phHasHazard(indices[li]) {
          last = li
        }
        li = li + 1
      }
      val recv2 = if phHasHazard(receiver) {
        phBind(phHoistSpine(receiver, acc, st), acc, st)
      } else if last >= 0 and not phIsNameLike(receiver) {
        phBind(receiver, acc, st)
      } else {
        receiver
      }
      val newIdx: List[Expr] = newList()
      var i = 0
      while i < indices.count {
        var ix2 = indices[i]
        if i < last {
          val h = if phHasHazard(ix2) { phHoistSpine(ix2, acc, st) } else { ix2 }
          ix2 = phBind(h, acc, st)
        } else if i == last {
          ix2 = phHoistSpine(ix2, acc, st)
        }
        newIdx.add(ix2)
        i = i + 1
      }
      mkExpr(EIndex(receiver = recv2, indices = newIdx), e.span)
    }
    case ETuple(exprs) -> mkExpr(ETuple(exprs = phHoistElems(exprs, acc, st)), e.span)
    case EList(exprs) -> mkExpr(EList(exprs = phHoistElems(exprs, acc, st)), e.span)
    case EInterpolated(segments) -> {
      var last = -1
      var si = 0
      while si < segments.count {
        match segments[si] {
          case ISText(_, _) -> ()
          case ISExpr(ex) -> {
            if phHasHazard(ex) {
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
              val h = if phHasHazard(ex) { phHoistSpine(ex, acc, st) } else { ex }
              ex2 = phBind(h, acc, st)
            } else if i == last {
              ex2 = phHoistSpine(ex, acc, st)
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
        // The RHS is conditionally evaluated: a `?` inside it cannot move
        // out.  Binding the whole (LHS-hoisted) operator expression to a
        // `val` makes any `?` inside it run against an empty stack — the
        // shape the emitter already compiles correctly.
        val l2 = if phHasHazard(lhs) { phHoistSpine(lhs, acc, st) } else { lhs }
        if phHasHazard(rhs) {
          phBind(mkExpr(EBinop(op = op, lhs = l2, rhs = rhs), e.span), acc, st)
        } else {
          mkExpr(EBinop(op = op, lhs = l2, rhs = rhs), e.span)
        }
      } else if phHasHazard(rhs) {
        val l2 = if phHasHazard(lhs) { phHoistSpine(lhs, acc, st) } else { lhs }
        val l3 = phBind(l2, acc, st)
        val r2 = phHoistSpine(rhs, acc, st)
        mkExpr(EBinop(op = op, lhs = l3, rhs = r2), e.span)
      } else {
        mkExpr(EBinop(op = op, lhs = phHoistSpine(lhs, acc, st), rhs = rhs), e.span)
      }
    }
    case EPrefix(op, operand) -> mkExpr(EPrefix(op = op, operand = phHoistSpine(operand, acc, st)), e.span)
    case EMember(receiver, memberName) -> mkExpr(EMember(receiver = phHoistSpine(receiver, acc, st), memberName = memberName), e.span)
    case EYield(inner) -> mkExpr(EYield(inner = phHoistSpine(inner, acc, st)), e.span)
    case ETypeApp(fn, targs) -> mkExpr(ETypeApp(fn = phHoistSpine(fn, acc, st), args = targs), e.span)
    case EAssign(target, op, value) -> {
      // Mirrors the `SAssign` statement rewrite: the target evaluates first,
      // so its own `?` (`arr[f()?] = v`) is spilled before the value's.
      // #6456: a member/index target with a `?`-bearing value additionally
      // needs the target's receiver/index operands rebound to temps (in
      // evaluation order) and the whole value bound out, so the early
      // return never fires with the receiver/index already stacked.
      if phAssignTargetStacks(target) and phHasHazard(value) {
        val target2 = phBindAssignTarget(target, acc, st)
        val value2 = phBind(phHoistTop(value, acc, st), acc, st)
        mkExpr(EAssign(target = target2, op = op, value = value2), e.span)
      } else {
        val target2 = if phNeedsHoist(target) { phHoistSpine(target, acc, st) } else { target }
        mkExpr(EAssign(target = target2, op = op, value = phHoistSpine(value, acc, st)), e.span)
      }
    }
    case EIf(cond, thenB, elseO, thenForm) -> {
      // Arms are conditionally evaluated; rewrite them internally and bind
      // the whole `if` to a `val` — a `?` inside a val-bound if/match arm
      // evaluates on an empty stack (the already-working shape).
      val cond2 = if phHasHazard(cond) { phHoistSpine(cond, acc, st) } else { cond }
      val then2 = phHoistArm(thenB, st)
      val else2: Option[ExprOrBlock] = match elseO { case Some(eb) -> Some(value = phHoistArm(eb, st)); case None -> None }
      val armsProp = phHasHazardEob(thenB) or (match elseO { case Some(eb0) -> phHasHazardEob(eb0); case None -> false })
      val rebuilt = mkExpr(EIf(cond = cond2, thenBranch = then2, elseBranch = else2, thenForm = thenForm), e.span)
      if armsProp {
        phBind(rebuilt, acc, st)
      } else {
        rebuilt
      }
    }
    case EMatch(scrutinee, arms) -> {
      val scr2 = if phHasHazard(scrutinee) { phHoistSpine(scrutinee, acc, st) } else { scrutinee }
      var armsProp = false
      val newArms: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        if phHasHazardEob(arm.body) {
          armsProp = true
        }
        newArms.add(MatchArm(pattern = arm.pattern, guard = arm.guard, body = phHoistArm(arm.body, st), span = arm.span))
        i = i + 1
      }
      val rebuilt = mkExpr(EMatch(scrutinee = scr2, arms = newArms), e.span)
      if armsProp {
        phBind(rebuilt, acc, st)
      } else {
        rebuilt
      }
    }
    case EBlock(blk) -> phBind(mkExpr(EBlock(block = phBlock(blk, st)), e.span), acc, st)
    case EUnsafe(blk) -> phBind(mkExpr(EUnsafe(block = phBlock(blk, st)), e.span), acc, st)
    case ERange(bound) -> {
      val newBound = match bound {
        case RBClosed(lo, hi) -> {
          if phHasHazard(hi) {
            val lo2 = phBind(phHoistSpine(lo, acc, st), acc, st)
            RBClosed(lo = lo2, hi = phHoistSpine(hi, acc, st))
          } else {
            RBClosed(lo = phHoistSpine(lo, acc, st), hi = hi)
          }
        }
        case RBHalfOpen(lo, hi) -> {
          if phHasHazard(hi) {
            val lo2 = phBind(phHoistSpine(lo, acc, st), acc, st)
            RBHalfOpen(lo = lo2, hi = phHoistSpine(hi, acc, st))
          } else {
            RBHalfOpen(lo = phHoistSpine(lo, acc, st), hi = hi)
          }
        }
        case RBLowerOpen(hi) -> RBLowerOpen(hi = phHoistSpine(hi, acc, st))
        case RBUpperOpen(lo) -> RBUpperOpen(lo = phHoistSpine(lo, acc, st))
      }
      mkExpr(ERange(bound = newBound), e.span)
    }
    case _ -> e
  }
}

// Positional hoist shared by tuple and list element lists.
func phHoistElems(exprs: in List[Expr], acc: in List[Statement], st: in PropHoistState): List[Expr] {
  var last = -1
  var li = 0
  while li < exprs.count {
    if phHasHazard(exprs[li]) {
      last = li
    }
    li = li + 1
  }
  val newExprs: List[Expr] = newList()
  var i = 0
  while i < exprs.count {
    var el2 = exprs[i]
    if i < last {
      val h = if phHasHazard(el2) { phHoistSpine(el2, acc, st) } else { el2 }
      el2 = phBind(h, acc, st)
    } else if i == last {
      el2 = phHoistSpine(el2, acc, st)
    }
    newExprs.add(el2)
    i = i + 1
  }
  newExprs
}

// Rewrite an if/match arm internally: block arms recurse the statement
// driver; expression arms that need hoisting become value-producing blocks
// carrying their own bindings.
func phHoistArm(eob: in ExprOrBlock, st: in PropHoistState): ExprOrBlock {
  match eob {
    case EOBExpr(ae) -> {
      if phNeedsHoist(ae) {
        val acc2: List[Statement] = newList()
        val ae2 = phHoistTop(ae, acc2, st)
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
    case EOBBlock(blk) -> EOBBlock(block = phBlock(blk, st))
  }
}

// Statement-position hoist: control-flow expressions that ARE the statement
// keep their shape (arms rewritten in place, no binding); everything else
// takes the spine hoist.
// #6456: rebind a member/index assignment target's receiver and index
// operands to fresh locals, in evaluation order, so a `?`-bearing value can
// be hoisted AFTER them without reordering side effects; the write then goes
// through the temps.  Receivers with their own hazards are spine-hoisted
// first.  Literals stay in place (`phBind` returns them unchanged); every
// other operand — including a bare-name receiver — is bound, because the
// value expression may mutate a `var` local the target read (the original
// order reads the target operands before the value runs).
func phBindAssignTarget(target: in Expr, dest: in List[Statement], st: in PropHoistState): Expr {
  match target.kind {
    case EParen(inner) -> mkExpr(EParen(inner = phBindAssignTarget(inner, dest, st)), target.span)
    case EMember(receiver, memberName) -> {
      val r0 = if phNeedsHoist(receiver) { phHoistSpine(receiver, dest, st) } else { receiver }
      mkExpr(EMember(receiver = phBind(r0, dest, st), memberName = memberName), target.span)
    }
    case EIndex(receiver, indices) -> {
      val r0 = if phNeedsHoist(receiver) { phHoistSpine(receiver, dest, st) } else { receiver }
      val r2 = phBind(r0, dest, st)
      val idx2: List[Expr] = newList()
      var i = 0
      while i < indices.count {
        val e0 = if phNeedsHoist(indices[i]) { phHoistSpine(indices[i], dest, st) } else { indices[i] }
        idx2.add(phBind(e0, dest, st))
        i = i + 1
      }
      mkExpr(EIndex(receiver = r2, indices = idx2), target.span)
    }
    case _ -> target
  }
}

func phHoistTop(e: in Expr, acc: in List[Statement], st: in PropHoistState): Expr {
  match e.kind {
    case EIf(cond, thenB, elseO, thenForm) -> {
      val cond2 = if phNeedsHoist(cond) { phHoistSpine(cond, acc, st) } else { cond }
      val else2: Option[ExprOrBlock] = match elseO { case Some(eb) -> Some(value = phHoistArm(eb, st)); case None -> None }
      mkExpr(EIf(cond = cond2, thenBranch = phHoistArm(thenB, st), elseBranch = else2, thenForm = thenForm), e.span)
    }
    case EMatch(scrutinee, arms) -> {
      val scr2 = if phNeedsHoist(scrutinee) { phHoistSpine(scrutinee, acc, st) } else { scrutinee }
      val newArms: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        newArms.add(MatchArm(pattern = arm.pattern, guard = arm.guard, body = phHoistArm(arm.body, st), span = arm.span))
        i = i + 1
      }
      mkExpr(EMatch(scrutinee = scr2, arms = newArms), e.span)
    }
    case EBlock(blk) -> mkExpr(EBlock(block = phBlock(blk, st)), e.span)
    case EUnsafe(blk) -> mkExpr(EUnsafe(block = phBlock(blk, st)), e.span)
    case EParen(inner) -> mkExpr(EParen(inner = phHoistTop(inner, acc, st)), e.span)
    case _ -> phHoistSpine(e, acc, st)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Statement / block drivers.
// ─────────────────────────────────────────────────────────────────────────────
func phStmt(s: in Statement, dest: in List[Statement], st: in PropHoistState): Unit {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(pat, ty, init) -> {
          if phNeedsHoist(init) {
            val init2 = phHoistTop(init, dest, st)
            dest.add(mkStmt(SLocal(binding = LBVal(pat = pat, ty = ty, init = init2)), s.span))
          } else {
            dest.add(s)
          }
        }
        case LBLet(name, ty, init) -> {
          if phNeedsHoist(init) {
            val init2 = phHoistTop(init, dest, st)
            dest.add(mkStmt(SLocal(binding = LBLet(name = name, ty = ty, init = init2)), s.span))
          } else {
            dest.add(s)
          }
        }
        case LBVar(name, ty, initOpt) -> {
          match initOpt {
            case Some(init) -> {
              if phNeedsHoist(init) {
                val init2 = phHoistTop(init, dest, st)
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
      // #6456: a member/index target with a `?`-bearing value needs the
      // target's receiver/index operands rebound to temps (in evaluation
      // order — receiver, indices, THEN value) and the whole value bound
      // out, so the early return never fires with the receiver/index
      // already stacked on MSIL.  Records/collections are reference types
      // in both backends' ABIs, so the write through the rebound receiver
      // hits the same object; rebinding also preserves the original
      // read-before-value order if the value expression mutates a `var`
      // the target reads.
      val stacked = phAssignTargetStacks(target) and phHasHazard(value)
      val targetNeedsHoist = phNeedsHoist(target)
      val valueNeedsHoist = phNeedsHoist(value)
      if stacked {
        val target2 = phBindAssignTarget(target, dest, st)
        val value2 = phBind(phHoistTop(value, dest, st), dest, st)
        dest.add(mkStmt(SAssign(target = target2, op = op, value = value2), s.span))
      } else {
        if targetNeedsHoist or valueNeedsHoist {
          val target2 = if targetNeedsHoist { phHoistSpine(target, dest, st) } else { target }
          val value2 = if valueNeedsHoist { phHoistTop(value, dest, st) } else { value }
          dest.add(mkStmt(SAssign(target = target2, op = op, value = value2), s.span))
        } else {
          dest.add(s)
        }
      }
    }
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> {
          if phNeedsHoist(e) {
            val e2 = phHoistTop(e, dest, st)
            dest.add(mkStmt(SReturn(value = Some(value = e2)), s.span))
          } else {
            dest.add(s)
          }
        }
        case None -> dest.add(s)
      }
    }
    case SThrow(e) -> {
      if phNeedsHoist(e) {
        val e2 = phHoistTop(e, dest, st)
        dest.add(mkStmt(SThrow(expr = e2), s.span))
      } else {
        dest.add(s)
      }
    }
    case SExpr(e) -> {
      if phNeedsHoist(e) {
        val e2 = phHoistTop(e, dest, st)
        dest.add(mkStmt(SExpr(expr = e2), s.span))
      } else {
        dest.add(s)
      }
    }
    case SWhile(label, cond, body) -> {
      val body2 = phBlock(body, st)
      if phNeedsHoist(cond) {
        // The condition re-evaluates each iteration, so its bindings must
        // live inside the loop:  loop { <hoisted>; if cond { body } else
        // { break } }.  `continue` re-enters at the loop head (the hoisted
        // bindings), `break` exits — exactly `while` semantics.
        val loopStmts: List[Statement] = newList()
        val cond2 = phHoistSpine(cond, loopStmts, st)
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
      val iter2 = if phNeedsHoist(iter) { phHoistTop(iter, dest, st) } else { iter }
      dest.add(mkStmt(SFor(label = label, pat = pat, iter = iter2, body = phBlock(body, st)), s.span))
    }
    case SLoop(label, body) -> dest.add(mkStmt(SLoop(label = label, body = phBlock(body, st)), s.span))
    case SScope(binding, body) -> dest.add(mkStmt(SScope(binding = binding, body = phBlock(body, st)), s.span))
    case SDefer(body) -> dest.add(mkStmt(SDefer(body = phBlock(body, st)), s.span))
    case STry(body, catches, finallyOpt) -> {
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val c = catches[i]
        newCatches.add(CatchClause(typeName = c.typeName, bindName = c.bindName, body = phBlock(c.body, st), span = c.span))
        i = i + 1
      }
      val newFinally: Option[Block] = match finallyOpt { case Some(fb) -> Some(value = phBlock(fb, st)); case None -> None }
      dest.add(mkStmt(STry(body = phBlock(body, st), catches = newCatches, finally_ = newFinally), s.span))
    }
    case SItem(item) -> dest.add(mkStmt(SItem(item = phRewriteItem(item, st)), s.span))
    // #6453 review: hoist nested hazards out of invariant / rule expressions
    // (the qualification walk now covers them); the hoisted bindings land
    // immediately before the statement, re-evaluated per iteration when the
    // invariant sits inside a loop body.
    case SInvariant(e) -> {
      val e2 = if phNeedsHoist(e) { phHoistTop(e, dest, st) } else { e }
      dest.add(mkStmt(SInvariant(expr = e2), s.span))
    }
    case SRule(lhs, rhs) -> {
      val lhs2 = if phNeedsHoist(lhs) { phHoistTop(lhs, dest, st) } else { lhs }
      val rhs2 = if phNeedsHoist(rhs) { phHoistTop(rhs, dest, st) } else { rhs }
      dest.add(mkStmt(SRule(lhs = lhs2, rhs = rhs2), s.span))
    }
    case _ -> dest.add(s)
  }
}

func phBlock(blk: in Block, st: in PropHoistState): Block {
  val dest: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    phStmt(blk.statements[i], dest, st)
    i = i + 1
  }
  Block(statements = dest, span = blk.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// Function / item drivers.  Runs for EVERY function body (no `isAsync` gate —
// `?` is valid in plain functions), only rewriting when something qualifies.
// ─────────────────────────────────────────────────────────────────────────────
func phBodyNeedsHoist(body: in FunctionBody): Bool {
  match body {
    case FBBlock(blk) -> phNeedsHoistBlock(blk)
    case FBExpr(e) -> phNeedsHoist(e)
  }
}

func phFunctionNeedsHoist(fn: in FunctionDecl): Bool {
  match fn.body {
    case Some(body) -> phBodyNeedsHoist(body)
    case None -> false
  }
}

func phRewriteFunction(fn: in FunctionDecl, st: in PropHoistState): FunctionDecl {
  if not phFunctionNeedsHoist(fn) {
    return fn
  }
  val body = match fn.body { case Some(b) -> b; case None -> return fn }
  val newBody: FunctionBody = match body {
    case FBBlock(blk) -> FBBlock(block = phBlock(blk, st))
    case FBExpr(e) -> {
      val acc: List[Statement] = newList()
      val e2 = phHoistTop(e, acc, st)
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

func phEntryNeedsHoist(ed: in EntryDecl): Bool {
  phBodyNeedsHoist(ed.body)
}

func phRewriteEntry(ed: in EntryDecl, st: in PropHoistState): EntryDecl {
  if not phEntryNeedsHoist(ed) {
    return ed
  }
  EntryDecl(
    docComments = ed.docComments,
    annotations = ed.annotations,
    visibility = ed.visibility,
    name = ed.name,
    params = ed.params,
    ret = ed.ret,
    contracts = ed.contracts,
    body = phRewriteBody(ed.body, st),
    span = ed.span
  )
}

func phRewriteBody(body: in FunctionBody, st: in PropHoistState): FunctionBody {
  match body {
    case FBBlock(blk) -> FBBlock(block = phBlock(blk, st))
    case FBExpr(e) -> {
      val acc: List[Statement] = newList()
      val e2 = phHoistTop(e, acc, st)
      if acc.count == 0 {
        FBExpr(expr = e2)
      } else {
        acc.add(mkStmt(SExpr(expr = e2), e.span))
        FBBlock(block = Block(statements = acc, span = e.span))
      }
    }
  }
}

func phItemNeedsHoist(it: in Item): Bool {
  match it.kind {
    case IFunc(fn) -> phFunctionNeedsHoist(fn)
    case IImpl(decl) -> {
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMplFunc(fn) -> {
            if phFunctionNeedsHoist(fn) {
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
            if phFunctionNeedsHoist(fn) {
              return true
            }
          }
          case _ -> ()
        }
        i = i + 1
      }
      false
    }
    case IRecord(decl) -> phRecordNeedsHoist(decl)
    case IExposedRec(decl) -> phRecordNeedsHoist(decl)
    case IProtected(decl) -> {
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case PMFunc(fn) -> {
            if phFunctionNeedsHoist(fn) {
              return true
            }
          }
          case PMEntry(ed) -> {
            if phEntryNeedsHoist(ed) {
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

func phRecordNeedsHoist(decl: in RecordDecl): Bool {
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMFunc(fn) -> {
        if phFunctionNeedsHoist(fn) {
          return true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

func phRewriteItem(it: in Item, st: in PropHoistState): Item {
  if not phItemNeedsHoist(it) {
    return it
  }
  val newKind: ItemKind = match it.kind {
    case IFunc(fn) -> IFunc(decl = phRewriteFunction(fn, st))
    case IImpl(decl) -> {
      val newMembers: List[ImplMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMplFunc(fn) -> newMembers.add(IMplFunc(fn = phRewriteFunction(fn, st)))
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
          case IMFunc(fn) -> newMembers.add(IMFunc(fn = phRewriteFunction(fn, st)))
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
    case IRecord(decl) -> IRecord(decl = phRewriteRecord(decl, st))
    case IExposedRec(decl) -> IExposedRec(decl = phRewriteRecord(decl, st))
    case IProtected(decl) -> {
      val newMembers: List[ProtectedMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case PMFunc(fn) -> newMembers.add(PMFunc(fn = phRewriteFunction(fn, st)))
          case PMEntry(ed) -> newMembers.add(PMEntry(entryDecl = phRewriteEntry(ed, st)))
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

func phRewriteRecord(decl: in RecordDecl, st: in PropHoistState): RecordDecl {
  val newMembers: List[RecordMember] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMFunc(fn) -> newMembers.add(RMFunc(fn = phRewriteFunction(fn, st)))
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

// Entry point: hoist every qualifying `?` in `file`, returning a new
// SourceFile.  Files with nothing to hoist are returned as-is (identity).
func hoistPropagateFile(file: in SourceFile): SourceFile {
  var any = false
  var i = 0
  while i < file.items.count {
    if phItemNeedsHoist(file.items[i]) {
      any = true
      i = file.items.count
    } else {
      i = i + 1
    }
  }
  if not any {
    return file
  }
  val st = PropHoistState(counter = newList())
  val newItems: List[Item] = newList()
  var j = 0
  while j < file.items.count {
    newItems.add(phRewriteItem(file.items[j], st))
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

// ─────────────────────────────────────────────────────────────────────────────
// §3. Monad classification from a declared return type.
// ─────────────────────────────────────────────────────────────────────────────
func lastSegment(path: in ModulePath): String {
  if path.segments.count == 0 {
    ""
  } else {
    path.segments[path.segments.count - 1]
  }
}

// Classification unfolds same-file `alias` declarations before the
// Result/Option test (#1814), so e.g. `alias ParseResult[T] = Result[T,
// ParseError]` classifies as PropResult.  Only the head matters here, so no
// generic-argument substitution is needed; the unfold depth is bounded so an
// alias cycle (a type error reported elsewhere) cannot loop.  Aliases imported
// from other packages are not visible to this pass and still classify as
// PropOther — the workaround there remains writing `Result[T, E]` directly.
func classifyRetType(te: in TypeExpr, aliases: in Map[String, TypeExpr], depth: in Int): PropKind {
  if depth > 8 {
    return PropOther
  }
  match te.kind {
    case TGenericApp(head, args) -> {
      val h = lastSegment(head)
      if h == "Result" and args.count == 2 {
        PropResult
      } else if h == "Option" and args.count == 1 {
        PropOption
      } else {
        match mapGet(aliases, h) {
          case Some(rhs) -> classifyRetType(rhs, aliases, depth + 1)
          case None -> PropOther
        }
      }
    }
    case TRef(path) -> {
      match mapGet(aliases, lastSegment(path)) {
        case Some(rhs) -> classifyRetType(rhs, aliases, depth + 1)
        case None -> PropOther
      }
    }
    case TParen(inner) -> classifyRetType(inner, aliases, depth + 1)
    case _ -> PropOther
  }
}

func monadOfRet(ret: in Option[TypeExpr], aliases: in Map[String, TypeExpr]): PropKind {
  match ret {
    case None -> PropOther
    case Some(te) -> classifyRetType(te, aliases, 0)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Expression / statement / block rewriters.
//
//     Every form is reconstructed with its children rewritten so a `?` at
//     any depth is found.  Lambda bodies switch to `PropOther` because the
//     lambda's return monad is independent of the enclosing function (and the
//     backend does not yet type lambda returns); a `?` inside one therefore
//     produces the F0020 diagnostic rather than a wrong rewrite.
// ─────────────────────────────────────────────────────────────────────────────
func rewriteEob(eob: in ExprOrBlock, kind: in PropKind, st: in PropState): ExprOrBlock {
  match eob {
    case EOBExpr(e) -> EOBExpr(expr = rewriteExpr(e, kind, st))
    case EOBBlock(blk) -> EOBBlock(block = rewriteBlock(blk, kind, st))
  }
}

func rewriteExprList(es: in List[Expr], kind: in PropKind, st: in PropState): List[Expr] {
  val acc: List[Expr] = newList()
  var i = 0
  while i < es.count {
    acc.add(rewriteExpr(es[i], kind, st))
    i = i + 1
  }
  acc
}

func rewriteExpr(e: in Expr, kind: in PropKind, st: in PropState): Expr {
  match e.kind {
    case EPropagate(inner) -> {
      val inner2 = rewriteExpr(inner, kind, st)
      match kind {
        case PropResult -> buildResultMatch(inner2, e.span, st)
        case PropOption -> buildOptionMatch(inner2, e.span, st)
        case PropInLambda -> {
          st.diagnostics.add(
            errorDiagnostic(
              "F0020",
              "the `?` operator is not yet supported inside a lambda body (the lambda's return type cannot be inferred; use an explicit `match` instead)",
              e.span
            )
          )
          inner2
        }
        case PropOther -> {
          st.diagnostics.add(
            errorDiagnostic(
              "F0020",
              "the `?` operator requires the enclosing function to return Result[T, E] or Option[T]",
              e.span
            )
          )
          inner2
        }
      }
    }

    // ── Leaves — nothing to rewrite ──────────────────────────────────────────
    case ELiteral(_) -> e
    case EPath(_) -> e
    case ESelf -> e
    case EResult -> e
    case EError -> e

    // ── Recurse into children ────────────────────────────────────────────────
    case EParen(inner) -> mkExpr(EParen(inner = rewriteExpr(inner, kind, st)), e.span)
    case ETuple(exprs) -> mkExpr(ETuple(exprs = rewriteExprList(exprs, kind, st)), e.span)
    case EList(exprs) -> mkExpr(EList(exprs = rewriteExprList(exprs, kind, st)), e.span)

    case EIf(cond, thenBranch, elseOpt, thenForm) -> {
      val newElse: Option[ExprOrBlock] = match elseOpt {
        case Some(eb) -> Some(value = rewriteEob(eb, kind, st))
        case None -> None
      }
      mkExpr(
        EIf(
          cond = rewriteExpr(cond, kind, st),
          thenBranch = rewriteEob(thenBranch, kind, st),
          elseBranch = newElse,
          thenForm = thenForm
        ),
        e.span
      )
    }

    case EMatch(scrutinee, arms) -> {
      val newArms: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        val newGuard: Option[Expr] = match arm.guard {
          case Some(g) -> Some(value = rewriteExpr(g, kind, st))
          case None -> None
        }
        newArms.add(MatchArm(pattern = arm.pattern, guard = newGuard, body = rewriteEob(arm.body, kind, st), span = arm.span))
        i = i + 1
      }
      mkExpr(EMatch(scrutinee = rewriteExpr(scrutinee, kind, st), arms = newArms), e.span)
    }

    case EAwait(inner) -> mkExpr(EAwait(inner = rewriteExpr(inner, kind, st)), e.span)
    case EYield(inner) -> mkExpr(EYield(inner = rewriteExpr(inner, kind, st)), e.span)
    case ESpawn(inner) -> mkExpr(ESpawn(inner = rewriteExpr(inner, kind, st)), e.span)
    case ETry(inner) -> mkExpr(ETry(inner = rewriteExpr(inner, kind, st)), e.span)
    case EOld(inner) -> mkExpr(EOld(inner = rewriteExpr(inner, kind, st)), e.span)

    case EForall(binders, whereOpt, body) -> {
      val newWhere: Option[Expr] = match whereOpt {
        case Some(w) -> Some(value = rewriteExpr(w, kind, st))
        case None -> None
      }
      mkExpr(EForall(binders = binders, whereExpr = newWhere, body = rewriteExpr(body, kind, st)), e.span)
    }
    case EExists(binders, whereOpt, body) -> {
      val newWhere: Option[Expr] = match whereOpt {
        case Some(w) -> Some(value = rewriteExpr(w, kind, st))
        case None -> None
      }
      mkExpr(EExists(binders = binders, whereExpr = newWhere, body = rewriteExpr(body, kind, st)), e.span)
    }

    // Lambdas carry their own return monad — switch to PropInLambda so a `?` inside surfaces the lambda-specific F0020 instead of the enclosing function's.
    case ELambda(lambdaParams, body) -> mkExpr(ELambda(lambdaParams = lambdaParams, body = rewriteBlock(body, PropInLambda, st)), e.span)

    case ECall(fn, args) -> {
      val newArgs: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(v) -> newArgs.add(CAPositional(expr = rewriteExpr(v, kind, st)))
          case CANamed(n, v, asp) -> newArgs.add(CANamed(name = n, value = rewriteExpr(v, kind, st), span = asp))
        }
        i = i + 1
      }
      mkExpr(ECall(fn = rewriteExpr(fn, kind, st), args = newArgs), e.span)
    }

    case ETypeApp(fn, args) -> mkExpr(ETypeApp(fn = rewriteExpr(fn, kind, st), args = args), e.span)

    case EIndex(receiver, indices) -> mkExpr(EIndex(receiver = rewriteExpr(receiver, kind, st), indices = rewriteExprList(indices, kind, st)), e.span)

    case EMember(receiver, memberName) -> mkExpr(EMember(receiver = rewriteExpr(receiver, kind, st), memberName = memberName), e.span)

    case EPrefix(op, operand) -> mkExpr(EPrefix(op = op, operand = rewriteExpr(operand, kind, st)), e.span)

    case EBinop(op, lhs, rhs) -> mkExpr(EBinop(op = op, lhs = rewriteExpr(lhs, kind, st), rhs = rewriteExpr(rhs, kind, st)), e.span)

    case ERange(bound) -> mkExpr(ERange(bound = rewriteRangeBound(bound, kind, st)), e.span)

    case EAssign(target, op, value) -> mkExpr(EAssign(target = rewriteExpr(target, kind, st), op = op, value = rewriteExpr(value, kind, st)), e.span)

    case EBlock(block) -> mkExpr(EBlock(block = rewriteBlock(block, kind, st)), e.span)
    case EUnsafe(block) -> mkExpr(EUnsafe(block = rewriteBlock(block, kind, st)), e.span)

    case EInterpolated(segments) -> {
      val newSegs: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISText(t, sp) -> newSegs.add(ISText(text = t, span = sp))
          case ISExpr(ex) -> newSegs.add(ISExpr(expr = rewriteExpr(ex, kind, st)))
        }
        i = i + 1
      }
      mkExpr(EInterpolated(segments = newSegs), e.span)
    }
  }
}

func rewriteRangeBound(b: in RangeBound, kind: in PropKind, st: in PropState): RangeBound {
  match b {
    case RBClosed(lo, hi) -> RBClosed(lo = rewriteExpr(lo, kind, st), hi = rewriteExpr(hi, kind, st))
    case RBHalfOpen(lo, hi) -> RBHalfOpen(lo = rewriteExpr(lo, kind, st), hi = rewriteExpr(hi, kind, st))
    case RBLowerOpen(hi) -> RBLowerOpen(hi = rewriteExpr(hi, kind, st))
    case RBUpperOpen(lo) -> RBUpperOpen(lo = rewriteExpr(lo, kind, st))
  }
}

func rewriteBinding(b: in LocalBinding, kind: in PropKind, st: in PropState): LocalBinding {
  match b {
    case LBVal(pat, ty, init) -> LBVal(pat = pat, ty = ty, init = rewriteExpr(init, kind, st))
    case LBLet(name, ty, init) -> LBLet(name = name, ty = ty, init = rewriteExpr(init, kind, st))
    case LBVar(name, ty, initOpt) -> {
      val newInit: Option[Expr] = match initOpt {
        case Some(e) -> Some(value = rewriteExpr(e, kind, st))
        case None -> None
      }
      LBVar(name = name, ty = ty, init = newInit)
    }
  }
}

func rewriteCatch(c: in CatchClause, kind: in PropKind, st: in PropState): CatchClause {
  CatchClause(typeName = c.typeName, bindName = c.bindName, body = rewriteBlock(c.body, kind, st), span = c.span)
}

func rewriteStmt(s: in Statement, kind: in PropKind, st: in PropState): Statement {
  match s.kind {
    case SLocal(binding) -> mkStmt(SLocal(binding = rewriteBinding(binding, kind, st)), s.span)
    case SAssign(target, op, value) -> mkStmt(SAssign(target = rewriteExpr(target, kind, st), op = op, value = rewriteExpr(value, kind, st)), s.span)
    case SReturn(valOpt) -> {
      val newVal: Option[Expr] = match valOpt { case Some(e) -> Some(value = rewriteExpr(e, kind, st)); case None -> None }
      mkStmt(SReturn(value = newVal), s.span)
    }
    case SBreak(_) -> s
    case SContinue(_) -> s
    case SThrow(ex) -> mkStmt(SThrow(expr = rewriteExpr(ex, kind, st)), s.span)
    case STry(body, catches, finallyOpt) -> {
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        newCatches.add(rewriteCatch(catches[i], kind, st))
        i = i + 1
      }
      val newFinally: Option[Block] = match finallyOpt {
        case Some(fb) -> Some(value = rewriteBlock(fb, kind, st))
        case None -> None
      }
      mkStmt(STry(body = rewriteBlock(body, kind, st), catches = newCatches, finally_ = newFinally), s.span)
    }
    case SDefer(body) -> mkStmt(SDefer(body = rewriteBlock(body, kind, st)), s.span)
    case SScope(binding, body) -> mkStmt(SScope(binding = binding, body = rewriteBlock(body, kind, st)), s.span)
    case SFor(label, pat, iter, body) -> mkStmt(SFor(label = label, pat = pat, iter = rewriteExpr(iter, kind, st), body = rewriteBlock(body, kind, st)), s.span)
    case SWhile(label, cond, body) -> mkStmt(SWhile(label = label, cond = rewriteExpr(cond, kind, st), body = rewriteBlock(body, kind, st)), s.span)
    case SLoop(label, body) -> mkStmt(SLoop(label = label, body = rewriteBlock(body, kind, st)), s.span)
    case SInvariant(ex) -> mkStmt(SInvariant(expr = rewriteExpr(ex, kind, st)), s.span)
    case SExpr(ex) -> mkStmt(SExpr(expr = rewriteExpr(ex, kind, st)), s.span)
    case SRule(lhs, rhs) -> mkStmt(SRule(lhs = rewriteExpr(lhs, kind, st), rhs = rewriteExpr(rhs, kind, st)), s.span)
    // A nested item re-derives its own monad context.
    case SItem(item) -> mkStmt(SItem(item = rewriteItem(item, st)), s.span)
  }
}

func rewriteBlock(blk: in Block, kind: in PropKind, st: in PropState): Block {
  val acc: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    acc.add(rewriteStmt(blk.statements[i], kind, st))
    i = i + 1
  }
  Block(statements = acc, span = blk.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Function / item drivers.
// ─────────────────────────────────────────────────────────────────────────────
func rewriteFunctionBody(body: in FunctionBody, kind: in PropKind, st: in PropState): FunctionBody {
  match body {
    case FBExpr(e) -> FBExpr(expr = rewriteExpr(e, kind, st))
    case FBBlock(blk) -> FBBlock(block = rewriteBlock(blk, kind, st))
  }
}

func rewriteFunction(fn: in FunctionDecl, st: in PropState): FunctionDecl {
  match fn.body {
    case None -> fn
    case Some(body) -> {
      val kind = monadOfRet(fn.ret, st.aliases)
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
        body = Some(value = rewriteFunctionBody(body, kind, st)),
        span = fn.span
      )
    }
  }
}

func rewriteEntry(ed: in EntryDecl, st: in PropState): EntryDecl {
  val kind = monadOfRet(ed.ret, st.aliases)
  EntryDecl(
    docComments = ed.docComments,
    annotations = ed.annotations,
    visibility = ed.visibility,
    name = ed.name,
    params = ed.params,
    ret = ed.ret,
    contracts = ed.contracts,
    body = rewriteFunctionBody(ed.body, kind, st),
    span = ed.span
  )
}

func rewriteItem(it: in Item, st: in PropState): Item {
  val newKind: ItemKind = match it.kind {
    case IFunc(fn) -> IFunc(decl = rewriteFunction(fn, st))

    case IImpl(decl) -> {
      val newMembers: List[ImplMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMplFunc(fn) -> newMembers.add(IMplFunc(fn = rewriteFunction(fn, st)))
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
          case IMFunc(fn) -> newMembers.add(IMFunc(fn = rewriteFunction(fn, st)))
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

    case IProtected(decl) -> {
      val newMembers: List[ProtectedMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case PMFunc(fn) -> newMembers.add(PMFunc(fn = rewriteFunction(fn, st)))
          case PMEntry(ed) -> newMembers.add(PMEntry(entryDecl = rewriteEntry(ed, st)))
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

    // #6463: record-BODY methods (D037 `RMFunc`) were never rewritten — a
    // `?` inside one reached codegen as a raw `EPropagate`, which MSIL
    // lowers as an identity pass-through (no Err/None check at all, a
    // silent miscompile), while the §2b hoist side already descended into
    // records (`phRewriteRecord`).
    case IRecord(decl) -> IRecord(decl = rewriteRecordDecl(decl, st))
    case IExposedRec(decl) -> IExposedRec(decl = rewriteRecordDecl(decl, st))

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

func rewriteRecordDecl(decl: in RecordDecl, st: in PropState): RecordDecl {
  val newMembers: List[RecordMember] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMFunc(fn) -> newMembers.add(RMFunc(fn = rewriteFunction(fn, st)))
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
// §6. Public entry point.
// ─────────────────────────────────────────────────────────────────────────────
pub func lowerPropagateFile(file: in SourceFile): PropagateResult {
  // #6448: hoist every qualifying `?` (operand-position, stacked-context)
  // into fresh `val` bindings FIRST, before the `?` -> match rewrite below —
  // see §2b's module doc.  Every hoisted `?` lands as a statement-level
  // initializer, the shape the rewrite below already turns into safely
  // compiling IL on both targets.  A no-op (returns `file` unchanged) when
  // nothing in the file qualifies.
  val hoisted = hoistPropagateFile(file)
  val diags: List[Diagnostic] = newList()
  val aliases: Map[String, TypeExpr] = newMap()
  var ai = 0
  while ai < hoisted.items.count {
    match hoisted.items[ai].kind {
      case ITypeAlias(decl) -> {
        if not aliases.containsKey(decl.name) {
          aliases.add(decl.name, decl.rhs)
        }
      }
      case _ -> ()
    }
    ai = ai + 1
  }
  val st = newPropState(diags, aliases)
  val newItems: List[Item] = newList()
  var i = 0
  while i < hoisted.items.count {
    newItems.add(rewriteItem(hoisted.items[i], st))
    i = i + 1
  }
  val newFile = SourceFile(
    moduleDoc = hoisted.moduleDoc,
    fileAnnotations = hoisted.fileAnnotations,
    packageDecl = hoisted.packageDecl,
    imports = hoisted.imports,
    items = newItems,
    span = hoisted.span
  )
  PropagateResult(file = newFile, diagnostics = diags)
}
