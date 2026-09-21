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
//! The hoist WALK is shared with `Lyric.AwaitHoist` (#5606), which solves
//! the identical problem for `await`, via `Lyric.HoistEngine` (#6454); see
//! §2b's own module doc below for this pass's `HoistConfig` and
//! `Lyric.HoistEngine`'s module doc for the full design.  §2b also hoists a
//! value-producing `try { … } catch { … }` found in an operand position —
//! independent of whether it contains a `?` (#6471) — because entering the
//! try's protected region with the stack already non-empty is the same
//! class of crash.
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
import Lyric.HoistEngine

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
  // #7178: same-file top-level, non-async `func` (name, arity) pairs
  // (mirrors `aliases`' same-file-declaration approach).
  // `implicitAwaitScrutinee` uses this as an allow-list: a bare same-file
  // call is only PROVEN safe when its `name#argCount` key is in this set.
  // Everything else that isn't provably safe (a call to a same-file `async
  // func`, a cross-package/qualified call, a method call, or a call to a
  // name/arity this pass cannot resolve at all — e.g. an imported function
  // or a locally-nested `func` statement) is treated as potentially
  // hazardous rather than silently assumed safe — see
  // `isRiskyTryCallScrutinee`'s doc.  #7192: keyed by `(name, arity)`, not
  // just `name` — Lyric permits arity-based overloading of top-level
  // functions (`funcArityExists`/T0001 only rejects a same-name SAME-arity
  // redeclaration), so a name-only allow-list would misclassify a call to
  // one (async) overload as safe purely because a DIFFERENT (sync) overload
  // shares the name.
  syncFuncNames: Map[String, Bool]
  // #7197: same-file SIBLING method (name, arity) pairs of the record/impl/
  // interface whose member body is currently being rewritten — empty
  // outside any such body.  `msil/codegen.l`'s bare-call resolution
  // (`fctx.className + "/" + funcName` lookup, #6489) makes a bare call
  // resolve to a sibling method of the ENCLOSING type whenever one exists
  // by that name, UNCONDITIONALLY shadowing a same-named top-level
  // function — so `isRiskyTryCallScrutinee` must consult these sibling maps
  // FIRST and never fall through to `syncFuncNames` once a same-named
  // sibling exists, or a same-named top-level sync function would
  // incorrectly "prove" a call actually bound to an async sibling method
  // safe. `siblingAnyName` records every sibling method name (regardless of
  // arity, mirroring the codegen shadowing check itself being arity-
  // agnostic); `siblingSyncArity` records the `(name, arity)` pairs proven
  // non-async, exactly like `syncFuncNames` but scoped to the container.
  siblingAnyName: Map[String, Bool]
  siblingSyncArity: Map[String, Bool]
  // #7199: every local name (parameter, or `val`/`let`/`var` binding) bound
  // ANYWHERE in the CURRENT function — reset fresh per function entry
  // (`stateForFn`, seeded from `fn.params`) and grown in place as
  // `rewriteStmt`'s `SLocal` case walks each binding, mirroring
  // `st.diagnostics`'/`st.counter`'s "mutable reference-type cell threaded
  // through the walk" idiom. Lyric's own name resolution prefers a local
  // binding over a same-named top-level function (`resolveExprPath`'s
  // `scopeTryFind`-first order) — a bare call whose name is in this set is
  // therefore NEVER provably safe via `syncFuncNames`/sibling maps, no
  // matter what a same-named top-level function or sibling method's own
  // async-ness is, because the call may not even resolve to either of
  // them. Over-conservative rather than imprecise: once a name enters this
  // set it stays flagged for the REST of the function's rewrite, even past
  // that particular local's true lexical scope (a block-precise scope
  // stack would be exact but is not needed — see `isRiskyTryCallScrutinee`'s
  // doc for why the excess conservatism here is an acceptable, always-
  // fixable-with-an-explicit-`await` cost, not a soundness gap).
  localNames: Map[String, Bool]
  // #7170: name and `isAsync`-ness of the function currently being rewritten,
  // plus whether the rewrite point is lexically inside one of its try/
  // catch/finally regions.  See `implicitAwaitScrutinee`'s doc for why this
  // pass — not the mode checker's V0012 — has to be the one to guard against
  // an implicit `await` landing inside an async function's protected region.
  curFnName: String
  curFnAsync: Bool
  inTry: Bool
  // #7198: whether F0045 should fire at all on this target — see
  // `lowerPropagateFile`'s doc. Constant for the whole file's rewrite, so
  // every state-scoping helper below just threads it through unchanged.
  awaitInTryIsHazard: Bool
}

func newPropState(
  diags: in List[Diagnostic],
  aliases: in Map[String, TypeExpr],
  syncFuncNames: in Map[String, Bool],
  awaitInTryIsHazard: Bool,
): PropState {
  val noSiblings: Map[String, Bool] = newMap()
  val noSyncSiblings: Map[String, Bool] = newMap()
  val noLocals: Map[String, Bool] = newMap()
  PropState(
    counter = newList(),
    diagnostics = diags,
    aliases = aliases,
    syncFuncNames = syncFuncNames,
    siblingAnyName = noSiblings,
    siblingSyncArity = noSyncSiblings,
    localNames = noLocals,
    curFnName = "",
    curFnAsync = false,
    inTry = false,
    awaitInTryIsHazard = awaitInTryIsHazard
  )
}

