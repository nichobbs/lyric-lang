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
  // #7178: same-file top-level, non-async `func` names (mirrors `aliases`'
  // same-file-declaration approach).  `implicitAwaitScrutinee` uses this as
  // an allow-list: a bare same-file call is only PROVEN safe when its name
  // is in this set.  Everything else that isn't provably safe (a call to a
  // same-file `async func`, a cross-package/qualified call, a method call,
  // or a call to a name this pass cannot resolve at all — e.g. an imported
  // function or a locally-nested `func` statement) is treated as
  // potentially hazardous rather than silently assumed safe — see
  // `isRiskyTryCallScrutinee`'s doc.
  syncFuncNames: Map[String, Bool]
  // #7170: name and `isAsync`-ness of the function currently being rewritten,
  // plus whether the rewrite point is lexically inside one of its try/
  // catch/finally regions.  See `implicitAwaitScrutinee`'s doc for why this
  // pass — not the mode checker's V0012 — has to be the one to guard against
  // an implicit `await` landing inside an async function's protected region.
  curFnName: String
  curFnAsync: Bool
  inTry: Bool
}

func newPropState(
  diags: in List[Diagnostic], aliases: in Map[String, TypeExpr], syncFuncNames: in Map[String, Bool]
): PropState {
  PropState(
    counter = newList(),
    diagnostics = diags,
    aliases = aliases,
    syncFuncNames = syncFuncNames,
    curFnName = "",
    curFnAsync = false,
    inTry = false
  )
}

// Re-scope `st` to a newly-entered function body: fresh async/try context,
// same threaded `counter`/`diagnostics`/`aliases`/`syncFuncNames` (all
// reference types, so mutations through the clone stay visible to the
// caller — the same idiom `st.counter`/`st.diagnostics` already rely on).
func stateForFn(st: in PropState, name: in String, isAsync: Bool): PropState {
  PropState(
    counter = st.counter,
    diagnostics = st.diagnostics,
    aliases = st.aliases,
    syncFuncNames = st.syncFuncNames,
    curFnName = name,
    curFnAsync = isAsync,
    inTry = false
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
    curFnName = st.curFnName,
    curFnAsync = st.curFnAsync,
    inTry = true
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
    curFnName = st.curFnName,
    curFnAsync = st.curFnAsync,
    inTry = false
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
  } else if st.curFnAsync and st.inTry and isRiskyTryCallScrutinee(inner, st) {
    st.diagnostics.add(
      errorDiagnostic(
        "F0045",
        "the `?` operator's implicit `await` of this call inside a try/catch/finally in async function '" + st.curFnName +
          "' cannot be proven safe here (only a direct call to a same-file, non-async function is) and, if the " +
          "call is actually async, would emit invalid IL (the CLR verifier rejects a suspend/resume sequence " +
          "inside a protected region — see V0012); await the call explicitly before or after the try block instead",
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
    case ECall(fn, _) -> {
      match fn.kind {
        case EPath(path) -> {
          if path.segments.count == 1 {
            val name = path.segments[0]
            not (st.syncFuncNames.containsKey(name) or isBuiltinMonadCtorName(name))
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
    case SFor(label, pat, iter, body) -> mkStmt(
      SFor(
        label = label,
        pat = pat,
        iter = rewriteExpr(iter, kind, st),
        body = rewriteBlock(body, kind, st)
      ),
      s.span
    )
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
      val fnSt = stateForFn(st, fn.name, fn.isAsync)
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
  val fnSt = stateForFn(st, ed.name, false)
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
        if not decl.isAsync and not syncFuncNames.containsKey(decl.name) {
          syncFuncNames.add(decl.name, true)
        }
      }
      case _ -> ()
    }
    ai = ai + 1
  }
  val st = newPropState(diags, aliases, syncFuncNames)
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
