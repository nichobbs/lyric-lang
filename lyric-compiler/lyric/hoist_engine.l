//! hoist_engine.l — Lyric.HoistEngine
//!
//! Shared statement-level ANF operand-position hoist, factored out of
//! `Lyric.Propagate` §2b (#6448) and `Lyric.AwaitHoist` (#5606) per #6454.
//!
//! Both passes solve the identical structural problem for two different
//! stacking hazards — a `?` (`EPropagate`) whose desugared match does an
//! early `return`, and an `await` (`EAwait`) whose MSIL state-machine
//! suspension loses whatever is on the CLR evaluation stack — with the same
//! algorithm: walk a function body, find every hazard sitting in a position
//! with operands already pushed ahead of it (a method-call receiver, an
//! earlier call/constructor argument, a list/tuple element, an index
//! operand, an interpolation segment, a non-short-circuit binop RHS, an
//! assignment's member/index target), and bind every such operand — in
//! left-to-right evaluation order — to a fresh `val` ahead of the statement,
//! so the hazard itself always ends up evaluating on an empty stack.
//!
//!     recv.m(a, HAZARD, b)   ⇒   val __fresh_0 = a
//!                                val __fresh_1 = HAZARD
//!                                recv.m(__fresh_0, __fresh_1, b)
//!
//! `Lyric.Propagate` and `Lyric.AwaitHoist` differ in exactly five
//! behavioural respects, each captured below as a `HoistConfig` field
//! rather than duplicated code (see each field's doc comment for the
//! evidence). Everything else — the presence walk, the qualification walk,
//! the spine rewrite, assign-target rebinding, the `while`-condition loop
//! restructuring, the statement/block/item/record drivers, and the
//! `ELambda`/`ESpawn`/`ETry` scope boundaries — is one implementation both
//! passes call.
//!
//! This is a LIBRARY, not a merged pass: `Lyric.Propagate` still runs in
//! `pipeCheckAndMono` (before derive/mono/weave) and `Lyric.AwaitHoist`
//! still runs LAST in `pipeWeave` (after aspect weaving) — see
//! `pipeline.l`. Each caller builds its own `HoistConfig`, threads its own
//! fresh-name prefix (so async-SM field pre-scan naming assumptions hold —
//! `__lyric_phoist_`/`__lyric_hoist_` stay distinct), and calls
//! `hoistFile(cfg, file)`.
//!
//! Scope boundaries (shared, unconditional):
//!   * `ELambda` / `ESpawn` bodies are deferred computations — a hazard
//!     inside one is not an operand of the enclosing expression, so the
//!     walk never descends into them.
//!   * `ETry` (the AST union case) is dead: the parser desugars a
//!     value-position `try { … } catch { … }` to `EBlock([STry(...)])`, a
//!     block wrapping the try as a statement — walked generically through
//!     the `EBlock` cases below, not through a `try`-specific rule. The
//!     `case ETry(_) -> false` arms below are match-exhaustiveness only.
//!   * A `while` condition containing a qualifying hazard is rewritten into
//!     `loop { <hoisted>; if cond { body } else { break } }` so the hoisted
//!     bindings re-evaluate every iteration; `continue` re-enters at the
//!     loop head.
//!   * An assignment to a MEMBER or INDEX target stacks the receiver (and
//!     any index operands) before the value evaluates on MSIL, so ANY
//!     hazard in the value qualifies even when nothing else about the value
//!     would; the target's receiver/index operands are rebound to temps in
//!     evaluation order and the whole value is bound out
//!     (`hzBindAssignTarget`). A bare-name target is a plain local store
//!     with nothing stacked and stays byte-identical.
//!   * A hazard reachable only through a `forall`/`exists` quantifier body
//!     or `old(...)` is detected by the presence/qualification walks
//!     (walk-consistency, since the contract elaborator can splice one
//!     verbatim into a body as a runtime assert argument) but not rewritten
//!     by the hoist spine — low severity, quantifiers never lower to real
//!     bytecode and `EOld` at codegen is already an ICE.
//!
//! The five configuration axes:
//!
//!   * `kind` — which AST node (`EPropagate` or `EAwait`) is this
//!     instantiation's OWN hazard. The walk still has explicit cases for
//!     BOTH node kinds (a `?` can nest inside an `await` and vice versa);
//!     the OTHER kind is always a transparent pass-through into its inner
//!     expression, never a hazard in its own right for this instantiation.
//!   * `unconditionalTryHazard` — does an `STry` statement's mere PRESENCE
//!     count as a hazard, independent of whether anything qualifying is
//!     nested inside it? `true` for `?` (#6471: entering a try's protected
//!     region with a non-empty stack is unsafe on both backends regardless
//!     of what the try contains). `false` for `await`: `Lyric.Propagate`
//!     runs first in the pipeline (`pipeCheckAndMono`, before
//!     `Lyric.AwaitHoist`'s `pipeWeave` slot) and already extracts any
//!     no-hazard try in a stacked operand position to a standalone `val`
//!     before `Lyric.AwaitHoist` ever sees the tree — verified live with an
//!     `async func` repro on both targets (D-progress-767) — so a second,
//!     redundant unconditional rule on the await side is unneeded. (A
//!     try that DOES contain an await cannot arise in the first place:
//!     V0012 rejects `await` inside `try`/`catch`/`finally` in an async
//!     function outright.)
//!   * `binopRhsHazardUnconditional` — does a non-short-circuit binop's RHS
//!     qualify the ENCLOSING statement for hoisting merely by containing a
//!     hazard (not just a nested NEED)? `true` for `?`: the MSIL emitter's
//!     LHS-spill (`phaseBSpillToLocal`) is gated on
//!     `exprContainsAwaitMsil(rhs)` and never fires for `?`, so a bare `?`
//!     in a binop RHS still crashed pre-fix (D-progress-762). `false` for
//!     `await`: the same spill already covers a bare await in binop RHS, so
//!     only a NESTED need (e.g. a call inside the RHS that itself needs
//!     hoisting) escalates.
//!   * `nestedTargetAlsoQualifies` — does the walk's OWN-kind recursive case
//!     (`EAwait(EAwait(_))`/`EPropagate(EPropagate(_))`) also qualify via
//!     raw hazard PRESENCE in its inner expression, not just a nested need?
//!     `true` for `await`: a nested await's completion is itself an operand
//!     of the outer await's expression, and the MSIL async-SM field
//!     pre-scan (`countSmFieldsMsil`) undercounts it unless flagged (#5606)
//!     — a concern specific to state-machine field counting. `false` for
//!     `?`: the parser never constructs a literal `EPropagate(EPropagate(_))`
//!     — `e??` always routes through an intervening `ECall`/`EIndex`/etc.
//!     node, so this rule has no analog for a plain `match` rewrite with no
//!     field pre-scan to keep in sync.
//!   * `asyncGated` — is the pass restricted to `async func` bodies?
//!     `true` for `await` (a blocking, non-async `await` has no suspension
//!     point, so its operand stack is never at risk — no isAsync gate would
//!     be a no-op there anyway). `false` for `?` (legal, and needing this
//!     hoist, in plain functions too). This flag also gates whether
//!     `protected type` ENTRY declarations are visited at all:
//!     `EntryDecl` has no `isAsync` field (entries can never be declared
//!     async), so under `asyncGated = true` they are permanently
//!     ineligible — matching `Lyric.AwaitHoist`'s original behaviour, which
//!     never rewrote `PMEntry` members — while `asyncGated = false` visits
//!     and rewrites them exactly like a function body, matching
//!     `Lyric.Propagate`'s `phEntryNeedsHoist`/`phRewriteEntry`.
//!
//! Public surface:
//!
//!   pub func hoistFile(cfg: in HoistConfig, file: in SourceFile): SourceFile
//!
//!     Returns a new SourceFile with every qualifying hazard hoisted under
//!     `cfg`. The input is not mutated; a file with nothing to hoist is
//!     returned as-is (identity).
package Lyric.HoistEngine

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// Configuration.
// ─────────────────────────────────────────────────────────────────────────────
pub union HoistKind {
  // This instantiation's own hazard node is `EPropagate` (the `?` operator).
  case HKPropagate
  // This instantiation's own hazard node is `EAwait`.
  case HKAwait
}

pub record HoistConfig {
  kind: HoistKind
  // Fresh-local name prefix; must stay distinct across instantiations (see
  // the module doc's async-SM field-naming note).
  freshPrefix: String
  unconditionalTryHazard: Bool
  binopRhsHazardUnconditional: Bool
  nestedTargetAlsoQualifies: Bool
  asyncGated: Bool
}