// #7199: seeds a newly-entered function's `localNames` with its own
// parameter names — they are in scope for the entire body, unlike a
// `val`/`let`/`var`, which `rewriteStmt`'s `SLocal` case adds as the walk
// reaches it.
func localNamesFromParams(params: in List[Param]): Map[String, Bool] {
  val m: Map[String, Bool] = newMap()
  var i = 0
  while i < params.count {
    if not m.containsKey(params[i].name) {
      m.add(params[i].name, true)
    }
    i = i + 1
  }
  m
}

// Re-scope `st` to a newly-entered function body: fresh async/try context
// and a fresh `localNames` set seeded from `params` (#7199 — a function's
// own locals must never leak into a sibling function's risk analysis),
// same threaded `counter`/`diagnostics`/`aliases`/`syncFuncNames`/sibling
// maps (all reference types, so mutations through the clone stay visible
// to the caller — the same idiom `st.counter`/`st.diagnostics` already
// rely on).
func stateForFn(st: in PropState, name: in String, isAsync: Bool, params: in List[Param]): PropState {
  PropState(
    counter = st.counter,
    diagnostics = st.diagnostics,
    aliases = st.aliases,
    syncFuncNames = st.syncFuncNames,
    siblingAnyName = st.siblingAnyName,
    siblingSyncArity = st.siblingSyncArity,
    localNames = localNamesFromParams(params),
    curFnName = name,
    curFnAsync = isAsync,
    inTry = false,
    awaitInTryIsHazard = st.awaitInTryIsHazard
  )
}

// Re-scope `st` for the duration of rewriting one record/impl/interface's
// own member bodies: fresh sibling-method maps built from THAT container's
// members (#7197), everything else threaded through unchanged. Call once
// per container, before rewriting its members; a nested container (there
// is none today, but this keeps the invariant precise) would correctly
// shadow the outer one's siblings for its own body.
func stateForContainerMembers(
  st: in PropState,
  siblingAnyName: in Map[String, Bool],
  siblingSyncArity: in Map[String, Bool],
): PropState {
  PropState(
    counter = st.counter,
    diagnostics = st.diagnostics,
    aliases = st.aliases,
    syncFuncNames = st.syncFuncNames,
    siblingAnyName = siblingAnyName,
    siblingSyncArity = siblingSyncArity,
    localNames = st.localNames,
    curFnName = st.curFnName,
    curFnAsync = st.curFnAsync,
    inTry = st.inTry,
    awaitInTryIsHazard = st.awaitInTryIsHazard
  )
}

// Re-scope `st` to mark the rewrite point as lexically inside a try/catch/
// finally region of the current function — mirrors `modechecker_check.l`'s
// `AwaitTryCtx` (V0012) at the point in the pipeline where `st.inTry` is
// consulted (`implicitAwaitScrutinee`).
func stateInTry(st: in PropState): PropState {
  PropState(
    counter = st.counter,
    diagnostics = st.diagnostics,
    aliases = st.aliases,
    syncFuncNames = st.syncFuncNames,
    siblingAnyName = st.siblingAnyName,
    siblingSyncArity = st.siblingSyncArity,
    localNames = st.localNames,
    curFnName = st.curFnName,
    curFnAsync = st.curFnAsync,
    inTry = true,
    awaitInTryIsHazard = st.awaitInTryIsHazard
  )
}

