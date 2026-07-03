//! msil_await_expr_forms_self_test.l — regression coverage for the seven
//! match arms added to `collectAwaitTypesExprPB` (Phase A await-type
//! pre-count) and mirrored in `exprContainsAwaitMsil` (Phase B spill
//! decision) for `ETuple`/`EList`/`EIndex`/`ETypeApp`/`EInterpolated`/
//! `ERange`/`EAssign` (#4276).
//!
//! Before these arms existed, an `await` nested inside one of these forms
//! fell into the catch-all `case _ -> {}` and was silently skipped by
//! Phase A's pre-count, while the real lowering (`lowerExprMsil`, the
//! single recursive dispatcher used for every expression kind) still
//! descended into the same sub-expression and emitted the suspend/resume
//! protocol via `emitPhaseBAwait`.  That function's `N >= pbc.resumeLabels.count`
//! guard (codegen.l, `emitPhaseBAwait`) means an undercount does not
//! silently miscompile — it makes the self-hosted compiler itself `panic`
//! with "await index N exceeds pre-allocated resume labels" during
//! `lyric build`/`lyric test`. So a regression here is loud (a build
//! failure), not a silent wrong value; that changes the risk profile for
//! this test versus a typical silent-miscompile scenario.
//!
//! Traversal-order verification (done by hand against the current
//! `codegen.l`, not assumed): for each arm below, Phase A's recursion
//! order into sub-expressions was checked against the ACTUAL lowering
//! order in the same file:
//!   - ETuple / EList: both Phase A and `lowerExprMsil`'s `ETuple`/`EList`
//!     cases iterate `exprs[i]` for `i = 0 .. count` in the same order.
//!   - EIndex: both visit `recv` then `indices[0]`.
//!   - EInterpolated: both iterate `segments[i]` in the same order
//!     (`lowerInterpolatedMsil`).
//!   - ERange: only reachable via a `for`-loop iterator (`ERange` as a
//!     first-class value panics on `--target dotnet`, #1478); Phase A's
//!     `SFor` case visits the range (`lo` then `hi`, matching
//!     `emitCountingForMsil`'s evaluation order) before the loop body,
//!     exactly mirroring `lowerForMsil`.
//!
//! TWO OF THE SEVEN ARMS ARE UNREACHABLE FROM SURFACE SYNTAX (verified by
//! reading the parser directly, not inferred) and so cannot be exercised by
//! a black-box compile-and-run test at all:
//!   - ETypeApp: Lyric's surface syntax parses `f[T](args)` as `EIndex`
//!     followed by `ECall`, not as `ETypeApp` — stated explicitly in
//!     `lyric-compiler/lyric/mono_self_test.l`'s header comment, which
//!     constructs `ETypeApp` nodes synthetically via direct AST splicing
//!     to test `Lyric.Mono`. No parser production path builds `ETypeApp`.
//!   - EAssign: `lyric-compiler/lyric/parser/parser_exprs.l`'s
//!     `parseExprStatement` (the ONLY place in the parser that recognises
//!     `=`/`+=`/`-=`/`*=`/`/=`/`%=`) always constructs `SAssign` — a
//!     `Statement`, not an `Expr`. Assignment is never parsed as a
//!     sub-expression (there is no expression-position `=` in the
//!     grammar), so no `.l` program can produce an `EAssign` node feeding
//!     into `collectAwaitTypesExprPB`. (The statement-level counterpart,
//!     `SAssign`, is a distinct, pre-existing arm of
//!     `collectAwaitTypesStmtPB` — unrelated to this issue — already
//!     covered by `async_sm_self_test.l`'s "#2367: SAssign: await on RHS
//!     of var reassignment" test.)
//!   Both arms exist defensively: every AST-rewriting pass in this repo
//!   (`Lyric.Mono`, `Lyric.Weaver`, `Lyric.ContractElaborator`, the alias
//!   rewriter, `propagate.l`) that touches `Expr` trees matches `ETypeApp`
//!   and `EAssign` exhaustively for when a synthetic AST reuses those Expr
//!   shapes, and `collectAwaitTypesExprPB`/`exprContainsAwaitMsil` mirror
//!   that same exhaustiveness so a future front-end or middle-end change
//!   that starts producing either node ahead of async codegen doesn't
//!   silently regress back to the catch-all. Neither currently runs ahead
//!   of `--target dotnet` async lowering for ordinary user code, so there
//!   is nothing to compile-and-run here; splicing a synthetic AST directly
//!   (`Lyric.Mono`'s own testing style) is the only way to exercise them,
//!   and that requires importing `Msil.Codegen`'s internals plus a hand-
//!   built `FuncCtx`/`CodegenCtx`, which is a materially larger, riskier
//!   undertaking than this file's black-box tests and is not attempted
//!   here.
//!
//! Syntax for each of the five reachable forms below was smoke-tested
//! against the published `lyric` NuGet tool (an older, non-self-hosted
//! build) before landing here, to confirm both parse-validity and the
//! expected runtime value — see #4276 discussion. `Msil.Codegen`'s
//! specific traversal-order fix is self-hosted-only, so this file
//! exercises it through ordinary front-end `async func`/`await` surface
//! syntax (imports only `Std.*`), the same way
//! `lyric-compiler/lyric/async_sm_self_test.l` does, rather than by
//! importing `Msil.Codegen` directly.
//!
//! Wired into CI via the "MSIL await-expr-forms self-test" step in
//! `.github/workflows/ci.yml` (#4812), alongside the other native
//! `lyric test` self-tests in the same barrier group.
@test_module
package Msil.AwaitExprFormsSelfTest

import Std.Core
import Std.Console
import Std.Testing

async func asyncAddOne(n: in Int): Int {
  n + 1
}

async func asyncGreeting(): String {
  "World"
}

async func asyncIndex(): Int {
  1
}

async func asyncBound(): Int {
  3
}

// ── ETuple: await nested inside a tuple literal ─────────────────────────────
test "ETuple: await inside a tuple literal element" {
  val t = (1, await asyncAddOne(2))
  val (a, b) = t
  assertEqualInt(a, 1, "first tuple element is the literal 1")
  assertEqualInt(b, 3, "second tuple element is asyncAddOne(2) = 3")
}

// ── EList: await nested inside a list literal ───────────────────────────────
test "EList: await inside list literal elements" {
  val xs = [await asyncAddOne(10), await asyncAddOne(20)]
  assertEqualInt(xs[0], 11, "first list element is asyncAddOne(10) = 11")
  assertEqualInt(xs[1], 21, "second list element is asyncAddOne(20) = 21")
}

// ── EIndex: await nested inside an index expression ─────────────────────────
test "EIndex: await inside the index sub-expression" {
  val xs = [100, 200, 300]
  val v = xs[await asyncIndex()]
  assertEqualInt(v, 200, "xs[await asyncIndex()] = xs[1] = 200")
}

// ── EInterpolated: await nested inside a string interpolation hole ──────────
test "EInterpolated: await inside an interpolation hole" {
  val s = "Hello, ${await asyncGreeting()}!"
  assertEqual(s, "Hello, World!", "interpolation hole evaluates the awaited greeting")
}

// ── ERange: await nested inside a for-loop range bound ──────────────────────
test "ERange: await inside a for-loop's upper bound" {
  var total = 0
  for i in 0 ..= (await asyncBound()) {
    total = total + i
  }
  assertEqualInt(total, 6, "sum of 0..=3 = 0+1+2+3 = 6")
}