// ─────────────────────────────────────────────────────────────────────────────
// Fresh-name state threaded through the walk. `counter` is a growable cell:
// its `.count` is the next fresh-name index (the `slotTicker` idiom), so a
// plain `in` reference suffices to mutate it. The counter is per-file so
// hoist locals are unique across a whole function even when hoists occur in
// sibling blocks.
// ─────────────────────────────────────────────────────────────────────────────
record HoistState {
  counter: List[Int]
  // Names, scoped to the function/entry currently being rewritten, that are
  // provably mutable there: `out`/`inout` parameters, `var` locals declared
  // anywhere in the body — including inside a nested `ELambda`/`ESpawn` body,
  // which shares the same slot by closure capture, not a copy — and any
  // bare-name assignment target. A `Map[String, Bool]` is used as the
  // name-set (not `Set[String]`/`HashSet`: the self-hosted emitter does not
  // reliably resolve a bare `newSet()` unless its defining package is a
  // direct import, #3943 — `Map` has no such gap and is the established
  // idiom for this exact shape; see `lsp.l`'s `handleCompletion` dedup set
  // and `modechecker_check.l`'s `N0100Ctx.varNames`). Rebuilt fresh per
  // function/entry by `hzBuildMutableNames` before its body is rewritten,
  // and consulted by `hzNameLikeMutable` to gate the name-like "skip bind"
  // fast path in `hzHoistSpine` (#5629): re-reading a NAME-LIKE receiver or
  // index after a hoisted hazard is only safe when that name cannot have
  // been reassigned by whatever ran while the hazard was in flight — an
  // immutable `val`/`let`/package-qualified name is safe, but a mutable one
  // is not, since the hazard's own evaluation (an awaited call reachable
  // from the same statement, e.g. via an `inout` argument, or a
  // concurrently spawned task sharing the slot) may have reassigned it.
  mutableNames: Map[String, Bool]
  // #6684: field names declared on the enclosing record/impl-target/
  // protected-type body, resolved when statically visible from THIS file.
  // Lets `hzNameLikeMutable` treat a BARE (implicit-self) reference to one
  // of these names exactly as conservatively as the `self.<name>`/`EMember`
  // spelling already is (#6600, see the doc comment there): the type
  // checker resolves an unqualified name inside a record/impl/protected-
  // type member body against the enclosing type's own fields whenever it
  // is not a local/parameter (#6173/#6487, D-progress-774) — a spelling
  // `hzNameLikeMutable` previously had no case for at all, so it fell
  // through to `hzIsNameLikeSafe` returning `true` and reopened the exact
  // #5629/#6600 stale-receiver-read bug one spelling later. Empty for a
  // non-member function/entry (no implicit-self scope to shadow) and,
  // narrowly, for an `impl` method whose target type is declared in a
  // DIFFERENT file: this pass runs per-file with no symbol table (unlike
  // the type checker's whole-compilation-unit view), so a same-file impl
  // target resolves exactly and a cross-file one quietly yields an empty
  // map — a strictly narrower residual gap than the one this fix closes,
  // not a new one.
  selfFieldNames: Map[String, Bool]
}

func hzFresh(cfg: in HoistConfig, st: in HoistState): String {
  val n = st.counter.count
  st.counter.add(0)
  cfg.freshPrefix + toString(n)
}

// ─────────────────────────────────────────────────────────────────────────────
// AST builders (span-stamped at the hoisted expression's span).
// ─────────────────────────────────────────────────────────────────────────────
func hzPath(name: in String, sp: in Span): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  mkExpr(EPath(path = ModulePath(segments = segs, span = sp)), sp)
}

// Bind `e` to a fresh `val` appended to `acc` and return a path expression
// reading it. Literals are returned unchanged — re-evaluating a literal
// after the hoisted hazards is identical and binding it is pure noise.
func hzBind(cfg: in HoistConfig, e: in Expr, acc: in List[Statement], st: in HoistState): Expr {
  match e.kind {
    case ELiteral(_) -> e
    case _ -> {
      val name = hzFresh(cfg, st)
      val noTy: Option[TypeExpr] = None
      val noInner: Option[Pattern] = None
      val pat = mkPat(PBinding(name = name, inner = noInner), e.span)
      acc.add(mkStmt(SLocal(binding = LBVal(pat = pat, ty = noTy, init = e)), e.span))
      hzPath(name, e.span)
    }
  }
}

func hzArgExpr(a: in CallArg): Expr {
  match a {
    case CAPositional(v) -> v
    case CANamed(_, v, _) -> v
  }
}

func hzRebuildArg(a: in CallArg, e2: in Expr): CallArg {
  match a {
    case CAPositional(_) -> CAPositional(expr = e2)
    case CANamed(n, _, asp) -> CANamed(name = n, value = e2, span = asp)
  }
}

// A receiver that is just a (possibly dotted) name: a package/type qualifier
// or a plain local read. Neither needs hoisting for order preservation —
// re-reading a name after the hoisted hazards is equivalent — and a package
// qualifier MUST NOT be bound to a local (it is not a value).
func hzIsNameLike(e: in Expr): Bool {
  match e.kind {
    case EPath(_) -> true
    case ESelf -> true
    case ELiteral(_) -> true
    case EMember(recv, _) -> hzIsNameLike(recv)
    case EParen(inner) -> hzIsNameLike(inner)
    case _ -> false
  }
}

// A name-like expression is only safe to leave unbound (re-read AFTER a
// hoisted hazard, in the residual statement) when its base name cannot have
// been reassigned while the hazard was in flight. A single-segment `EPath`
// naming a mutable binding (an `out`/`inout` parameter, or a `var` declared
// anywhere in the enclosing function/entry — see `hzBuildMutableNames`) does
// not qualify: the hazard's own evaluation may itself reassign it (e.g. an
// `await`ed call reachable from the same statement takes it as an `inout`
// argument, or — under real concurrency — a spawned sibling task shares the
// slot), so re-reading it afterward risks a stale-vs-mutated read (#5629). A
// multi-segment path (a package/type qualifier) is never a reassignable
// binding and stays unconditionally safe; a literal is already excluded
// upstream by `hzIsNameLike`'s own callers gating on `hzHasHazard`.
//
// `EMember` (and `self`, which can itself be an `EMember` receiver, e.g.
// `self.box`) is NOT unconditionally safe the way a bare path base is:
// records support `var` fields, and the type checker's own mutability
// check (T0087) only fires for bare-`EPath` assignment targets — a
// member-target write like `h.box = ...` (or `self.box = ...`) is
// unchecked at the type-checker level too, so a `var` record field
// mutated through a member-write during the hoisted hazard is completely
// invisible if we only recurse to the base name's own mutability (#6600).
// We cannot cheaply prove non-`var` field-ness at this point in the
// pipeline, so conservatively treat every `EMember` receiver — and a bare
// `self` receiver, whose own fields are just as mutable — as mutable.
// This costs a spurious extra temp bind when the field genuinely is
// immutable (a minor codegen inefficiency), which is the safe direction
// to err versus the silent stale-read this replaces.
//
// A record/impl/protected-type member body may ALSO reference its own
// fields with a BARE (implicit-self) name instead of the `self.<name>`
// spelling above (#6173/#6487, D-progress-774) — `box` instead of
// `self.box`. Structurally that is a single-segment `EPath`, identical in
// shape to a local `val`/`var`/parameter read, so it needs its own case:
// `st.selfFieldNames` (built per-member from the enclosing type's OWN
// field declarations, never a broad "not a known local" guess — see its
// doc comment on `HoistState` for why precision matters here) says
// exactly which bare names are field candidates, letting a genuine local
// keep resolving exactly as it did before this case existed (#6684).
func hzNameLikeMutable(st: in HoistState, e: in Expr): Bool {
  match e.kind {
    case EPath(path) -> {
      path.segments.count == 1 and
        (st.mutableNames.containsKey(path.segments[0]) or st.selfFieldNames.containsKey(path.segments[0]))
    }
    case ESelf -> true
    case ELiteral(_) -> false
    case EMember(_, _) -> true
    case EParen(inner) -> hzNameLikeMutable(st, inner)
    case _ -> false
  }
}

// `hzIsNameLike(e) and not hzNameLikeMutable(st, e)`: the actual "safe to
// skip binding" predicate the hoist spine's receiver/index fast paths gate
// on (#5629).
func hzIsNameLikeSafe(st: in HoistState, e: in Expr): Bool {
  hzIsNameLike(e) and not hzNameLikeMutable(st, e)
}