// #7179: re-scope `st` when descending into a lambda body — reset `inTry`
// to `false`, mirroring `modechecker_check.l`'s `walkExprForAwaitInTry`
// `ELambda` case (`AwaitTryCtx(fnName = ctx.fnName, inTry = false, ...)`)
// exactly.  A lambda lowers to its own separately-compiled synthetic
// function/closure-class method (`msil/codegen.l`'s `collectLambdasBfsExpr`,
// ~line 10267) — it is never physically inside the enclosing function's
// try/catch/finally protected IL region, no matter how deeply the lambda
// literal is lexically nested inside a `try` block in the source.  A `?`
// written directly in the lambda's own body already can't reach F0045 (it
// classifies as `PropInLambda` and gets its own `F0020` before
// `implicitAwaitScrutinee` is ever consulted — see `rewriteExpr`'s
// `EPropagate` case), so this reset is currently a no-op for F0045
// specifically; it is kept anyway so `st.inTry` stays a precise "lexically
// inside the CURRENT function's own try region" invariant for any future
// consumer, matching V0012's own invariant exactly rather than leaving a
// latent mismatch between the two passes.
func stateForLambda(st: in PropState): PropState {
  PropState(
    counter = st.counter,
    diagnostics = st.diagnostics,
    aliases = st.aliases,
    syncFuncNames = st.syncFuncNames,
    siblingAnyName = st.siblingAnyName,
    siblingSyncArity = st.siblingSyncArity,
    localNames = st.localNames,
    curFnName = st.curFnName,
    curFnAsync = st.curFnAsync,
    inTry = false,
    awaitInTryIsHazard = st.awaitInTryIsHazard
  )
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

// #6920: `expr?` used to desugar straight to `match expr { ... }`, using
// whatever `expr` evaluates to as the scrutinee verbatim.  When `expr` is a
// direct call to an `async func` (implicit-await propagation — no literal
// `await` in the source, e.g. `mayFail(3)?`), that scrutinee is the async
// kickoff's raw `Task<Result[T,E]>` (MSIL: `cctx.funcRetTypes` records the
// Task-wrapped kickoff return for every async func, in-bundle or restored —
// see `msil/codegen.l`'s `seedAsyncFuncRetTypePlaceholderMsil` /
// `registerRestoredFunc`), never the awaited `Result[T,E]` itself — the
// unwrap ONLY happens through the dedicated `EAwait` AST node's codegen.
// Testing a Task value against `Ok(v)`/`Err(x)` (or `Some`/`None`) patterns
// silently fails to bind `v`/the payload (the match codegen has no case
// shape for a Task-typed scrutinee), which only surfaces later as a T0115
// "cannot resolve name" panic at the first read of the synthesized
// `__lyric_prop_v<n>` — a confusing, far-from-the-cause diagnostic for what
// is really a missing implicit await.
//
// Wrapping the scrutinee in an explicit `EAwait` here — unless the caller
// already wrote one (`(await mayFail(3))?`) — makes `expr?` match the
// language reference's "a direct call to an async function awaits in place
// with or without the `await` keyword" rule (docs/01 §7.1) and reuses
// EXACTLY the already-verified-correct codegen path the explicit-`await`
// spelling goes through (Phase B suspend/resume inside an async function,
// a blocking `GetAwaiter().GetResult()` shim otherwise).  It is safe for
// every OTHER scrutinee shape too: `EAwait`'s own codegen is a no-op
// pass-through whenever the awaited value is not actually Task-shaped
// (`isTaskTypeMsil` false) — so wrapping a plain synchronous
// `Result`/`Option` value (the overwhelmingly common case, e.g. `x?` on a
// local `val x: Result[Int, String]`) costs nothing: zero extra
// instructions are ever emitted for it.
//
// #7170 (review finding on #6920's fix): the mode checker's V0012 rejects
// `await` inside a try/catch/finally in an async function, because the CLR
// verifier rejects `AwaitUnsafeOnCompleted` inside a protected region — a
// suspend/resume sequence physically inside a `try`.  V0012 is a purely
// syntactic walk over literal `EAwait` nodes that runs during mode checking
// (`pipeCheckAndMono`'s `checkFile`), which happens BEFORE this pass
// (`lowerPropagateFile`) synthesizes the implicit `EAwait` above — so V0012
// can never see it.  Left unguarded, `try { val x = asyncCall()?; ... }
// catch ... { ... }` inside an `async func` would silently regress from a
// safe (if confusing) T0115 compile failure pre-#6920 to invalid IL that
// builds successfully and crashes at JIT/runtime.
//
// Fix it here instead: this pass already knows, at the exact moment it is
// about to synthesize the implicit `EAwait`, whether the enclosing function
// is async (`st.curFnAsync`) and whether the rewrite point is lexically
// inside one of its try/catch/finally regions (`st.inTry`, threaded by
// `stateForFn`/`stateInTry` — see `PropState`'s doc).  When both hold, reject
// with a clear diagnostic instead of emitting the hazardous implicit await.
// A caller who wrote the `await` explicitly is UNCHANGED — V0012 already
// catches that spelling correctly, at the correct pipeline stage, with its
// own diagnostic; this guard only covers the implicit-rewrite case V0012
// structurally cannot reach.  Extending V0012 itself to see the implicit
// await (or to reason about async-ness across package boundaries) is a
// larger, separately-tracked follow-up — see docs/decisions/D-progress-0941.
func implicitAwaitScrutinee(inner: in Expr, sp: in Span, st: in PropState): Expr {
  if isAlreadyAwaitedExpr(inner) {
    inner
  } else if st.awaitInTryIsHazard and st.curFnAsync and st.inTry and isRiskyTryCallScrutinee(inner, st) {
    st.diagnostics.add(
      errorDiagnostic(
        "F0045",
        "the `?` operator's implicit `await` of this call inside a try/catch/finally in async function '" + st.curFnName +
          "' cannot be proven safe here (only a direct call to a same-file non-async function or sibling method, " +
          "or a builtin Ok/Err/Some/None constructor, is) and, if the call is actually async, would emit invalid " +
          "IL (the CLR verifier rejects a suspend/resume sequence inside a protected region — see V0012); await " +
          "the call explicitly before or after the try block instead",
        sp
      )
    )
    inner
  } else {
    mkExpr(EAwait(inner = inner), inner.span)
  }
}

func isAlreadyAwaitedExpr(e: in Expr): Bool {
  match e.kind {
    case EParen(paren) -> isAlreadyAwaitedExpr(paren)
    case EAwait(_) -> true
    case _ -> false
  }
}

// A bare reference to one of the four builtin union constructors is always
// synchronous no matter the surrounding context — `Ok(v)?`/`Err(e)?`/
// `Some(v)?`/`None` never need (or benefit from) an await, so they are
// never risky even though they aren't in `st.syncFuncNames` (they're not a
// same-file `func` declaration at all).
func isBuiltinMonadCtorName(name: in String): Bool {
  name == "Ok" or name == "Err" or name == "Some" or name == "None"
}

// #7192: `syncFuncNames` is keyed by `(name, arity)`, not just `name` — see
// `PropState.syncFuncNames`'s doc for why (arity-based overloading means a
// same-named sync and async top-level function can coexist in the same
// file). Both the build site (`lowerPropagateFile`) and the lookup site
// (`isRiskyTryCallScrutinee`) must format this key identically.
func syncFuncArityKey(name: in String, arity: in Int): String {
  name + "#" + toString(arity)
}

// #7174/#7178: F0045 (above) must fire for exactly the scrutinee shapes that
// CANNOT be proven safe, not just the one shape #7170 originally targeted
// (a direct call to a same-file `async func`).  Two classes exist:
//
//   * Provably safe, never flagged: anything that isn't a call at all (a
//     bare local variable, a field access, …), and a bare same-file call to
//     a function this pass has proven is NOT `async` (`st.syncFuncNames`)
//     or to a builtin monad constructor.  Neither ever produces a
//     Task-shaped scrutinee, so `EAwait`'s no-op-when-not-Task-shaped
//     codegen (see the #6920 doc above) makes wrapping them in an implicit
//     await free.
//
//   * Everything else is treated as RISKY (flagged) rather than silently
//     assumed safe, because this pass cannot prove it safe without
//     cross-package/cross-scope type information it doesn't have: a call to
//     a same-file `async func` (#7170's original case), a qualified/
//     cross-package call or a method call (both parse as `ECall(fn =
//     EMember(...))` — see `parsePostfixExpr`'s `Dot` case, there is no
//     separate "qualified path call" AST shape to special-case), and a bare
//     call whose name resolves to neither `syncFuncNames` nor a builtin
//     constructor — which covers an imported function brought into scope
//     unqualified, AND a locally-nested `func`/lambda-bound callable (#7178
//     found this exact shape unflagged: a nested `async func` statement is
//     never collected into any same-file top-level name set, so leaving it
//     assumed-safe would silently regress it to the invalid-IL hazard this
//     diagnostic exists to close). This mirrors the pre-#6920 baseline,
//     where every one of these shapes already failed to compile (a safe,
//     if confusing, `T0115`) rather than building invalid IL.
//
//   * #7185: a composite `if`/`match`/`try`-as-expression scrutinee (e.g.
//     `(if cond { asyncCall1() } else { asyncCall2() })?`) is ALSO risky —
//     `msil/codegen.l`'s own Phase-B pre-scan (`inferCallReturnTypePB`) has
//     dedicated `EIf`/`EMatch` cases specifically because these really can
//     thread a Task-shaped value up from a branch's tail expression, exactly
//     like a bare direct call. This pass does not (and, without real type
//     information, cannot cheaply) inspect individual branches to rule that
//     out, so `EIf`/`EMatch` scrutinees are flagged unconditionally rather
//     than risking the same silent-regress-to-invalid-IL class #7178 closed
//     for `ECall`. A value-position `try { … } catch … { … }` scrutinee is
//     the same hazard, but the parser never produces the `ETry` AST case for
//     it — it desugars to `EBlock([STry(...)])` instead (see
//     `hoist_engine.l`'s own "`ETry` … is dead" note); `blockEndsInTry`
//     below recognizes that actual shape.
func blockEndsInTry(blk: in Block): Bool {
  if blk.statements.count == 0 {
    false
  } else {
    match blk.statements[blk.statements.count - 1].kind {
      case STry(_, _, _) -> true
      case _ -> false
    }
  }
}

func isRiskyTryCallScrutinee(inner: in Expr, st: in PropState): Bool {
  match inner.kind {
    case EParen(paren) -> isRiskyTryCallScrutinee(paren, st)
    case ECall(fn, args) -> {
      match fn.kind {
        case EPath(path) -> {
          if path.segments.count == 1 {
            val name = path.segments[0]
            // #7199: a local (parameter, or `val`/`let`/`var`/`for`-pattern/
            // `catch`-bind) shadowing this bare name ALWAYS wins name
            // resolution over both a sibling method and a top-level
            // function (Lyric's own `resolveExprPath` tries local scope
            // first). Once such a local exists, this pass has no static
            // type information to prove what it's bound to (a value, an
            // async function reference, a lambda...), so the call can never
            // be classified safe via either allow-list below.
            if st.localNames.containsKey(name) {
              true
            } else if st.siblingAnyName.containsKey(name) {
              // #7197: a same-named sibling method of the enclosing record/
              // impl/interface — if one exists — ALWAYS wins bare-call
              // resolution over a same-named top-level function (mirroring
              // `msil/codegen.l`'s `fctx.className + "/" + funcName`
              // shadowing, #6489). Once a sibling of this name exists, the
              // top-level `syncFuncNames` allow-list must never be consulted
              // for it — only the sibling's own (proven) sync-ness does.
              not st.siblingSyncArity.containsKey(syncFuncArityKey(name, args.count))
            } else {
              val key = syncFuncArityKey(name, args.count)
              not (st.syncFuncNames.containsKey(key) or isBuiltinMonadCtorName(name))
            }
          } else {
            true
          }
        }
        case _ -> true
      }
    }
    case EIf(_, _, _, _) -> true
    case EMatch(_, _) -> true
    case EBlock(blk) -> blockEndsInTry(blk)
    // A value-position `unsafe { … }` block (`@unsafe_ffi`/`NativePtr` work
    // per docs/01) can still tail-yield an ordinary call — nothing about
    // `unsafe` restricts what's INSIDE the block to FFI-only expressions,
    // it only widens what's ALLOWED there. Same composite-scrutinee hazard
    // as `EIf`/`EMatch`, flagged the same conservative way.
    case EUnsafe(_) -> true
    // `ETry` is match-exhaustiveness only — the parser never constructs it
    // (see the doc above); it can never actually be observed here.
    case ETry(_) -> false
    case _ -> false
  }
}

// `match (await inner) { case Ok(v) -> v; case Err(x) -> { return Err(x) } }`
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
  mkExpr(EMatch(scrutinee = implicitAwaitScrutinee(inner, sp, st), arms = arms), sp)
}

// `match (await inner) { case Some(v) -> v; case None -> { return None } }`
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
  mkExpr(EMatch(scrutinee = implicitAwaitScrutinee(inner, sp, st), arms = arms), sp)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2b (#6448, unified into `Lyric.HoistEngine` per #6454). Statement-level
// ANF hoist for `?` in operand position, run BEFORE the match rewrite below,
// for `?` found in operand position (a method-call argument — the receiver
// is a stacked operand ahead of it — or a non-first argument of a free
// call, a list/tuple/interpolation element, a binop/index operand, …).
// Left alone, the synthesised match's early `return Err(x)` / `return None`
// fires with operands already pushed on the evaluation stack:
// `InvalidProgramException` on MSIL, inconsistent stackmap frames on JVM.
//
// The hoist ENGINE (walk, qualification, spine rewrite, assign-target
// rebinding, `while`-loop restructuring, scope boundaries) is shared with
// `Lyric.AwaitHoist` (#5606) via `Lyric.HoistEngine` (#6454) — see that
// package's module doc for the full design, the five configuration axes,
// and the evidence for each. This pass's own `HoistConfig`:
//
//   * `kind = HKPropagate` — `EPropagate` is this instantiation's own
//     hazard node; `EAwait` is a transparent pass-through.
//   * `freshPrefix = "__lyric_phoist_"` — distinct from AwaitHoist's
//     `__lyric_hoist_` (async-SM field-naming assumption).
//   * `unconditionalTryHazard = true` (#6471) — an `STry` statement is
//     itself a stacking hazard, independent of whether a `?` is nested
//     inside it (entering the protected region with a non-empty stack is
//     unsafe on both backends regardless of contents).
//   * `binopRhsHazardUnconditional = true` (D-progress-762) — the MSIL
//     emitter's LHS-spill (`phaseBSpillToLocal`) never fires for `?`, so a
//     bare `?` in a non-short-circuit binop RHS must be caught here.
//   * `nestedTargetAlsoQualifies = false` — the parser never constructs a
//     literal `EPropagate(EPropagate(_))` (`e??` always routes through an
//     intervening `ECall`/`EIndex`/…), so there is no analog of
//     AwaitHoist's nested-await pre-scan concern.
//   * `asyncGated = false` — `?` is legal (and needs this hoist) in plain
//     functions too, unlike `await`; `protected type` entries are visited.
//
// Unlike `await`, `?` is legal in PLAIN functions too (not just `async
// func`), so this pass runs unconditionally over every function body — see
// `asyncGated` above.
// ─────────────────────────────────────────────────────────────────────────────
func propagateHoistConfig(): HoistConfig {
  HoistConfig(
    kind = HKPropagate,
    freshPrefix = "__lyric_phoist_",
    unconditionalTryHazard = true,
    binopRhsHazardUnconditional = true,
    nestedTargetAlsoQualifies = false,
    asyncGated = false
  )
}

// Entry point: hoist every qualifying `?` in `file`, returning a new
// SourceFile. Files with nothing to hoist are returned as-is (identity).
// `?`-hoisting runs earlier in the pipeline than `AwaitHoist` (inside
// `pipeCheckAndMono`, before mono) with no cross-file record index of its
// own yet threaded to it, so an `impl` block's cross-file target still
// resolves narrowly here (same-file only) — see `HoistEngine`'s
// `typeFieldIndex` doc comment; #6702's fix targets `pipeWeave`'s
// `AwaitHoist` call specifically.
func hoistPropagateFile(file: in SourceFile): SourceFile {
  val noExtraRecords: List[RecordDecl] = newList()
  hoistFile(propagateHoistConfig(), file, noExtraRecords)
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
      val newScrutinee = rewriteExpr(scrutinee, kind, st)
      val newArms: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        // #7200: an arm's pattern binds names in scope for BOTH its guard
        // and its body — must be registered before either is rewritten,
        // same as `SFor`'s loop pattern and `LBVal`'s destructuring.
        collectPatternBoundNames(arm.pattern, st.localNames)
        val newGuard: Option[Expr] = match arm.guard {
          case Some(g) -> Some(value = rewriteExpr(g, kind, st))
          case None -> None
        }
        newArms.add(MatchArm(pattern = arm.pattern, guard = newGuard, body = rewriteEob(arm.body, kind, st), span = arm.span))
        i = i + 1
      }
      mkExpr(EMatch(scrutinee = newScrutinee, arms = newArms), e.span)
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
    // #7179: also reset `inTry` (see `stateForLambda`'s doc) — a lambda body is never inside the enclosing function's own try/catch/finally protected region.
    case ELambda(lambdaParams, body) -> mkExpr(
      ELambda(
        lambdaParams = lambdaParams,
        body = rewriteBlock(body, PropInLambda, stateForLambda(st))
      ),
      e.span
    )

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

    case EIndex(receiver, indices) -> mkExpr(
      EIndex(
        receiver = rewriteExpr(receiver, kind, st),
        indices = rewriteExprList(indices, kind, st)
      ),
      e.span
    )

    case EMember(receiver, memberName) -> mkExpr(
      EMember(receiver = rewriteExpr(receiver, kind, st), memberName = memberName),
      e.span
    )

    case EPrefix(op, operand) -> mkExpr(EPrefix(op = op, operand = rewriteExpr(operand, kind, st)), e.span)

    case EBinop(op, lhs, rhs) -> mkExpr(
      EBinop(op = op, lhs = rewriteExpr(lhs, kind, st), rhs = rewriteExpr(rhs, kind, st)),
      e.span
    )

    case ERange(bound) -> mkExpr(ERange(bound = rewriteRangeBound(bound, kind, st)), e.span)

    case EAssign(target, op, value) -> mkExpr(
      EAssign(
        target = rewriteExpr(target, kind, st),
        op = op,
        value = rewriteExpr(value, kind, st)
      ),
      e.span
    )

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
    case RBHalfOpen(lo, hi, bareDotDot) -> RBHalfOpen(
      lo = rewriteExpr(lo, kind, st),
      hi = rewriteExpr(hi, kind, st),
      bareDotDot = bareDotDot
    )
    case RBLowerOpen(hi) -> RBLowerOpen(hi = rewriteExpr(hi, kind, st))
    case RBUpperOpen(lo) -> RBUpperOpen(lo = rewriteExpr(lo, kind, st))
  }
}