// An assignment whose target is a member or index write stacks its receiver
// (and index operands) on MSIL BEFORE the value evaluates — the target's
// codegen pushes them with no spill-and-reload — so a top-level hazard in
// the value is a stacking risk even when nothing about the value's own
// shape would otherwise qualify it. A bare-name target is a plain local
// store with nothing stacked. (JVM is unaffected: its member/index
// assignment lowering already spills receiver/index/value to locals,
// #5936.)
func hzAssignTargetStacks(target: in Expr): Bool {
  match target.kind {
    case EParen(inner) -> hzAssignTargetStacks(inner)
    case EMember(_, _) -> true
    case EIndex(_, _) -> true
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Presence: true when evaluating `e` executes a hazard under `cfg`.
// ─────────────────────────────────────────────────────────────────────────────
func hzHasHazard(cfg: in HoistConfig, e: in Expr): Bool {
  match e.kind {
    case EPropagate(inner) -> {
      match cfg.kind {
        case HKPropagate -> true
        case HKAwait -> hzHasHazard(cfg, inner)
      }
    }
    case EAwait(inner) -> {
      match cfg.kind {
        case HKAwait -> true
        case HKPropagate -> hzHasHazard(cfg, inner)
      }
    }
    case ELambda(_, _) -> false
    case ESpawn(_) -> false
    // Match-exhaustiveness only — the parser never constructs `ETry` for
    // real source (see the module doc); unreachable from any parseable
    // program.
    case ETry(_) -> false
    case EParen(inner) -> hzHasHazard(cfg, inner)
    case ETuple(exprs) -> hzHasHazardList(cfg, exprs)
    case EList(exprs) -> hzHasHazardList(cfg, exprs)
    case EIf(cond, thenB, elseO, _) -> {
      if hzHasHazard(cfg, cond) or hzHasHazardEob(cfg, thenB) {
        true
      } else {
        match elseO {
          case Some(eb) -> hzHasHazardEob(cfg, eb)
          case None -> false
        }
      }
    }
    case EMatch(scrutinee, arms) -> {
      if hzHasHazard(cfg, scrutinee) {
        return true
      }
      var i = 0
      while i < arms.count {
        val g = match arms[i].guard { case Some(ge) -> hzHasHazard(cfg, ge); case None -> false }
        if g or hzHasHazardEob(cfg, arms[i].body) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EYield(inner) -> hzHasHazard(cfg, inner)
    case ECall(fn, args) -> {
      if hzHasHazard(cfg, fn) {
        return true
      }
      var i = 0
      while i < args.count {
        if hzHasHazard(cfg, hzArgExpr(args[i])) {
          return true
        }
        i = i + 1
      }
      false
    }
    case ETypeApp(fn, _) -> hzHasHazard(cfg, fn)
    case EIndex(receiver, indices) -> hzHasHazard(cfg, receiver) or hzHasHazardList(cfg, indices)
    case EMember(receiver, _) -> hzHasHazard(cfg, receiver)
    case EPrefix(_, operand) -> hzHasHazard(cfg, operand)
    case EBinop(_, lhs, rhs) -> hzHasHazard(cfg, lhs) or hzHasHazard(cfg, rhs)
    case ERange(bound) -> {
      match bound {
        case RBClosed(lo, hi) -> hzHasHazard(cfg, lo) or hzHasHazard(cfg, hi)
        case RBHalfOpen(lo, hi) -> hzHasHazard(cfg, lo) or hzHasHazard(cfg, hi)
        case RBLowerOpen(hi) -> hzHasHazard(cfg, hi)
        case RBUpperOpen(lo) -> hzHasHazard(cfg, lo)
      }
    }
    case EAssign(target, _, value) -> hzHasHazard(cfg, target) or hzHasHazard(cfg, value)
    case EBlock(blk) -> hzHasHazardBlock(cfg, blk)
    case EUnsafe(blk) -> hzHasHazardBlock(cfg, blk)
    case EInterpolated(segments) -> {
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISText(_, _) -> ()
          case ISExpr(ex) -> {
            if hzHasHazard(cfg, ex) {
              return true
            }
          }
        }
        i = i + 1
      }
      false
    }
    // Walk-consistency: the contract elaborator can splice a
    // `requires:`/`ensures:` quantifier or `old(...)` verbatim into a body
    // as a runtime assert argument.
    case EOld(inner) -> hzHasHazard(cfg, inner)
    case EForall(_, whereOpt, body) -> {
      val w = match whereOpt { case Some(we) -> hzHasHazard(cfg, we); case None -> false }
      w or hzHasHazard(cfg, body)
    }
    case EExists(_, whereOpt, body) -> {
      val w = match whereOpt { case Some(we) -> hzHasHazard(cfg, we); case None -> false }
      w or hzHasHazard(cfg, body)
    }
    case _ -> false
  }
}

func hzHasHazardList(cfg: in HoistConfig, es: in List[Expr]): Bool {
  var i = 0
  while i < es.count {
    if hzHasHazard(cfg, es[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func hzHasHazardEob(cfg: in HoistConfig, eob: in ExprOrBlock): Bool {
  match eob {
    case EOBExpr(e) -> hzHasHazard(cfg, e)
    case EOBBlock(blk) -> hzHasHazardBlock(cfg, blk)
  }
}

func hzHasHazardBlock(cfg: in HoistConfig, blk: in Block): Bool {
  var i = 0
  while i < blk.statements.count {
    if hzHasHazardStmt(cfg, blk.statements[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func hzHasHazardStmt(cfg: in HoistConfig, s: in Statement): Bool {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> hzHasHazard(cfg, init)
        case LBLet(_, _, init) -> hzHasHazard(cfg, init)
        case LBVar(_, _, initOpt) -> {
          match initOpt {
            case Some(init) -> hzHasHazard(cfg, init)
            case None -> false
          }
        }
      }
    }
    case SAssign(target, _, value) -> hzHasHazard(cfg, target) or hzHasHazard(cfg, value)
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> hzHasHazard(cfg, e)
        case None -> false
      }
    }
    case SThrow(e) -> hzHasHazard(cfg, e)
    case SExpr(e) -> hzHasHazard(cfg, e)
    case SWhile(_, cond, body) -> hzHasHazard(cfg, cond) or hzHasHazardBlock(cfg, body)
    case SFor(_, _, iter, body) -> hzHasHazard(cfg, iter) or hzHasHazardBlock(cfg, body)
    case SLoop(_, body) -> hzHasHazardBlock(cfg, body)
    case SScope(_, body) -> hzHasHazardBlock(cfg, body)
    case SDefer(body) -> hzHasHazardBlock(cfg, body)
    case STry(body, catches, finallyOpt) -> {
      if cfg.unconditionalTryHazard {
        true
      } else {
        if hzHasHazardBlock(cfg, body) {
          return true
        }
        var i = 0
        while i < catches.count {
          if hzHasHazardBlock(cfg, catches[i].body) {
            return true
          }
          i = i + 1
        }
        match finallyOpt {
          case Some(fb) -> hzHasHazardBlock(cfg, fb)
          case None -> false
        }
      }
    }
    case SInvariant(e) -> hzHasHazard(cfg, e)
    case SRule(lhs, rhs) -> hzHasHazard(cfg, lhs) or hzHasHazard(cfg, rhs)
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Qualification: does this subtree contain a hazard in a position that
// leaves operands stacked across it (or a nested own-kind hazard that
// desyncs a pre-scan, per `nestedTargetAlsoQualifies`)? Everything this
// predicate rejects is left byte-identical by the rewrite.
// ─────────────────────────────────────────────────────────────────────────────
func hzLastHazardArgIdx(cfg: in HoistConfig, args: in List[CallArg]): Int {
  var last = -1
  var i = 0
  while i < args.count {
    if hzHasHazard(cfg, hzArgExpr(args[i])) {
      last = i
    }
    i = i + 1
  }
  last
}

func hzNeedsHoist(cfg: in HoistConfig, e: in Expr): Bool {
  match e.kind {
    case EPropagate(inner) -> {
      match cfg.kind {
        case HKPropagate -> {
          if cfg.nestedTargetAlsoQualifies {
            hzHasHazard(cfg, inner) or hzNeedsHoist(cfg, inner)
          } else {
            hzNeedsHoist(cfg, inner)
          }
        }
        case HKAwait -> hzNeedsHoist(cfg, inner)
      }
    }
    case EAwait(inner) -> {
      match cfg.kind {
        case HKAwait -> {
          if cfg.nestedTargetAlsoQualifies {
            hzHasHazard(cfg, inner) or hzNeedsHoist(cfg, inner)
          } else {
            hzNeedsHoist(cfg, inner)
          }
        }
        case HKPropagate -> hzNeedsHoist(cfg, inner)
      }
    }
    case ECall(fn, args) -> {
      val last = hzLastHazardArgIdx(cfg, args)
      // ANY hazard-bearing argument qualifies, regardless of callee shape:
      // a bare-name (`EPath`) callee is syntactically indistinguishable
      // from a local/module-level lambda VALUE, whose invocation pushes
      // the delegate/closure reference before arguments evaluate; a
      // callee-expression call has the same stacked-callee hazard. No
      // "first-free-arg is safe" exemption (#6460/#6457).
      if last >= 0 {
        return true
      }
      if hzNeedsHoist(cfg, fn) {
        return true
      }
      var i = 0
      while i < args.count {
        if hzNeedsHoist(cfg, hzArgExpr(args[i])) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EIndex(receiver, indices) -> {
      // The receiver is stacked before the index expressions evaluate.
      if hzHasHazardList(cfg, indices) {
        return true
      }
      if hzNeedsHoist(cfg, receiver) {
        return true
      }
      var i = 0
      while i < indices.count {
        if hzNeedsHoist(cfg, indices[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    // List/tuple construction stacks the collection/earlier elements.
    case EList(exprs) -> hzHasHazardList(cfg, exprs) or hzNeedsHoistList(cfg, exprs)
    case ETuple(exprs) -> hzHasHazardList(cfg, exprs) or hzNeedsHoistList(cfg, exprs)
    // Interpolation stacks the accumulating string across segments.
    case EInterpolated(segments) -> {
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISText(_, _) -> ()
          case ISExpr(ex) -> {
            if hzHasHazard(cfg, ex) or hzNeedsHoist(cfg, ex) {
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
        // instruction consumes the LHS's pushed value before RHS runs, so a
        // bare hazard directly in the RHS is not itself a stacking hazard
        // here. Only an internally-hazardous LHS or RHS qualifies.
        hzNeedsHoist(cfg, lhs) or hzNeedsHoist(cfg, rhs)
      } else if cfg.binopRhsHazardUnconditional {
        // Regular binops push LHS unconditionally, then evaluate RHS with
        // that value still on the stack, and (under this config) there is
        // no emitter spill covering a bare hazard in the RHS — ANY hazard
        // anywhere in the RHS is a stacking hazard here, not just a nested
        // one.
        hzHasHazard(cfg, rhs) or hzNeedsHoist(cfg, lhs) or hzNeedsHoist(cfg, rhs)
      } else {
        hzNeedsHoist(cfg, lhs) or hzNeedsHoist(cfg, rhs)
      }
    }
    case EParen(inner) -> hzNeedsHoist(cfg, inner)
    case EPrefix(_, operand) -> hzNeedsHoist(cfg, operand)
    case EMember(receiver, _) -> hzNeedsHoist(cfg, receiver)
    case EYield(inner) -> hzNeedsHoist(cfg, inner)
    case ETypeApp(fn, _) -> hzNeedsHoist(cfg, fn)
    case EAssign(target, _, value) -> hzNeedsHoist(cfg, target) or hzNeedsHoist(cfg, value) or
      (hzAssignTargetStacks(target) and hzHasHazard(cfg, value))
    case EIf(cond, thenB, elseO, _) -> {
      if hzNeedsHoist(cfg, cond) or hzNeedsHoistEob(cfg, thenB) {
        true
      } else {
        match elseO {
          case Some(eb) -> hzNeedsHoistEob(cfg, eb)
          case None -> false
        }
      }
    }
    case EMatch(scrutinee, arms) -> {
      if hzNeedsHoist(cfg, scrutinee) {
        return true
      }
      var i = 0
      while i < arms.count {
        if hzNeedsHoistEob(cfg, arms[i].body) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EBlock(blk) -> hzNeedsHoistBlock(cfg, blk)
    case EUnsafe(blk) -> hzNeedsHoistBlock(cfg, blk)
    case ERange(bound) -> {
      match bound {
        case RBClosed(lo, hi) -> hzNeedsHoist(cfg, lo) or hzNeedsHoist(cfg, hi)
        case RBHalfOpen(lo, hi) -> hzNeedsHoist(cfg, lo) or hzNeedsHoist(cfg, hi)
        case RBLowerOpen(hi) -> hzNeedsHoist(cfg, hi)
        case RBUpperOpen(lo) -> hzNeedsHoist(cfg, lo)
      }
    }
    // Walk-consistency only (see `hzHasHazard`'s identical note) — no
    // hoist-spine support for these, so a qualifying hazard found only here
    // is detected but the enclosing statement's OTHER hazards (if any)
    // still get hoisted through the generic rules.
    case EOld(inner) -> hzNeedsHoist(cfg, inner)
    case EForall(_, whereOpt, body) -> {
      val w = match whereOpt { case Some(we) -> hzNeedsHoist(cfg, we); case None -> false }
      w or hzNeedsHoist(cfg, body)
    }
    case EExists(_, whereOpt, body) -> {
      val w = match whereOpt { case Some(we) -> hzNeedsHoist(cfg, we); case None -> false }
      w or hzNeedsHoist(cfg, body)
    }
    case _ -> false
  }
}

func hzNeedsHoistList(cfg: in HoistConfig, es: in List[Expr]): Bool {
  var i = 0
  while i < es.count {
    if hzNeedsHoist(cfg, es[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func hzNeedsHoistEob(cfg: in HoistConfig, eob: in ExprOrBlock): Bool {
  match eob {
    case EOBExpr(e) -> hzNeedsHoist(cfg, e)
    case EOBBlock(blk) -> hzNeedsHoistBlock(cfg, blk)
  }
}

func hzNeedsHoistBlock(cfg: in HoistConfig, blk: in Block): Bool {
  var i = 0
  while i < blk.statements.count {
    if hzNeedsHoistStmt(cfg, blk.statements[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func hzNeedsHoistStmt(cfg: in HoistConfig, s: in Statement): Bool {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> hzNeedsHoist(cfg, init)
        case LBLet(_, _, init) -> hzNeedsHoist(cfg, init)
        case LBVar(_, _, initOpt) -> {
          match initOpt {
            case Some(init) -> hzNeedsHoist(cfg, init)
            case None -> false
          }
        }
      }
    }
    case SAssign(target, _, value) -> hzNeedsHoist(cfg, target) or hzNeedsHoist(cfg, value) or
      (hzAssignTargetStacks(target) and hzHasHazard(cfg, value))
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> hzNeedsHoist(cfg, e)
        case None -> false
      }
    }
    case SThrow(e) -> hzNeedsHoist(cfg, e)
    case SExpr(e) -> hzNeedsHoist(cfg, e)
    case SWhile(_, cond, body) -> hzNeedsHoist(cfg, cond) or hzNeedsHoistBlock(cfg, body)
    case SFor(_, _, iter, body) -> hzNeedsHoist(cfg, iter) or hzNeedsHoistBlock(cfg, body)
    case SLoop(_, body) -> hzNeedsHoistBlock(cfg, body)
    case SScope(_, body) -> hzNeedsHoistBlock(cfg, body)
    case SDefer(body) -> hzNeedsHoistBlock(cfg, body)
    case STry(body, catches, finallyOpt) -> {
      if hzNeedsHoistBlock(cfg, body) {
        return true
      }
      var i = 0
      while i < catches.count {
        if hzNeedsHoistBlock(cfg, catches[i].body) {
          return true
        }
        i = i + 1
      }
      match finallyOpt {
        case Some(fb) -> hzNeedsHoistBlock(cfg, fb)
        case None -> false
      }
    }
    case SItem(item) -> hzItemNeedsHoist(cfg, item)
    case SInvariant(e) -> hzNeedsHoist(cfg, e)
    case SRule(lhs, rhs) -> hzNeedsHoist(cfg, lhs) or hzNeedsHoist(cfg, rhs)
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The spine hoist. `hzHoistSpine(cfg, e, acc, st)` appends bindings to `acc`
// and returns a residual expression whose evaluation executes no hazard at a
// hazardous stack depth (a hazard under `ELambda`/`ESpawn`/`ETry` is
// deferred or opaque, never touched). Every operand evaluated before a
// hoisted hazard is bound first, preserving left-to-right evaluation order
// exactly.
// ─────────────────────────────────────────────────────────────────────────────
func hzHoistSpine(cfg: in HoistConfig, e: in Expr, acc: in List[Statement], st: in HoistState): Expr {
  if not hzHasHazard(cfg, e) {
    return e
  }
  match e.kind {
    case EPropagate(inner) -> {
      match cfg.kind {
        case HKPropagate -> {
          val inner2 = hzHoistSpine(cfg, inner, acc, st)
          hzBind(cfg, mkExpr(EPropagate(inner = inner2), e.span), acc, st)
        }
        case HKAwait -> mkExpr(EPropagate(inner = hzHoistSpine(cfg, inner, acc, st)), e.span)
      }
    }
    case EAwait(inner) -> {
      match cfg.kind {
        case HKAwait -> {
          val inner2 = hzHoistSpine(cfg, inner, acc, st)
          hzBind(cfg, mkExpr(EAwait(inner = inner2), e.span), acc, st)
        }
        case HKPropagate -> mkExpr(EAwait(inner = hzHoistSpine(cfg, inner, acc, st)), e.span)
      }
    }
    case EParen(inner) -> mkExpr(EParen(inner = hzHoistSpine(cfg, inner, acc, st)), e.span)
    case ECall(fn, args) -> {
      val last = hzLastHazardArgIdx(cfg, args)
      val fn2 = match fn.kind {
        case EMember(recv, nm) -> {
          val recv2 = if hzHasHazard(cfg, recv) {
            hzBind(cfg, hzHoistSpine(cfg, recv, acc, st), acc, st)
          } else if last >= 0 and not hzIsNameLikeSafe(st, recv) {
            hzBind(cfg, recv, acc, st)
          } else {
            recv
          }
          mkExpr(EMember(receiver = recv2, memberName = nm), fn.span)
        }
        case EPath(_) -> fn
        case _ -> {
          if hzHasHazard(cfg, fn) {
            hzBind(cfg, hzHoistSpine(cfg, fn, acc, st), acc, st)
          } else if last >= 0 {
            hzBind(cfg, fn, acc, st)
          } else {
            fn
          }
        }
      }
      val newArgs: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        val ae = hzArgExpr(args[i])
        var ae2 = ae
        if i < last {
          val h = if hzHasHazard(cfg, ae) { hzHoistSpine(cfg, ae, acc, st) } else { ae }
          ae2 = hzBind(cfg, h, acc, st)
        } else if i == last {
          ae2 = hzHoistSpine(cfg, ae, acc, st)
        }
        newArgs.add(hzRebuildArg(args[i], ae2))
        i = i + 1
      }
      mkExpr(ECall(fn = fn2, args = newArgs), e.span)
    }
    case EIndex(receiver, indices) -> {
      var last = -1
      var li = 0
      while li < indices.count {
        if hzHasHazard(cfg, indices[li]) {
          last = li
        }
        li = li + 1
      }
      val recv2 = if hzHasHazard(cfg, receiver) {
        hzBind(cfg, hzHoistSpine(cfg, receiver, acc, st), acc, st)
      } else if last >= 0 and not hzIsNameLikeSafe(st, receiver) {
        hzBind(cfg, receiver, acc, st)
      } else {
        receiver
      }
      val newIdx: List[Expr] = newList()
      var i = 0
      while i < indices.count {
        var ix2 = indices[i]
        if i < last {
          val h = if hzHasHazard(cfg, ix2) { hzHoistSpine(cfg, ix2, acc, st) } else { ix2 }
          ix2 = hzBind(cfg, h, acc, st)
        } else if i == last {
          ix2 = hzHoistSpine(cfg, ix2, acc, st)
        }
        newIdx.add(ix2)
        i = i + 1
      }
      mkExpr(EIndex(receiver = recv2, indices = newIdx), e.span)
    }
    case ETuple(exprs) -> mkExpr(ETuple(exprs = hzHoistElems(cfg, exprs, acc, st)), e.span)
    case EList(exprs) -> mkExpr(EList(exprs = hzHoistElems(cfg, exprs, acc, st)), e.span)
    case EInterpolated(segments) -> {
      var last = -1
      var si = 0
      while si < segments.count {
        match segments[si] {
          case ISText(_, _) -> ()
          case ISExpr(ex) -> {
            if hzHasHazard(cfg, ex) {
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
              val h = if hzHasHazard(cfg, ex) { hzHoistSpine(cfg, ex, acc, st) } else { ex }
              ex2 = hzBind(cfg, h, acc, st)
            } else if i == last {
              ex2 = hzHoistSpine(cfg, ex, acc, st)
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
        // The RHS is conditionally evaluated: a hazard inside it cannot
        // move out. Binding the whole (LHS-hoisted) operator expression to
        // a `val` makes any hazard inside it run against an empty stack —
        // the shape the emitter already compiles correctly.
        val l2 = if hzHasHazard(cfg, lhs) { hzHoistSpine(cfg, lhs, acc, st) } else { lhs }
        if hzHasHazard(cfg, rhs) {
          hzBind(cfg, mkExpr(EBinop(op = op, lhs = l2, rhs = rhs), e.span), acc, st)
        } else {
          mkExpr(EBinop(op = op, lhs = l2, rhs = rhs), e.span)
        }
      } else if hzHasHazard(cfg, rhs) {
        val l2 = if hzHasHazard(cfg, lhs) { hzHoistSpine(cfg, lhs, acc, st) } else { lhs }
        val l3 = hzBind(cfg, l2, acc, st)
        val r2 = hzHoistSpine(cfg, rhs, acc, st)
        mkExpr(EBinop(op = op, lhs = l3, rhs = r2), e.span)
      } else {
        mkExpr(EBinop(op = op, lhs = hzHoistSpine(cfg, lhs, acc, st), rhs = rhs), e.span)
      }
    }
    case EPrefix(op, operand) -> mkExpr(EPrefix(op = op, operand = hzHoistSpine(cfg, operand, acc, st)), e.span)
    case EMember(receiver, memberName) -> mkExpr(
      EMember(
        receiver = hzHoistSpine(cfg, receiver, acc, st),
        memberName = memberName
      ),
      e.span
    )
    case EYield(inner) -> mkExpr(EYield(inner = hzHoistSpine(cfg, inner, acc, st)), e.span)
    case ETypeApp(fn, targs) -> mkExpr(ETypeApp(fn = hzHoistSpine(cfg, fn, acc, st), args = targs), e.span)
    case EAssign(target, op, value) -> {
      // Mirrors the `SAssign` statement rewrite: the target evaluates
      // first, so its own hazard is spilled before the value's. A
      // member/index target with a hazard-bearing value additionally needs
      // the target's receiver/index operands rebound to temps (in
      // evaluation order) and the whole value bound out, so the hazard's
      // control-flow effect never fires with the receiver/index already
      // stacked.
      if hzAssignTargetStacks(target) and hzHasHazard(cfg, value) {
        val target2 = hzBindAssignTarget(cfg, target, acc, st)
        val value2 = hzBind(cfg, hzHoistTop(cfg, value, acc, st), acc, st)
        mkExpr(EAssign(target = target2, op = op, value = value2), e.span)
      } else {
        val target2 = if hzNeedsHoist(cfg, target) { hzHoistSpine(cfg, target, acc, st) } else { target }
        mkExpr(EAssign(target = target2, op = op, value = hzHoistSpine(cfg, value, acc, st)), e.span)
      }
    }
    case EIf(cond, thenB, elseO, thenForm) -> {
      // Arms are conditionally evaluated; rewrite them internally and bind
      // the whole `if` to a `val` — a hazard inside a val-bound if/match
      // arm evaluates on an empty stack (the already-working shape).
      val cond2 = if hzHasHazard(cfg, cond) { hzHoistSpine(cfg, cond, acc, st) } else { cond }
      val then2 = hzHoistArm(cfg, thenB, st)
      val else2: Option[ExprOrBlock] = match elseO {
        case Some(eb) -> Some(value = hzHoistArm(cfg, eb, st))
        case None -> None
      }
      val armsHazard = hzHasHazardEob(cfg, thenB) or
        (match elseO { case Some(eb0) -> hzHasHazardEob(cfg, eb0); case None -> false })
      val rebuilt = mkExpr(EIf(cond = cond2, thenBranch = then2, elseBranch = else2, thenForm = thenForm), e.span)
      if armsHazard {
        hzBind(cfg, rebuilt, acc, st)
      } else {
        rebuilt
      }
    }
    case EMatch(scrutinee, arms) -> {
      val scr2 = if hzHasHazard(cfg, scrutinee) { hzHoistSpine(cfg, scrutinee, acc, st) } else { scrutinee }
      var armsHazard = false
      val newArms: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        if hzHasHazardEob(cfg, arm.body) {
          armsHazard = true
        }
        newArms.add(MatchArm(pattern = arm.pattern, guard = arm.guard, body = hzHoistArm(cfg, arm.body, st), span = arm.span))
        i = i + 1
      }
      val rebuilt = mkExpr(EMatch(scrutinee = scr2, arms = newArms), e.span)
      if armsHazard {
        hzBind(cfg, rebuilt, acc, st)
      } else {
        rebuilt
      }
    }
    case EBlock(blk) -> hzBind(cfg, mkExpr(EBlock(block = hzBlock(cfg, blk, st)), e.span), acc, st)
    case EUnsafe(blk) -> hzBind(cfg, mkExpr(EUnsafe(block = hzBlock(cfg, blk, st)), e.span), acc, st)
    case ERange(bound) -> {
      val newBound = match bound {
        case RBClosed(lo, hi) -> {
          if hzHasHazard(cfg, hi) {
            val lo2 = hzBind(cfg, hzHoistSpine(cfg, lo, acc, st), acc, st)
            RBClosed(lo = lo2, hi = hzHoistSpine(cfg, hi, acc, st))
          } else {
            RBClosed(lo = hzHoistSpine(cfg, lo, acc, st), hi = hi)
          }
        }
        case RBHalfOpen(lo, hi) -> {
          if hzHasHazard(cfg, hi) {
            val lo2 = hzBind(cfg, hzHoistSpine(cfg, lo, acc, st), acc, st)
            RBHalfOpen(lo = lo2, hi = hzHoistSpine(cfg, hi, acc, st))
          } else {
            RBHalfOpen(lo = hzHoistSpine(cfg, lo, acc, st), hi = hi)
          }
        }
        case RBLowerOpen(hi) -> RBLowerOpen(hi = hzHoistSpine(cfg, hi, acc, st))
        case RBUpperOpen(lo) -> RBUpperOpen(lo = hzHoistSpine(cfg, lo, acc, st))
      }
      mkExpr(ERange(bound = newBound), e.span)
    }
    case _ -> e
  }
}

// Positional hoist shared by tuple and list element lists.
func hzHoistElems(cfg: in HoistConfig, exprs: in List[Expr], acc: in List[Statement], st: in HoistState): List[Expr] {
  var last = -1
  var li = 0
  while li < exprs.count {
    if hzHasHazard(cfg, exprs[li]) {
      last = li
    }
    li = li + 1
  }
  val newExprs: List[Expr] = newList()
  var i = 0
  while i < exprs.count {
    var el2 = exprs[i]
    if i < last {
      val h = if hzHasHazard(cfg, el2) { hzHoistSpine(cfg, el2, acc, st) } else { el2 }
      el2 = hzBind(cfg, h, acc, st)
    } else if i == last {
      el2 = hzHoistSpine(cfg, el2, acc, st)
    }
    newExprs.add(el2)
    i = i + 1
  }
  newExprs
}

// Rewrite an if/match arm internally: block arms recurse the statement
// driver; expression arms that need hoisting become value-producing blocks
// carrying their own bindings.
func hzHoistArm(cfg: in HoistConfig, eob: in ExprOrBlock, st: in HoistState): ExprOrBlock {
  match eob {
    case EOBExpr(ae) -> {
      if hzNeedsHoist(cfg, ae) {
        val acc2: List[Statement] = newList()
        val ae2 = hzHoistTop(cfg, ae, acc2, st)
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
    case EOBBlock(blk) -> EOBBlock(block = hzBlock(cfg, blk, st))
  }
}

// Rebind a member/index assignment target's receiver and index operands to
// fresh locals, in evaluation order, so a hazard-bearing value can be
// hoisted AFTER them without reordering side effects; the write then goes
// through the temps. Receivers with their own hazards are spine-hoisted
// first. Literals stay in place (`hzBind` returns them unchanged); every
// other operand — including a bare-name receiver — is bound, because the
// value expression may mutate a `var` local the target read (the original
// order reads the target operands before the value runs).
func hzBindAssignTarget(cfg: in HoistConfig, target: in Expr, dest: in List[Statement], st: in HoistState): Expr {
  match target.kind {
    case EParen(inner) -> mkExpr(EParen(inner = hzBindAssignTarget(cfg, inner, dest, st)), target.span)
    case EMember(receiver, memberName) -> {
      val r0 = if hzNeedsHoist(cfg, receiver) { hzHoistSpine(cfg, receiver, dest, st) } else { receiver }
      mkExpr(EMember(receiver = hzBind(cfg, r0, dest, st), memberName = memberName), target.span)
    }
    case EIndex(receiver, indices) -> {
      val r0 = if hzNeedsHoist(cfg, receiver) { hzHoistSpine(cfg, receiver, dest, st) } else { receiver }
      val r2 = hzBind(cfg, r0, dest, st)
      val idx2: List[Expr] = newList()
      var i = 0
      while i < indices.count {
        val e0 = if hzNeedsHoist(cfg, indices[i]) { hzHoistSpine(cfg, indices[i], dest, st) } else { indices[i] }
        idx2.add(hzBind(cfg, e0, dest, st))
        i = i + 1
      }
      mkExpr(EIndex(receiver = r2, indices = idx2), target.span)
    }
    case _ -> target
  }
}

// Statement-position hoist: control-flow expressions that ARE the statement
// keep their shape (arms rewritten in place, no binding); everything else
// takes the spine hoist.
func hzHoistTop(cfg: in HoistConfig, e: in Expr, acc: in List[Statement], st: in HoistState): Expr {
  match e.kind {
    case EIf(cond, thenB, elseO, thenForm) -> {
      val cond2 = if hzNeedsHoist(cfg, cond) { hzHoistSpine(cfg, cond, acc, st) } else { cond }
      val else2: Option[ExprOrBlock] = match elseO {
        case Some(eb) -> Some(value = hzHoistArm(cfg, eb, st))
        case None -> None
      }
      mkExpr(EIf(cond = cond2, thenBranch = hzHoistArm(cfg, thenB, st), elseBranch = else2, thenForm = thenForm), e.span)
    }
    case EMatch(scrutinee, arms) -> {
      val scr2 = if hzNeedsHoist(cfg, scrutinee) { hzHoistSpine(cfg, scrutinee, acc, st) } else { scrutinee }
      val newArms: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        newArms.add(MatchArm(pattern = arm.pattern, guard = arm.guard, body = hzHoistArm(cfg, arm.body, st), span = arm.span))
        i = i + 1
      }
      mkExpr(EMatch(scrutinee = scr2, arms = newArms), e.span)
    }
    case EBlock(blk) -> mkExpr(EBlock(block = hzBlock(cfg, blk, st)), e.span)
    case EUnsafe(blk) -> mkExpr(EUnsafe(block = hzBlock(cfg, blk, st)), e.span)
    case EParen(inner) -> mkExpr(EParen(inner = hzHoistTop(cfg, inner, acc, st)), e.span)
    case _ -> hzHoistSpine(cfg, e, acc, st)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Statement / block drivers.
// ─────────────────────────────────────────────────────────────────────────────
func hzStmt(cfg: in HoistConfig, s: in Statement, dest: in List[Statement], st: in HoistState): Unit {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(pat, ty, init) -> {
          if hzNeedsHoist(cfg, init) {
            val init2 = hzHoistTop(cfg, init, dest, st)
            dest.add(mkStmt(SLocal(binding = LBVal(pat = pat, ty = ty, init = init2)), s.span))
          } else {
            dest.add(s)
          }
        }
        case LBLet(name, ty, init) -> {
          if hzNeedsHoist(cfg, init) {
            val init2 = hzHoistTop(cfg, init, dest, st)
            dest.add(mkStmt(SLocal(binding = LBLet(name = name, ty = ty, init = init2)), s.span))
          } else {
            dest.add(s)
          }
        }
        case LBVar(name, ty, initOpt) -> {
          match initOpt {
            case Some(init) -> {
              if hzNeedsHoist(cfg, init) {
                val init2 = hzHoistTop(cfg, init, dest, st)
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
      // Target evaluates before value, so a target needing hoisting is
      // spilled via the same `EIndex`/`EMember` spine logic any other read
      // context uses, BEFORE the value is hoisted. A member/index target
      // with a hazard-bearing value needs the target's receiver/index
      // operands rebound to temps (in evaluation order — receiver, indices,
      // THEN value) and the whole value bound out, so the hazard's
      // control-flow effect never lands with the receiver/index already
      // stacked on MSIL. Records/collections are reference types in both
      // backends' ABIs, so the write through the rebound receiver hits the
      // same object; rebinding also preserves the original read-before-
      // value order if the value expression mutates a `var` the target
      // reads.
      val stacked = hzAssignTargetStacks(target) and hzHasHazard(cfg, value)
      val targetNeedsHoist = hzNeedsHoist(cfg, target)
      val valueNeedsHoist = hzNeedsHoist(cfg, value)
      if stacked {
        val target2 = hzBindAssignTarget(cfg, target, dest, st)
        val value2 = hzBind(cfg, hzHoistTop(cfg, value, dest, st), dest, st)
        dest.add(mkStmt(SAssign(target = target2, op = op, value = value2), s.span))
      } else {
        if targetNeedsHoist or valueNeedsHoist {
          val target2 = if targetNeedsHoist { hzHoistSpine(cfg, target, dest, st) } else { target }
          val value2 = if valueNeedsHoist { hzHoistTop(cfg, value, dest, st) } else { value }
          dest.add(mkStmt(SAssign(target = target2, op = op, value = value2), s.span))
        } else {
          dest.add(s)
        }
      }
    }
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> {
          if hzNeedsHoist(cfg, e) {
            val e2 = hzHoistTop(cfg, e, dest, st)
            dest.add(mkStmt(SReturn(value = Some(value = e2)), s.span))
          } else {
            dest.add(s)
          }
        }
        case None -> dest.add(s)
      }
    }
    case SThrow(e) -> {
      if hzNeedsHoist(cfg, e) {
        val e2 = hzHoistTop(cfg, e, dest, st)
        dest.add(mkStmt(SThrow(expr = e2), s.span))
      } else {
        dest.add(s)
      }
    }
    case SExpr(e) -> {
      if hzNeedsHoist(cfg, e) {
        val e2 = hzHoistTop(cfg, e, dest, st)
        dest.add(mkStmt(SExpr(expr = e2), s.span))
      } else {
        dest.add(s)
      }
    }
    case SWhile(label, cond, body) -> {
      val body2 = hzBlock(cfg, body, st)
      if hzNeedsHoist(cfg, cond) {
        // The condition re-evaluates each iteration, so its bindings must
        // live inside the loop: loop { <hoisted>; if cond { body } else
        // { break } }. `continue` re-enters at the loop head (the hoisted
        // bindings), `break` exits — exactly `while` semantics.
        val loopStmts: List[Statement] = newList()
        val cond2 = hzHoistSpine(cfg, cond, loopStmts, st)
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
      val iter2 = if hzNeedsHoist(cfg, iter) { hzHoistTop(cfg, iter, dest, st) } else { iter }
      dest.add(mkStmt(SFor(label = label, pat = pat, iter = iter2, body = hzBlock(cfg, body, st)), s.span))
    }
    case SLoop(label, body) -> dest.add(mkStmt(SLoop(label = label, body = hzBlock(cfg, body, st)), s.span))
    case SScope(binding, body) -> dest.add(mkStmt(SScope(binding = binding, body = hzBlock(cfg, body, st)), s.span))
    case SDefer(body) -> dest.add(mkStmt(SDefer(body = hzBlock(cfg, body, st)), s.span))
    case STry(body, catches, finallyOpt) -> {
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val c = catches[i]
        newCatches.add(
          CatchClause(typeName = c.typeName, bindName = c.bindName, body = hzBlock(cfg, c.body, st), span = c.span)
        )
        i = i + 1
      }
      val newFinally: Option[Block] = match finallyOpt {
        case Some(fb) -> Some(value = hzBlock(cfg, fb, st))
        case None -> None
      }
      dest.add(mkStmt(STry(body = hzBlock(cfg, body, st), catches = newCatches, finally_ = newFinally), s.span))
    }
    case SItem(item) -> {
      // No enclosing `SourceFile` is threaded this deep into the statement
      // rewrite (#6684) — a nested `impl` here resolves its target's fields
      // only when the target itself is ALSO declared locally inside this
      // same nested item (self-contained in `hzRewriteRecord`/
      // `hzProtectedFieldNames`, no `file` needed); see
      // `hzImplTargetFieldNames`'s doc comment.
      val noFile: Option[SourceFile] = None
      dest.add(mkStmt(SItem(item = hzRewriteItem(cfg, item, st, noFile)), s.span))
    }
    case SInvariant(e) -> {
      val e2 = if hzNeedsHoist(cfg, e) { hzHoistTop(cfg, e, dest, st) } else { e }
      dest.add(mkStmt(SInvariant(expr = e2), s.span))
    }
    case SRule(lhs, rhs) -> {
      val lhs2 = if hzNeedsHoist(cfg, lhs) { hzHoistTop(cfg, lhs, dest, st) } else { lhs }
      val rhs2 = if hzNeedsHoist(cfg, rhs) { hzHoistTop(cfg, rhs, dest, st) } else { rhs }
      dest.add(mkStmt(SRule(lhs = lhs2, rhs = rhs2), s.span))
    }
    case _ -> dest.add(s)
  }
}

func hzBlock(cfg: in HoistConfig, blk: in Block, st: in HoistState): Block {
  val dest: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    hzStmt(cfg, blk.statements[i], dest, st)
    i = i + 1
  }
  Block(statements = dest, span = blk.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// Mutable-name collection (#5629). A pre-walk of a function/entry's OWN
// params + body, gathering every name that is provably mutable: an
// `out`/`inout` parameter, a `var` local declared anywhere in the body, or
// any bare-name assignment target. Descends into `ELambda`/`ESpawn` bodies
// too — unlike the hazard walk above, which treats them as opaque deferred
// computations — because a `var` captured by a nested closure shares the
// SAME slot with the enclosing function (see `async_spawn_self_test.l`'s
// `panicWithUnfinishedSpawn`, where a spawned lambda both reads and a
// sibling statement writes the same outer `var go`), so a reassignment
// reachable only through a closure still makes the outer name unsafe to
// re-read after a hoisted hazard.
// ─────────────────────────────────────────────────────────────────────────────
func hzAddMutableName(m: in Map[String, Bool], name: in String): Unit {
  if not m.containsKey(name) {
    m.add(name, true)
  }
}

// A bare (single-segment) path assignment target names a mutable binding by
// construction — the mode/type checker already rejected reassigning a
// `val`/`let` before this pass ever runs — so any `SAssign`/`EAssign` target
// of this shape is recorded regardless of whether it was also seen as an
// `LBVar` (catches a captured OUTER `var` reassigned only via a closure, and
// is a harmless no-op re-add otherwise).
func hzRecordAssignTargetName(target: in Expr, m: in Map[String, Bool]): Unit {
  match target.kind {
    case EParen(inner) -> hzRecordAssignTargetName(inner, m)
    case EPath(path) -> {
      if path.segments.count == 1 {
        hzAddMutableName(m, path.segments[0])
      }
    }
    case _ -> {
    }
  }
}

func hzCollectMutableNamesExprList(es: in List[Expr], m: in Map[String, Bool]): Unit {
  var i = 0
  while i < es.count {
    hzCollectMutableNamesExpr(es[i], m)
    i = i + 1
  }
}

func hzCollectMutableNamesEob(eob: in ExprOrBlock, m: in Map[String, Bool]): Unit {
  match eob {
    case EOBExpr(e) -> hzCollectMutableNamesExpr(e, m)
    case EOBBlock(blk) -> hzCollectMutableNamesBlock(blk, m)
  }
}

func hzCollectMutableNamesExpr(e: in Expr, m: in Map[String, Bool]): Unit {
  match e.kind {
    case EInterpolated(segments) -> {
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISText(_, _) -> {
          }
          case ISExpr(ex) -> hzCollectMutableNamesExpr(ex, m)
        }
        i = i + 1
      }
    }
    case EParen(inner) -> hzCollectMutableNamesExpr(inner, m)
    case ETuple(exprs) -> hzCollectMutableNamesExprList(exprs, m)
    case EList(exprs) -> hzCollectMutableNamesExprList(exprs, m)
    case EIf(cond, thenB, elseO, _) -> {
      hzCollectMutableNamesExpr(cond, m)
      hzCollectMutableNamesEob(thenB, m)
      match elseO {
        case Some(eb) -> hzCollectMutableNamesEob(eb, m)
        case None -> {
        }
      }
    }
    case EMatch(scrutinee, arms) -> {
      hzCollectMutableNamesExpr(scrutinee, m)
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(ge) -> hzCollectMutableNamesExpr(ge, m)
          case None -> {
          }
        }
        hzCollectMutableNamesEob(arms[i].body, m)
        i = i + 1
      }
    }
    case EAwait(inner) -> hzCollectMutableNamesExpr(inner, m)
    case EPropagate(inner) -> hzCollectMutableNamesExpr(inner, m)
    case EYield(inner) -> hzCollectMutableNamesExpr(inner, m)
    case ESpawn(inner) -> hzCollectMutableNamesExpr(inner, m)
    case ETry(inner) -> hzCollectMutableNamesExpr(inner, m)
    case EOld(inner) -> hzCollectMutableNamesExpr(inner, m)
    case EForall(_, whereOpt, body) -> {
      match whereOpt {
        case Some(we) -> hzCollectMutableNamesExpr(we, m)
        case None -> {
        }
      }
      hzCollectMutableNamesExpr(body, m)
    }
    case EExists(_, whereOpt, body) -> {
      match whereOpt {
        case Some(we) -> hzCollectMutableNamesExpr(we, m)
        case None -> {
        }
      }
      hzCollectMutableNamesExpr(body, m)
    }
    case ELambda(_, body) -> hzCollectMutableNamesBlock(body, m)
    case ECall(fn, args) -> {
      hzCollectMutableNamesExpr(fn, m)
      var i = 0
      while i < args.count {
        hzCollectMutableNamesExpr(hzArgExpr(args[i]), m)
        i = i + 1
      }
    }
    case ETypeApp(fn, _) -> hzCollectMutableNamesExpr(fn, m)
    case EIndex(receiver, indices) -> {
      hzCollectMutableNamesExpr(receiver, m)
      hzCollectMutableNamesExprList(indices, m)
    }
    case EMember(receiver, _) -> hzCollectMutableNamesExpr(receiver, m)
    case EPrefix(_, operand) -> hzCollectMutableNamesExpr(operand, m)
    case EBinop(_, lhs, rhs) -> {
      hzCollectMutableNamesExpr(lhs, m)
      hzCollectMutableNamesExpr(rhs, m)
    }
    case ERange(bound) -> {
      match bound {
        case RBClosed(lo, hi) -> {
          hzCollectMutableNamesExpr(lo, m)
          hzCollectMutableNamesExpr(hi, m)
        }
        case RBHalfOpen(lo, hi) -> {
          hzCollectMutableNamesExpr(lo, m)
          hzCollectMutableNamesExpr(hi, m)
        }
        case RBLowerOpen(hi) -> hzCollectMutableNamesExpr(hi, m)
        case RBUpperOpen(lo) -> hzCollectMutableNamesExpr(lo, m)
      }
    }
    case EAssign(target, _, value) -> {
      hzRecordAssignTargetName(target, m)
      hzCollectMutableNamesExpr(target, m)
      hzCollectMutableNamesExpr(value, m)
    }
    case EBlock(blk) -> hzCollectMutableNamesBlock(blk, m)
    case EUnsafe(blk) -> hzCollectMutableNamesBlock(blk, m)
    case _ -> {
    }
  }
}

func hzCollectMutableNamesStmt(s: in Statement, m: in Map[String, Bool]): Unit {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> hzCollectMutableNamesExpr(init, m)
        case LBLet(_, _, init) -> hzCollectMutableNamesExpr(init, m)
        case LBVar(name, _, initOpt) -> {
          hzAddMutableName(m, name)
          match initOpt {
            case Some(init) -> hzCollectMutableNamesExpr(init, m)
            case None -> {
            }
          }
        }
      }
    }
    case SAssign(target, _, value) -> {
      hzRecordAssignTargetName(target, m)
      hzCollectMutableNamesExpr(target, m)
      hzCollectMutableNamesExpr(value, m)
    }
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> hzCollectMutableNamesExpr(e, m)
        case None -> {
        }
      }
    }
    case SThrow(e) -> hzCollectMutableNamesExpr(e, m)
    case SExpr(e) -> hzCollectMutableNamesExpr(e, m)
    case SWhile(_, cond, body) -> {
      hzCollectMutableNamesExpr(cond, m)
      hzCollectMutableNamesBlock(body, m)
    }
    case SFor(_, _, iter, body) -> {
      hzCollectMutableNamesExpr(iter, m)
      hzCollectMutableNamesBlock(body, m)
    }
    case SLoop(_, body) -> hzCollectMutableNamesBlock(body, m)
    case SScope(_, body) -> hzCollectMutableNamesBlock(body, m)
    case SDefer(body) -> hzCollectMutableNamesBlock(body, m)
    case STry(body, catches, finallyOpt) -> {
      hzCollectMutableNamesBlock(body, m)
      var i = 0
      while i < catches.count {
        hzCollectMutableNamesBlock(catches[i].body, m)
        i = i + 1
      }
      match finallyOpt {
        case Some(fb) -> hzCollectMutableNamesBlock(fb, m)
        case None -> {
        }
      }
    }
    case SInvariant(e) -> hzCollectMutableNamesExpr(e, m)
    case SRule(lhs, rhs) -> {
      hzCollectMutableNamesExpr(lhs, m)
      hzCollectMutableNamesExpr(rhs, m)
    }
    case _ -> {
    }
  }
}

func hzCollectMutableNamesBlock(blk: in Block, m: in Map[String, Bool]): Unit {
  var i = 0
  while i < blk.statements.count {
    hzCollectMutableNamesStmt(blk.statements[i], m)
    i = i + 1
  }
}

func hzCollectMutableNamesParams(params: in List[Param], m: in Map[String, Bool]): Unit {
  var i = 0
  while i < params.count {
    match params[i].mode {
      case PMOut -> hzAddMutableName(m, params[i].name)
      case PMInout -> hzAddMutableName(m, params[i].name)
      case PMIn -> {
      }
    }
    i = i + 1
  }
}

func hzBuildMutableNames(params: in List[Param], body: in FunctionBody): Map[String, Bool] {
  val m: Map[String, Bool] = newMap()
  hzCollectMutableNamesParams(params, m)
  match body {
    case FBBlock(blk) -> hzCollectMutableNamesBlock(blk, m)
    case FBExpr(e) -> hzCollectMutableNamesExpr(e, m)
  }
  m
}

// ─────────────────────────────────────────────────────────────────────────────
// Self-field name sets for the #6684 bare-implicit-self-field case (see
// `HoistState.selfFieldNames`'s doc comment). Deliberately an EXACT name
// allowlist, never a "not a known local" guess: a bare single-segment
// `EPath` can also name a same-package TYPE or a free function used as a
// static-call qualifier (`Cache.default(...)`), and this pass runs AFTER
// type checking with the rewritten tree going straight to codegen with no
// re-check (see the module doc) — wrongly treating such a qualifier as a
// value to hoist-bind would try to emit `val temp = Cache`, not a
// spurious-but-safe extra bind like the mutable-local case, but a genuine
// miscompile. Restricting the set to the enclosing type's OWN declared
// field names avoids that risk entirely, since a field name colliding
// with an in-scope type/package name is exactly as unlikely as any other
// name collision this file's flat, non-scope-precise approximations
// already tolerate (see `mutableNames`'s doc comment).
// ─────────────────────────────────────────────────────────────────────────────
func hzAddFieldName(m: in Map[String, Bool], name: in String): Unit {
  if not m.containsKey(name) {
    m.add(name, true)
  }
}

func hzRecordFieldNames(members: in List[RecordMember]): Map[String, Bool] {
  val names: Map[String, Bool] = newMap()
  var i = 0
  while i < members.count {
    match members[i] {
      case RMField(field) -> hzAddFieldName(names, field.name)
      case _ -> {
      }
    }
    i = i + 1
  }
  names
}

func hzProtectedFieldNames(members: in List[ProtectedMember]): Map[String, Bool] {
  val names: Map[String, Bool] = newMap()
  var i = 0
  while i < members.count {
    match members[i] {
      case PMField(field) -> {
        match field {
          case PFVar(name, _, _, _, _, _) -> hzAddFieldName(names, name)
          case PFLet(name, _, _, _, _, _) -> hzAddFieldName(names, name)
          case PFImmutable(fd) -> hzAddFieldName(names, fd.name)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  names
}

// Resolves an `impl <Iface> for <target> { ... }` block's TARGET type's own
// field names by scanning THIS SAME FILE for a matching record/exposed-
// record/protected-type declaration. A same-file match is exact; a
// cross-file target, OR an `impl` nested inside a statement block where no
// top-level `SourceFile` is threaded (`fileOpt = None` — the `SItem` case
// deep in the statement rewrite never carries one, see `hzRewriteItem`'s
// doc comment), quietly returns an empty map — this pass has no cross-file
// symbol table, unlike the type checker (see `HoistState.selfFieldNames`'s
// doc comment), and neither residual case is new: both are narrower slices
// of the gap this fix closes, not gaps it introduces. Tracked in #6702
// (concrete plan: thread `pipeline.l`'s already-computed `monoRecordDecls`
// into `pipeWeave`'s `HoistEngine` invocation).
func hzImplTargetFieldNames(fileOpt: in Option[SourceFile], target: in TypeExpr): Map[String, Bool] {
  val noNames: Map[String, Bool] = newMap()
  val file = match fileOpt { case Some(f) -> f; case None -> return noNames }
  val targetName = match target.kind {
    case TRef(path) -> {
      if path.segments.count == 0 {
        ""
      } else {
        path.segments[path.segments.count - 1]
      }
    }
    case _ -> ""
  }
  if targetName == "" {
    return noNames
  }
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IRecord(decl) -> {
        if decl.name == targetName {
          return hzRecordFieldNames(decl.members)
        }
      }
      case IExposedRec(decl) -> {
        if decl.name == targetName {
          return hzRecordFieldNames(decl.members)
        }
      }
      case IProtected(decl) -> {
        if decl.name == targetName {
          return hzProtectedFieldNames(decl.members)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  noNames
}

// ─────────────────────────────────────────────────────────────────────────────
// Function / entry / item drivers. Under `asyncGated = true` only `async
// func` bodies are visited (a blocking, non-async hazard has no suspension
// to protect, and `EntryDecl` — no `isAsync` field, entries can never be
// async — is permanently ineligible); under `asyncGated = false` every
// function AND every protected-type entry is visited. Either way the pass
// is identity for anything that doesn't qualify.
// ─────────────────────────────────────────────────────────────────────────────
func hzBodyNeedsHoist(cfg: in HoistConfig, body: in FunctionBody): Bool {
  match body {
    case FBBlock(blk) -> hzNeedsHoistBlock(cfg, blk)
    case FBExpr(e) -> hzNeedsHoist(cfg, e)
  }
}

func hzRewriteBody(cfg: in HoistConfig, body: in FunctionBody, st: in HoistState): FunctionBody {
  match body {
    case FBBlock(blk) -> FBBlock(block = hzBlock(cfg, blk, st))
    case FBExpr(e) -> {
      val acc: List[Statement] = newList()
      val e2 = hzHoistTop(cfg, e, acc, st)
      if acc.count == 0 {
        FBExpr(expr = e2)
      } else {
        acc.add(mkStmt(SExpr(expr = e2), e.span))
        FBBlock(block = Block(statements = acc, span = e.span))
      }
    }
  }
}

func hzFunctionNeedsHoist(cfg: in HoistConfig, fn: in FunctionDecl): Bool {
  if cfg.asyncGated and not fn.isAsync {
    return false
  }
  match fn.body {
    case Some(body) -> hzBodyNeedsHoist(cfg, body)
    case None -> false
  }
}

// `selfFieldNames` is the enclosing member's own field-name set (#6684,
// `hzRecordFieldNames`/`hzProtectedFieldNames`/`hzImplTargetFieldNames`) —
// an empty map for a non-member (top-level `IFunc`, interface default
// method) `fn`.
func hzRewriteFunction(
  cfg: in HoistConfig, fn: in FunctionDecl, st: in HoistState, selfFieldNames: in Map[String, Bool]
): FunctionDecl {
  if not hzFunctionNeedsHoist(cfg, fn) {
    return fn
  }
  val body = match fn.body { case Some(b) -> b; case None -> return fn }
  val fnSt = HoistState(
    counter = st.counter,
    mutableNames = hzBuildMutableNames(fn.params, body),
    selfFieldNames = selfFieldNames
  )
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
    body = Some(value = hzRewriteBody(cfg, body, fnSt)),
    span = fn.span
  )
}

// `EntryDecl` has no `isAsync` field, so under `asyncGated = true` it is
// permanently ineligible (matching a permanently-false `fn.isAsync` check).
func hzEntryNeedsHoist(cfg: in HoistConfig, ed: in EntryDecl): Bool {
  if cfg.asyncGated {
    false
  } else {
    hzBodyNeedsHoist(cfg, ed.body)
  }
}

// `selfFieldNames` is the enclosing protected type's own field-name set
// (#6684, `hzProtectedFieldNames`) — `PMEntry` is only ever a protected-type
// member (see the module doc), so every call site has one to pass.
func hzRewriteEntry(
  cfg: in HoistConfig, ed: in EntryDecl, st: in HoistState, selfFieldNames: in Map[String, Bool]
): EntryDecl {
  if not hzEntryNeedsHoist(cfg, ed) {
    return ed
  }
  val edSt = HoistState(
    counter = st.counter,
    mutableNames = hzBuildMutableNames(ed.params, ed.body),
    selfFieldNames = selfFieldNames
  )
  EntryDecl(
    docComments = ed.docComments,
    annotations = ed.annotations,
    visibility = ed.visibility,
    name = ed.name,
    params = ed.params,
    ret = ed.ret,
    contracts = ed.contracts,
    body = hzRewriteBody(cfg, ed.body, edSt),
    span = ed.span
  )
}

func hzItemNeedsHoist(cfg: in HoistConfig, it: in Item): Bool {
  match it.kind {
    case IFunc(fn) -> hzFunctionNeedsHoist(cfg, fn)
    case IImpl(decl) -> {
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMplFunc(fn) -> {
            if hzFunctionNeedsHoist(cfg, fn) {
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
            if hzFunctionNeedsHoist(cfg, fn) {
              return true
            }
          }
          case _ -> ()
        }
        i = i + 1
      }
      false
    }
    case IRecord(decl) -> hzRecordNeedsHoist(cfg, decl)
    case IExposedRec(decl) -> hzRecordNeedsHoist(cfg, decl)
    case IProtected(decl) -> {
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case PMFunc(fn) -> {
            if hzFunctionNeedsHoist(cfg, fn) {
              return true
            }
          }
          case PMEntry(ed) -> {
            if hzEntryNeedsHoist(cfg, ed) {
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

func hzRecordNeedsHoist(cfg: in HoistConfig, decl: in RecordDecl): Bool {
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMFunc(fn) -> {
        if hzFunctionNeedsHoist(cfg, fn) {
          return true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

// `fileOpt` is the enclosing `SourceFile`, when one is threaded (#6684) —
// needed only to resolve an `IImpl` block's target type's own fields via
// `hzImplTargetFieldNames`; every other case's field-name set is
// self-contained in `it.kind` itself. `hoistFile`'s top-level driver always
// has one to pass; the `SItem` case deep in the statement rewrite (a LOCAL
// item declared inside a function body) does not thread the outer file that
// far and passes `None` — see `hzImplTargetFieldNames`'s doc comment for why
// that residual gap is narrow and pre-existing in spirit.
func hzRewriteItem(cfg: in HoistConfig, it: in Item, st: in HoistState, fileOpt: in Option[SourceFile]): Item {
  if not hzItemNeedsHoist(cfg, it) {
    return it
  }
  val noFields: Map[String, Bool] = newMap()
  val newKind: ItemKind = match it.kind {
    case IFunc(fn) -> IFunc(decl = hzRewriteFunction(cfg, fn, st, noFields))
    case IImpl(decl) -> {
      // A non-member `IMFunc` default method never has fields of its own to
      // shadow (interfaces declare no fields at all), but an `impl` block's
      // methods DO — resolved once per block, not per method.
      val implFields = hzImplTargetFieldNames(fileOpt, decl.target)
      val newMembers: List[ImplMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMplFunc(fn) -> newMembers.add(IMplFunc(fn = hzRewriteFunction(cfg, fn, st, implFields)))
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
          case IMFunc(fn) -> newMembers.add(IMFunc(fn = hzRewriteFunction(cfg, fn, st, noFields)))
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
    case IRecord(decl) -> IRecord(decl = hzRewriteRecord(cfg, decl, st))
    case IExposedRec(decl) -> IExposedRec(decl = hzRewriteRecord(cfg, decl, st))
    case IProtected(decl) -> {
      val protectedFields = hzProtectedFieldNames(decl.members)
      val newMembers: List[ProtectedMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case PMFunc(fn) -> newMembers.add(PMFunc(fn = hzRewriteFunction(cfg, fn, st, protectedFields)))
          case PMEntry(ed) -> newMembers.add(PMEntry(entryDecl = hzRewriteEntry(cfg, ed, st, protectedFields)))
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

func hzRewriteRecord(cfg: in HoistConfig, decl: in RecordDecl, st: in HoistState): RecordDecl {
  val recordFields = hzRecordFieldNames(decl.members)
  val newMembers: List[RecordMember] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMFunc(fn) -> newMembers.add(RMFunc(fn = hzRewriteFunction(cfg, fn, st, recordFields)))
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
// Public entry point.
// ─────────────────────────────────────────────────────────────────────────────
pub func hoistFile(cfg: in HoistConfig, file: in SourceFile): SourceFile {
  var any = false
  var i = 0
  while i < file.items.count {
    if hzItemNeedsHoist(cfg, file.items[i]) {
      any = true
      i = file.items.count
    } else {
      i = i + 1
    }
  }
  if not any {
    return file
  }
  // `mutableNames`/`selfFieldNames` here are placeholders: `hzRewriteFunction`/
  // `hzRewriteEntry` build their own per-function/entry maps (sharing this
  // `counter`) before ever consulting them, so this file-level state's maps
  // are never read.
  val st = HoistState(counter = newList(), mutableNames = newMap(), selfFieldNames = newMap())
  val someFile: Option[SourceFile] = Some(value = file)
  val newItems: List[Item] = newList()
  var j = 0
  while j < file.items.count {
    newItems.add(hzRewriteItem(cfg, file.items[j], st, someFile))
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