// #7199: adds every name a pattern binds into `acc` — covers destructuring
// `val` bindings (`val (a, b) = pair`, `val Some(x) = opt`, `val Point { x,
// y } = p`, an `@`-style `PBinding(name, inner)` nested pattern, etc.), not
// just the common single-bare-name case.
func collectPatternBoundNames(pat: in Pattern, acc: in Map[String, Bool]): Unit {
  match pat.kind {
    case PBinding(name, inner) -> {
      if not acc.containsKey(name) {
        acc.add(name, true)
      }
      match inner {
        case Some(p) -> collectPatternBoundNames(p, acc)
        case None -> {
        }
      }
    }
    case PConstructor(_, args) -> {
      var i = 0
      while i < args.count {
        collectPatternBoundNames(args[i], acc)
        i = i + 1
      }
    }
    case PRecord(_, fields, _) -> {
      var i = 0
      while i < fields.count {
        match fields[i] {
          case RPFNamed(_, p, _) -> collectPatternBoundNames(p, acc)
          case RPFShort(name, _) -> {
            if not acc.containsKey(name) {
              acc.add(name, true)
            }
          }
        }
        i = i + 1
      }
    }
    case PTuple(patterns) -> {
      var i = 0
      while i < patterns.count {
        collectPatternBoundNames(patterns[i], acc)
        i = i + 1
      }
    }
    case PParen(inner) -> collectPatternBoundNames(inner, acc)
    case PTypeTest(inner, _) -> collectPatternBoundNames(inner, acc)
    case POr(patterns) -> {
      var i = 0
      while i < patterns.count {
        collectPatternBoundNames(patterns[i], acc)
        i = i + 1
      }
    }
    case PWildcard -> {
    }
    case PLiteral(_) -> {
    }
    case PRange(_, _, _, _) -> {
    }
    case PConstRef(_) -> {
    }
    case PError -> {
    }
  }
}

func rewriteBinding(b: in LocalBinding, kind: in PropKind, st: in PropState): LocalBinding {
  match b {
    case LBVal(pat, ty, init) -> {
      val newInit = rewriteExpr(init, kind, st)
      collectPatternBoundNames(pat, st.localNames)
      LBVal(pat = pat, ty = ty, init = newInit)
    }
    case LBLet(name, ty, init) -> {
      val newInit = rewriteExpr(init, kind, st)
      if not st.localNames.containsKey(name) {
        st.localNames.add(name, true)
      }
      LBLet(name = name, ty = ty, init = newInit)
    }
    case LBVar(name, ty, initOpt) -> {
      val newInit: Option[Expr] = match initOpt {
        case Some(e) -> Some(value = rewriteExpr(e, kind, st))
        case None -> None
      }
      if not st.localNames.containsKey(name) {
        st.localNames.add(name, true)
      }
      LBVar(name = name, ty = ty, init = newInit)
    }
  }
}

func rewriteCatch(c: in CatchClause, kind: in PropKind, st: in PropState): CatchClause {
  // #7199: a `catch T as name` bind name is in scope for the catch body —
  // over-conservative to include (it's never itself callable), but keeps
  // `st.localNames` a precise superset of every binding form.
  match c.bindName {
    case Some(name) -> {
      if not st.localNames.containsKey(name) {
        st.localNames.add(name, true)
      }
    }
    case None -> {
    }
  }
  CatchClause(typeName = c.typeName, bindName = c.bindName, body = rewriteBlock(c.body, kind, st), span = c.span)
}

func rewriteStmt(s: in Statement, kind: in PropKind, st: in PropState): Statement {
  match s.kind {
    case SLocal(binding) -> mkStmt(SLocal(binding = rewriteBinding(binding, kind, st)), s.span)
    case SAssign(target, op, value) -> mkStmt(
      SAssign(
        target = rewriteExpr(target, kind, st),
        op = op,
        value = rewriteExpr(value, kind, st)
      ),
      s.span
    )
    case SReturn(valOpt) -> {
      val newVal: Option[Expr] = match valOpt { case Some(e) -> Some(value = rewriteExpr(e, kind, st)); case None -> None }
      mkStmt(SReturn(value = newVal), s.span)
    }
    case SBreak(_) -> s
    case SContinue(_) -> s
    case SThrow(ex) -> mkStmt(SThrow(expr = rewriteExpr(ex, kind, st)), s.span)
    case STry(body, catches, finallyOpt) -> {
      // #7170: the body, every catch handler, and the finally block are all
      // inside the try's protected region for V0012's purposes — mirror
      // `modechecker_check.l`'s `walkStmtForAwaitInTry` STry case exactly.
      val tryChildSt = stateInTry(st)
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        newCatches.add(rewriteCatch(catches[i], kind, tryChildSt))
        i = i + 1
      }
      val newFinally: Option[Block] = match finallyOpt {
        case Some(fb) -> Some(value = rewriteBlock(fb, kind, tryChildSt))
        case None -> None
      }
      mkStmt(STry(body = rewriteBlock(body, kind, tryChildSt), catches = newCatches, finally_ = newFinally), s.span)
    }
    case SDefer(body) -> mkStmt(SDefer(body = rewriteBlock(body, kind, st)), s.span)
    case SScope(binding, body) -> mkStmt(SScope(binding = binding, body = rewriteBlock(body, kind, st)), s.span)
    case SFor(label, pat, iter, body) -> {
      // #7199: the loop pattern's bound name(s) are in scope for `body`.
      val newIter = rewriteExpr(iter, kind, st)
      collectPatternBoundNames(pat, st.localNames)
      mkStmt(SFor(label = label, pat = pat, iter = newIter, body = rewriteBlock(body, kind, st)), s.span)
    }
    case SWhile(label, cond, body) -> mkStmt(
      SWhile(
        label = label,
        cond = rewriteExpr(cond, kind, st),
        body = rewriteBlock(body, kind, st)
      ),
      s.span
    )
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
      // #7170: (re-)enter a fresh async/try context for this function, so
      // `implicitAwaitScrutinee` sees THIS function's own `isAsync` — not
      // an enclosing one's — and starts outside any try region regardless
      // of where this function is itself nested (a statement-level `SItem`
      // function declared inside an outer try body runs in its own frame,
      // not the outer function's protected region).
      val fnSt = stateForFn(st, fn.name, fn.isAsync, fn.params)
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
        body = Some(value = rewriteFunctionBody(body, kind, fnSt)),
        span = fn.span
      )
    }
  }
}

func rewriteEntry(ed: in EntryDecl, st: in PropState): EntryDecl {
  val kind = monadOfRet(ed.ret, st.aliases)
  // Entry points cannot be declared `async` (no `isAsync` field on
  // `EntryDecl`), so this always starts a non-async context.
  val fnSt = stateForFn(st, ed.name, false, ed.params)
  EntryDecl(
    docComments = ed.docComments,
    annotations = ed.annotations,
    visibility = ed.visibility,
    name = ed.name,
    params = ed.params,
    ret = ed.ret,
    contracts = ed.contracts,
    body = rewriteFunctionBody(ed.body, kind, fnSt),
    span = ed.span
  )
}

func rewriteItem(it: in Item, st: in PropState): Item {
  val newKind: ItemKind = match it.kind {
    case IFunc(fn) -> IFunc(decl = rewriteFunction(fn, st))

    case IImpl(decl) -> {
      // #7197: build this impl's own sibling map before rewriting its
      // members, mirroring `rewriteRecordDecl` — a bare call inside one
      // impl method can resolve to a sibling impl method the same way it
      // resolves to a sibling record method.
      val siblingAnyName: Map[String, Bool] = newMap()
      val siblingSyncArity: Map[String, Bool] = newMap()
      var si = 0
      while si < decl.members.count {
        match decl.members[si] {
          case IMplFunc(fn) -> addSiblingFn(siblingAnyName, siblingSyncArity, fn)
          case _ -> ()
        }
        si = si + 1
      }
      val memberSt = stateForContainerMembers(st, siblingAnyName, siblingSyncArity)

      val newMembers: List[ImplMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMplFunc(fn) -> newMembers.add(IMplFunc(fn = rewriteFunction(fn, memberSt)))
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
      // #7197: same sibling-map treatment for an interface's own default
      // methods (a bare call inside one DIM body can resolve to a sibling
      // default method).
      val siblingAnyName: Map[String, Bool] = newMap()
      val siblingSyncArity: Map[String, Bool] = newMap()
      var si = 0
      while si < decl.members.count {
        match decl.members[si] {
          case IMFunc(fn) -> addSiblingFn(siblingAnyName, siblingSyncArity, fn)
          case _ -> ()
        }
        si = si + 1
      }
      val memberSt = stateForContainerMembers(st, siblingAnyName, siblingSyncArity)

      val newMembers: List[InterfaceMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMFunc(fn) -> newMembers.add(IMFunc(fn = rewriteFunction(fn, memberSt)))
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
    // records (`Lyric.HoistEngine.hzRewriteRecord`).
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

// #7197: records a member function's `(name, arity)` into both sibling
// maps — `anyName` unconditionally (bare-call shadowing is arity-agnostic,
// mirroring `msil/codegen.l`'s `fctx.className + "/" + funcName` check),
// `syncArity` only when the member is not itself `async`.
// A bare call site never spells out `self` (`helper(n)`, not
// `helper(self, n)`), but `parseRecordMembers`'s `injectSelfIfNeeded`
// unconditionally prepends a synthetic `self: TSelf` param to every record
// method (`RMFunc`) — impl (`IMplFunc`) and interface (`IMFunc`) methods
// are NOT injected (see `injectSelfIfNeeded`'s own call sites and
// `parseImplMemberOpt`'s doc comment on why not). The injected param is
// always literally named `"self"` (`injectSelfIfNeeded` also short-circuits
// when the user already wrote one), so it is reliably detectable and must
// be excluded from the arity used to key a bare call's argument count.
func declaredArity(fn: in FunctionDecl): Int {
  if fn.params.count > 0 and fn.params[0].name == "self" {
    fn.params.count - 1
  } else {
    fn.params.count
  }
}

func addSiblingFn(anyName: in Map[String, Bool], syncArity: in Map[String, Bool], fn: in FunctionDecl): Unit {
  if not anyName.containsKey(fn.name) {
    anyName.add(fn.name, true)
  }
  val arityKey = syncFuncArityKey(fn.name, declaredArity(fn))
  if not fn.isAsync and not syncArity.containsKey(arityKey) {
    syncArity.add(arityKey, true)
  }
}

func rewriteRecordDecl(decl: in RecordDecl, st: in PropState): RecordDecl {
  val siblingAnyName: Map[String, Bool] = newMap()
  val siblingSyncArity: Map[String, Bool] = newMap()
  var si = 0
  while si < decl.members.count {
    match decl.members[si] {
      case RMFunc(fn) -> addSiblingFn(siblingAnyName, siblingSyncArity, fn)
      case _ -> ()
    }
    si = si + 1
  }
  val memberSt = stateForContainerMembers(st, siblingAnyName, siblingSyncArity)

  val newMembers: List[RecordMember] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMFunc(fn) -> newMembers.add(RMFunc(fn = rewriteFunction(fn, memberSt)))
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
// #7198: `awaitInTryIsHazard` — whether F0045's guard should fire at all on
// this target.  See `docs/decisions/D-progress-0941-...md`'s scope note and
// `Lyric.Pipeline.MiddleEndOptions.awaitInTryIsHazard`'s doc: the hazard
// (a suspend/resume sequence physically inside a try/catch/finally
// protected region) is MSIL/.NET-specific — JVM's `async func` lowering is
// a synchronous stub with no suspend point, so firing F0045 there would be
// a spurious, target-incorrect build failure for code that already
// compiled and ran correctly on `--target jvm`.
pub func lowerPropagateFile(file: in SourceFile, awaitInTryIsHazard: Bool): PropagateResult {
  // #6448: hoist every qualifying `?` (operand-position, stacked-context)
  // into fresh `val` bindings FIRST, before the `?` -> match rewrite below —
  // see §2b's module doc.  Every hoisted `?` lands as a statement-level
  // initializer, the shape the rewrite below already turns into safely
  // compiling IL on both targets.  A no-op (returns `file` unchanged) when
  // nothing in the file qualifies.
  val hoisted = hoistPropagateFile(file)
  val diags: List[Diagnostic] = newList()
  val aliases: Map[String, TypeExpr] = newMap()
  val syncFuncNames: Map[String, Bool] = newMap()
  var ai = 0
  while ai < hoisted.items.count {
    match hoisted.items[ai].kind {
      case ITypeAlias(decl) -> {
        if not aliases.containsKey(decl.name) {
          aliases.add(decl.name, decl.rhs)
        }
      }
      case IFunc(decl) -> {
        val arityKey = syncFuncArityKey(decl.name, decl.params.count)
        if not decl.isAsync and not syncFuncNames.containsKey(arityKey) {
          syncFuncNames.add(arityKey, true)
        }
      }
      case _ -> ()
    }
    ai = ai + 1
  }
  val st = newPropState(diags, aliases, syncFuncNames, awaitInTryIsHazard)
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
