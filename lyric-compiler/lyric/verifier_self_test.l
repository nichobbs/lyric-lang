//! verifier_self_test.l — exercises the self-hosted Lyric.Verifier library.
//!
//! Run via `lyric test lyric-compiler/lyric/verifier_self_test.l`.
//! Replaces the F# SelfHostedVerifierTests.fs wrapper (#2580).
@test_module
package Lyric.VerifierSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.Verifier

// ─────────────────────────────────────────────────────────────────────────────
// Helpers.
// ─────────────────────────────────────────────────────────────────────────────
func zeroSpan(): Span {
  makeSpan(initialPosition(), initialPosition())
}

func makeGoalTrue(): Goal {
  val hyps: List[Term] = newList()
  val syms: List[SymbolDecl] = newList()
  Goal(
    hypotheses = hyps,
    conclusion = trueT(),
    symbols = syms,
    origin = zeroSpan(),
    kind = GKAssertion,
    label = "test-true"
  )
}

func makeGoalHypMatch(p: in Term): Goal {
  val hyps: List[Term] = newList()
  hyps.add(p)
  val syms: List[SymbolDecl] = newList()
  Goal(hypotheses = hyps, conclusion = p, symbols = syms, origin = zeroSpan(), kind = GKAssertion, label = "test-hyp")
}

func makeGoalFalseConclusion(): Goal {
  val hyps: List[Term] = newList()
  val syms: List[SymbolDecl] = newList()
  Goal(
    hypotheses = hyps,
    conclusion = falseT(),
    symbols = syms,
    origin = zeroSpan(),
    kind = GKAssertion,
    label = "test-false"
  )
}

func prove(src: in String): ProofSummary {
  proveSource(src)
}

// ─────────────────────────────────────────────────────────────────────────────
// §1. SMT sort rendering.
// ─────────────────────────────────────────────────────────────────────────────
func testSmtSortBool(): Unit {
  assertEqual(smtRenderSort(SBool), "Bool", "sort-bool")
}

func testSmtSortInt(): Unit {
  assertEqual(smtRenderSort(SInt), "Int", "sort-int")
}

func testSmtSortFloat32(): Unit {
  assertEqual(smtRenderSort(SFloat32), "Real", "sort-float32-as-real")
}

func testSmtSortString(): Unit {
  assertEqual(smtRenderSort(SString), "String", "sort-string")
}

func testSmtSortBitVec(): Unit {
  assertEqual(smtRenderSort(SBitVec(width = 32)), "(_ BitVec 32)", "sort-bv32")
}

func testSmtSortDatatype(): Unit {
  val args: List[Sort] = newList()
  assertEqual(smtRenderSort(SDatatype(name = "MyType", args = args)), "MyType", "sort-datatype-no-args")
}

func testSmtSortSlice(): Unit {
  assertEqual(smtRenderSort(SSlice(element = SInt)), "(Array Int Int)", "sort-slice-int")
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. SMT sanitize.
// ─────────────────────────────────────────────────────────────────────────────
func testSmtSanitizeAlpha(): Unit {
  assertEqual(smtSanitize("hello"), "hello", "sanitize-alpha")
}

func testSmtSanitizeWithDot(): Unit {
  assertEqual(smtSanitize("Foo.bar"), "Foo.bar", "sanitize-dot")
}

func testSmtSanitizeSpecial(): Unit {
  val result = smtSanitize("a b-c")
  // spaces and dash become underscores
  assertEqual(result, "a_b_c", "sanitize-special")
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. SMT term rendering.
// ─────────────────────────────────────────────────────────────────────────────
func testSmtTermBoolTrue(): Unit {
  val t = trueT()
  assertEqual(smtRenderTerm(t), "true", "term-true")
}

func testSmtTermBoolFalse(): Unit {
  val t = falseT()
  assertEqual(smtRenderTerm(t), "false", "term-false")
}

func testSmtTermVar(): Unit {
  val t = TVar(name = "x", sort = SInt)
  assertEqual(smtRenderTerm(t), "x", "term-var")
}

func testSmtTermIntLit(): Unit {
  val t = TLit(value = VLInt(n = 42i64), sort = SInt)
  assertEqual(smtRenderTerm(t), "42", "term-lit-42")
}

func testSmtTermNegIntLit(): Unit {
  val t = TLit(value = VLInt(n = -5i64), sort = SInt)
  assertEqual(smtRenderTerm(t), "(- 5)", "term-lit-neg5")
}

func testSmtTermAdd(): Unit {
  val x = TVar(name = "x", sort = SInt)
  val y = TVar(name = "y", sort = SInt)
  val t = TBuiltin(op = BOpAdd, args = termList2(x, y))
  assertEqual(smtRenderTerm(t), "(+ x y)", "term-add")
}

func testSmtTermNot(): Unit {
  val p = TVar(name = "p", sort = SBool)
  val t = TBuiltin(op = BOpNot, args = termList1(p))
  assertEqual(smtRenderTerm(t), "(not p)", "term-not")
}

func testSmtTermIte(): Unit {
  val c = TVar(name = "c", sort = SBool)
  val a = TLit(value = VLInt(n = 1i64), sort = SInt)
  val b = TLit(value = VLInt(n = 0i64), sort = SInt)
  val t = TIte(cond = c, thenT = a, elseT = b)
  assertEqual(smtRenderTerm(t), "(ite c 1 0)", "term-ite")
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. SMT goal rendering includes preamble and assert.
// ─────────────────────────────────────────────────────────────────────────────
func testSmtGoalContainsPreamble(): Unit {
  val g = makeGoalTrue()
  val rendered = smtRenderGoal(g)
  assertTrue(rendered.contains("(set-logic ALL)"), "goal-has-set-logic")
  assertTrue(rendered.contains("(check-sat)"), "goal-has-check-sat")
  assertTrue(rendered.contains("(assert"), "goal-has-assert")
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Term structural equality.
// ─────────────────────────────────────────────────────────────────────────────
func testTermEqSame(): Unit {
  val t1 = TVar(name = "x", sort = SInt)
  val t2 = TVar(name = "x", sort = SInt)
  assertTrue(termEq(t1, t2), "term-eq-same-var")
}

func testTermEqDiff(): Unit {
  val t1 = TVar(name = "x", sort = SInt)
  val t2 = TVar(name = "y", sort = SInt)
  assertTrue(not termEq(t1, t2), "term-eq-diff-var")
}

func testTermEqLit(): Unit {
  val t1 = trueT()
  val t2 = trueT()
  assertTrue(termEq(t1, t2), "term-eq-true-true")
}

func testTermEqLitDiff(): Unit {
  assertTrue(not termEq(trueT(), falseT()), "term-eq-true-false")
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. substTerm capture-avoiding substitution.
//
// Regression tests for the soundness fix in PR #448/#456:
//   subst {x -> y} (forall y. x > y)  must NOT produce forall y. y > y
//   (which is UNSOUND — y was captured).  Correct result: forall y$1. y > y$1.
// ─────────────────────────────────────────────────────────────────────────────
func testSubstTermTForallCapture(): Unit {
  // env = { x -> y }; subst into (forall y. x > y) — y must be alpha-renamed.
  val env: Map[String, Term] = newMap()
  env.add("x", TVar(name = "y", sort = SInt))
  val envNames: List[String] = newList()
  envNames.add("x")
  val binderY = SortBinder(name = "y", sort = SInt)
  val bs: List[SortBinder] = newList()
  bs.add(binderY)
  val trigs: List[List[Term]] = newList()
  val body = TBuiltin(op = BOpGt, args = termList2(TVar(name = "x", sort = SInt), TVar(name = "y", sort = SInt)))
  val forallXY = TForall(binders = bs, triggers = trigs, body = body)
  val result = substTerm(env, envNames, forallXY)
  val rendered = smtRenderTerm(result)
  // The binder "y" must be renamed to avoid capturing the substituted "y".
  // smtSanitize turns "$" into "_", so the freshened form "y$1" renders as "y_1".
  assertTrue(not rendered.contains("(forall ((y Int)) (> y y))"), "TForall: no capture")
  assertTrue(rendered.contains("forall"), "TForall: still a forall")
  assertTrue(rendered.contains("y_1"), "TForall: binder freshened")
}

func testSubstTermTExistsCapture(): Unit {
  // env = { x -> y }; subst into (exists y. x < y) — y must be alpha-renamed.
  val env: Map[String, Term] = newMap()
  env.add("x", TVar(name = "y", sort = SInt))
  val envNames: List[String] = newList()
  envNames.add("x")
  val binderY = SortBinder(name = "y", sort = SInt)
  val bs: List[SortBinder] = newList()
  bs.add(binderY)
  val body = TBuiltin(op = BOpLt, args = termList2(TVar(name = "x", sort = SInt), TVar(name = "y", sort = SInt)))
  val existsXY = TExists(binders = bs, body = body)
  val result = substTerm(env, envNames, existsXY)
  val rendered = smtRenderTerm(result)
  assertTrue(not rendered.contains("(exists ((y Int)) (< y y))"), "TExists: no capture")
  assertTrue(rendered.contains("exists"), "TExists: still an exists")
  // smtSanitize turns "$" into "_", so "y$1" renders as "y_1".
  assertTrue(rendered.contains("y_1"), "TExists: binder freshened")
}

func testSubstTermNoCapture(): Unit {
  // subst {x -> z} (forall y. x > y) — no capture; binder should NOT be renamed.
  val env: Map[String, Term] = newMap()
  env.add("x", TVar(name = "z", sort = SInt))
  val envNames: List[String] = newList()
  envNames.add("x")
  val binderY = SortBinder(name = "y", sort = SInt)
  val bs: List[SortBinder] = newList()
  bs.add(binderY)
  val trigs: List[List[Term]] = newList()
  val body = TBuiltin(op = BOpGt, args = termList2(TVar(name = "x", sort = SInt), TVar(name = "y", sort = SInt)))
  val forallXY = TForall(binders = bs, triggers = trigs, body = body)
  val result = substTerm(env, envNames, forallXY)
  val rendered = smtRenderTerm(result)
  // Substitution does not capture "y"; binder stays "y".
  assertEqual(rendered, "(forall ((y Int)) (> z y))", "TForall: no rename needed")
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Trivial discharger.
// ─────────────────────────────────────────────────────────────────────────────
func testTrivialDischargeTrue(): Unit {
  val g = makeGoalTrue()
  match trivialDischarge(g) {
    case Some(Discharged) -> {
    }
    case _ -> {
      assertTrue(false, "trivial-true: expected Discharged")
    }
  }
}

func testTrivialDischargeHyp(): Unit {
  val p = TVar(name = "p", sort = SBool)
  val g = makeGoalHypMatch(p)
  match trivialDischarge(g) {
    case Some(Discharged) -> {
    }
    case _ -> {
      assertTrue(false, "trivial-hyp: expected Discharged")
    }
  }
}

func testTrivialDiscargeFalseNone(): Unit {
  val g = makeGoalFalseConclusion()
  match trivialDischarge(g) {
    case None -> {
    }
    case Some(_) -> {
      assertTrue(false, "trivial-false: expected None")
    }
  }
}

func testTrivialDischargeReflexiveEq(): Unit {
  val x = TVar(name = "x", sort = SInt)
  val eq = TBuiltin(op = BOpEq, args = termList2(x, x))
  val hyps: List[Term] = newList()
  val syms: List[SymbolDecl] = newList()
  val g = Goal(
    hypotheses = hyps,
    conclusion = eq,
    symbols = syms,
    origin = zeroSpan(),
    kind = GKAssertion,
    label = "refl-eq"
  )
  match trivialDischarge(g) {
    case Some(Discharged) -> {
    }
    case _ -> {
      assertTrue(false, "trivial-refl-eq: expected Discharged")
    }
  }
}

func testTrivialDischargeImpliesSelf(): Unit {
  val p = TVar(name = "p", sort = SBool)
  val imp = TBuiltin(op = BOpImplies, args = termList2(p, p))
  val hyps: List[Term] = newList()
  val syms: List[SymbolDecl] = newList()
  val g = Goal(
    hypotheses = hyps,
    conclusion = imp,
    symbols = syms,
    origin = zeroSpan(),
    kind = GKAssertion,
    label = "implies-self"
  )
  match trivialDischarge(g) {
    case Some(Discharged) -> {
    }
    case _ -> {
      assertTrue(false, "trivial-implies-self: expected Discharged")
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. parseModel from solver.
// ─────────────────────────────────────────────────────────────────────────────
func testParseModelEmpty(): Unit {
  val result = parseModel("")
  assertEqualInt(result.count, 0, "parse-model-empty")
}

func testParseModelOneDef(): Unit {
  val modelText = "(model\n(define-fun x () Int\n  7)\n)"
  val result = parseModel(modelText)
  assertEqualInt(result.count, 1, "parse-model-one-def: count")
  assertEqual(result[0].name, "x", "parse-model-one-def: name")
  assertEqual(result[0].sort, "Int", "parse-model-one-def: sort")
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. proveSource — pipeline smoke tests (no SMT solver required).
// ─────────────────────────────────────────────────────────────────────────────
func testProveRuntimeCheckedNoGoals(): Unit {
  val src = "package P\nfunc f(): Int { 42 }\n"
  val summary = prove(src)
  match summary.level {
    case VLRuntimeChecked -> {
    }
    case _ -> {
      assertTrue(false, "prove-rc: expected VLRuntimeChecked")
    }
  }
  assertEqualInt(summaryTotalCount(summary), 0, "prove-rc: no goals")
  assertTrue(not summaryHasFailure(summary), "prove-rc: no failure")
  assertTrue(not summaryHasErrorDiag(summary), "prove-rc: no error diags")
}

func testProveExplicitRuntimeChecked(): Unit {
  val src = "@runtime_checked\npackage P\nfunc g(): Bool { true }\n"
  val summary = prove(src)
  match summary.level {
    case VLRuntimeChecked -> {
    }
    case _ -> {
      assertTrue(false, "prove-explicit-rc: expected VLRuntimeChecked")
    }
  }
  assertEqualInt(summaryTotalCount(summary), 0, "prove-explicit-rc: no goals")
}

func testTrivialDischargeGteRefl(): Unit {
  // Test that BOpGte with equal TLit args is tautological.
  val zero = TLit(value = VLInt(n = 0i64), sort = SInt)
  val gteRefl = TBuiltin(op = BOpGte, args = termList2(zero, zero))
  val hyps: List[Term] = newList()
  val syms: List[SymbolDecl] = newList()
  val g = Goal(
    hypotheses = hyps,
    conclusion = gteRefl,
    symbols = syms,
    origin = zeroSpan(),
    kind = GKAssertion,
    label = "gte-refl"
  )
  match trivialDischarge(g) {
    case Some(Discharged) -> {
    }
    case _ -> {
      assertTrue(false, "trivial-gte-refl: expected Discharged")
    }
  }
}

func testProveProofRequiredNoContracts(): Unit {
  // A @proof_required function with a loop invariant generates VCs that
  // the trivial discharger closes (establish: 0 >= 0; preserve: i+1 >= 0
  // under i >= 0 ∧ i < 3).
  val src = "@proof_required\npackage P\nfunc f(): Int {\n  var i = 0\n  while i < 3\n    invariant: i >= 0\n  {\n    i = i + 1\n  }\n  i\n}\n"
  val summary = prove(src)
  match summary.level {
    case VLProofRequired -> {
    }
    case _ -> {
      assertTrue(false, "prove-pr-no-contracts: expected VLProofRequired")
    }
  }
  assertTrue(not summaryHasErrorDiag(summary), "prove-pr-no-contracts: no error diags")
}

func testProveParseError(): Unit {
  val src = "package P\nfunc broken(: Int { 0 }\n"
  val summary = prove(src)
  assertTrue(summaryHasErrorDiag(summary), "prove-parse-error: has error diag")
  assertEqualInt(summaryTotalCount(summary), 0, "prove-parse-error: no goals")
}

// #336: aspect weaving runs before VC generation, so the verifier sees
// the wrapper's composed contracts and the around body that the runtime
// actually executes — V0031 is retired and the proof obligations come
// from the woven body.
func testProveAspectWeaveNoV0031(): Unit {
  // Aspect `Trivial` matches `compute` and adds a tautological
  // `ensures: true` clause to the wrapper.  Before #336 this fired
  // V0031 (and the bare body, not the wrapper, was "proven"); after
  // #336 the verifier sees the woven wrapper, no V0031 fires, and
  // the trivial discharger closes the obligations on the woven body.
  val src = "@proof_required\npackage P\n" + "aspect Trivial {\n" + "  matches: name like \"compute*\"\n" +
    "  ensures: true\n" +
    "  around(args) -> ret { proceed(args) }\n" +
    "}\n" +
    "func compute(x: in Int): Int { x }\n"
  val summary = prove(src)
  assertTrue(not summaryHasErrorDiag(summary), "aspect-weave-noV0031: no error diags")
  // V0031 must not appear — the verifier walks the woven body.
  var hasV0031 = false
  var di = 0
  while di < summary.diagnostics.count {
    if summary.diagnostics[di].code == "V0031" {
      hasV0031 = true
    }
    di = di + 1
  }
  assertTrue(not hasV0031, "aspect-weave-noV0031: V0031 retired (weaver runs pre-VCgen)")
}

// #336: with no aspect block, the verifier and weaver behave identically
// — the pre-existing prove-pr-no-contracts smoke still holds.
func testProveNoAspectStillWorks(): Unit {
  val src = "@proof_required\npackage P\nfunc f(): Int { 0 }\n"
  val summary = prove(src)
  assertTrue(not summaryHasErrorDiag(summary), "no-aspect-still-works: no error diags")
}

func testProveProtectedTypeInvariantHolds(): Unit {
  // An entry with an empty body trivially preserves the invariant:
  // WP(n>=0, {}) = n>=0, which is the requires hypothesis — discharged.
  val src = "@proof_required\npackage P\nprotected type Counter {\n  var n: Int\n  invariant: n >= 0\n  entry noop(): Unit { }\n}\n"
  val summary = prove(src)
  match summary.level {
    case VLProofRequired -> {
    }
    case _ -> {
      assertTrue(false, "prot-inv-holds: expected VLProofRequired")
    }
  }
  assertTrue(not summaryHasFailure(summary), "prot-inv-holds: no failure")
  assertTrue(not summaryHasErrorDiag(summary), "prot-inv-holds: no error diags")
}

func testProveProtectedTypeInvariantViolated(): Unit {
  // An assert after a contradicting assignment produces an unresolvable side
  // goal that the trivial discharger cannot close.
  val src = "@proof_required\npackage P\nprotected type Counter {\n  var n: Int\n  invariant: n >= 0\n  entry bad(): Unit {\n    n = 0 - 1\n    assert(n >= 0)\n  }\n}\n"
  val summary = prove(src)
  match summary.level {
    case VLProofRequired -> {
    }
    case _ -> {
      assertTrue(false, "prot-inv-violated: expected VLProofRequired")
    }
  }
  assertTrue(summaryHasFailure(summary), "prot-inv-violated: has failure")
}

func testProveProtectedFuncContractViolated(): Unit {
  // `goalsForFile`'s `IProtected` arm dispatches `PMEntry` through
  // `goalsForEntry` (which augments with invariants) and `PMFunc`
  // through `goalsForProtectedFunc` (which uses the helper's own
  // contracts unaugmented).  The existing
  // `testProveProtectedType*Invariant*` tests only exercise the
  // `PMEntry` route.  Pin the `PMFunc` route by declaring a helper
  // whose ensures clause is trivially unprovable (#664).
  val src = "@proof_required\npackage P\n" + "protected type Counter {\n" + "  var n: Int\n" + "  invariant: n >= 0\n" +
    "  func helper(): Int requires: true ensures: result < 0 { 0 }\n" +
    "}\n"
  val summary = prove(src)
  match summary.level {
    case VLProofRequired -> {
    }
    case _ -> {
      assertTrue(false, "prot-func-violated: expected VLProofRequired")
    }
  }
  assertTrue(summaryHasFailure(summary), "prot-func-violated: PMFunc with unprovable ensures has failure")
}

// `..= hi` smoke: verifier accepts the half-open AST without crashing (RBKLowerBound is parser-unreachable today; theory.l keeps it defensive).
func testProveRangeBoundUpperOnly(): Unit {
  val src = "@proof_required\npackage P\ntype Pct = Int range ..= 100\nfunc clip(x: in Pct): Int { return x }\n"
  val summary = prove(src)
  match summary.level {
    case VLProofRequired -> {
    }
    case _ -> {
      assertTrue(false, "range-upper-only: expected VLProofRequired")
    }
  }
  assertTrue(not summaryHasErrorDiag(summary), "range-upper-only: no error diags")
}

// #735/#746 sort-name smoke: two same-shape records compile through `qualifiedDatatypeName` without crash.
func testProveSortNamespacing(): Unit {
  val src = "@proof_required\npackage P\nrecord A { x: Int }\nrecord B { x: Int }\nfunc id(a: in A): A { return a }\n"
  val summary = prove(src)
  match summary.level {
    case VLProofRequired -> {
    }
    case _ -> {
      assertTrue(false, "sort-namespace: expected VLProofRequired")
    }
  }
  assertTrue(not summaryHasErrorDiag(summary), "sort-namespace: no error diags")
}

// #752: pin the collision scenario that motivated the `.` separator in
// `qualifiedDatatypeName`.  With a `_` separator, segments
// `["Pkg_A", "Foo"]` and `["Pkg", "A_Foo"]` would both render as
// "Pkg_A_Foo" — the join is now `.`-separated, so the two paths
// produce distinct sort names ("Pkg_A.Foo" vs "Pkg.A_Foo").
func testQualifiedDatatypeNameNoCollision(): Unit {
  val left: List[String] = newList()
  left.add("Pkg_A")
  left.add("Foo")
  val right: List[String] = newList()
  right.add("Pkg")
  right.add("A_Foo")
  val l = qualifiedDatatypeName(left)
  val r = qualifiedDatatypeName(right)
  assertEqual(l, "Pkg_A.Foo", "left rendered as Pkg_A.Foo")
  assertEqual(r, "Pkg.A_Foo", "right rendered as Pkg.A_Foo")
  assertTrue(l != r, "the two rendered names are distinct (no `_`-join collision)")
}

func testSummaryHelpers(): Unit {
  // Build a ProofSummary manually to test helpers.
  val hyps: List[Term] = newList()
  val syms: List[SymbolDecl] = newList()
  val g = Goal(
    hypotheses = hyps,
    conclusion = trueT(),
    symbols = syms,
    origin = zeroSpan(),
    kind = GKAssertion,
    label = "test"
  )
  val r1 = ProofResult(goal = g, outcome = Discharged)
  val r2 = ProofResult(goal = g, outcome = Unknown(reason = "no solver"))
  val results: List[ProofResult] = newList()
  results.add(r1)
  results.add(r2)
  val diags: List[Diagnostic] = newList()
  val summary = ProofSummary(level = VLProofRequired, diagnostics = diags, results = results)
  assertEqualInt(summaryTotalCount(summary), 2, "summary-total-2")
  assertEqualInt(summaryDischargedCount(summary), 1, "summary-discharged-1")
  assertTrue(summaryHasFailure(summary), "summary-has-failure")
  assertTrue(not summaryHasCounterexample(summary), "summary-no-counterexample")
  assertTrue(not summaryHasErrorDiag(summary), "summary-no-error-diag")
}

func summaryHasDiagCode(s: in ProofSummary, code: in String): Bool {
  var i = 0
  while i < s.diagnostics.count {
    if s.diagnostics[i].code == code {
      return true
    }
    i = i + 1
  }
  false
}

// #3298: a @proof_required async function carrying a contract clause must be
// rejected with V0032, not silently verified against an opaqued body.
func testProveAsyncContractRejected(): Unit {
  val src = "@proof_required\npackage P\nasync func f(x: in Int): Int requires: x > 0 ensures: result > 0 { x }\n"
  val summary = prove(src)
  assertTrue(summaryHasDiagCode(summary, "V0032"), "async-contract: V0032 emitted")
  assertTrue(summaryHasErrorDiag(summary), "async-contract: error diag present")
  // No vacuous/opaque goals are generated for the rejected function.
  assertEqualInt(summaryTotalCount(summary), 0, "async-contract: no goals")
}

// #3298: a @proof_required async function WITHOUT contracts is unaffected —
// no V0032, and it verifies normally.
func testProveAsyncNoContractAllowed(): Unit {
  val src = "@proof_required\npackage P\nasync func f(x: in Int): Int { x }\n"
  val summary = prove(src)
  assertTrue(not summaryHasDiagCode(summary, "V0032"), "async-no-contract: no V0032")
  assertTrue(not summaryHasErrorDiag(summary), "async-no-contract: no error diags")
}

// #3298 regression: a synchronous @proof_required function with contracts must
// still take the normal VC-generation path — the guard fires only for
// async/yield bodies, so no V0032 and goals are still produced.
func testProveSyncContractStillVerifies(): Unit {
  val src = "@proof_required\npackage P\nfunc f(x: in Int): Int requires: x >= 0 ensures: result >= 0 { x }\n"
  val summary = prove(src)
  assertTrue(not summaryHasDiagCode(summary, "V0032"), "sync-contract: no V0032")
  assertTrue(summaryTotalCount(summary) > 0, "sync-contract: goals generated (normal path)")
}

// #3298: a @proof_required generator (async + yield) carrying a contract is
// rejected with V0032 like any other async contract-bearer.
func testProveGeneratorContractRejected(): Unit {
  val src = "@proof_required\npackage P\nasync func gen(): Int ensures: result >= 0 {\n  yield 1\n  0\n}\n"
  val summary = prove(src)
  assertTrue(summaryHasDiagCode(summary, "V0032"), "generator-contract: V0032 emitted")
  assertTrue(summaryHasErrorDiag(summary), "generator-contract: error diag present")
}

// ─────────────────────────────────────────────────────────────────────────────
// Test items
// ─────────────────────────────────────────────────────────────────────────────
test "smt sort bool" {
  testSmtSortBool()
}

test "smt sort int" {
  testSmtSortInt()
}

test "smt sort float32" {
  testSmtSortFloat32()
}

test "smt sort string" {
  testSmtSortString()
}

test "smt sort bitvec" {
  testSmtSortBitVec()
}

test "smt sort datatype" {
  testSmtSortDatatype()
}

test "smt sort slice" {
  testSmtSortSlice()
}

test "smt sanitize alpha" {
  testSmtSanitizeAlpha()
}

test "smt sanitize with dot" {
  testSmtSanitizeWithDot()
}

test "smt sanitize special" {
  testSmtSanitizeSpecial()
}

test "smt term bool true" {
  testSmtTermBoolTrue()
}

test "smt term bool false" {
  testSmtTermBoolFalse()
}

test "smt term var" {
  testSmtTermVar()
}

test "smt term int lit" {
  testSmtTermIntLit()
}

test "smt term neg int lit" {
  testSmtTermNegIntLit()
}

test "smt term add" {
  testSmtTermAdd()
}

test "smt term not" {
  testSmtTermNot()
}

test "smt term ite" {
  testSmtTermIte()
}

test "smt goal contains preamble" {
  testSmtGoalContainsPreamble()
}

test "term eq same" {
  testTermEqSame()
}

test "term eq diff" {
  testTermEqDiff()
}

test "term eq lit" {
  testTermEqLit()
}

test "term eq lit diff" {
  testTermEqLitDiff()
}

test "subst term tforall capture" {
  testSubstTermTForallCapture()
}

test "subst term texists capture" {
  testSubstTermTExistsCapture()
}

test "subst term no capture" {
  testSubstTermNoCapture()
}

test "trivial discharge true" {
  testTrivialDischargeTrue()
}

test "trivial discharge hyp" {
  testTrivialDischargeHyp()
}

test "trivial discharge false none" {
  testTrivialDiscargeFalseNone()
}

test "trivial discharge reflexive eq" {
  testTrivialDischargeReflexiveEq()
}

test "trivial discharge implies self" {
  testTrivialDischargeImpliesSelf()
}

test "trivial discharge gte refl" {
  testTrivialDischargeGteRefl()
}

test "parse model empty" {
  testParseModelEmpty()
}

test "parse model one def" {
  testParseModelOneDef()
}

test "prove runtime checked no goals" {
  testProveRuntimeCheckedNoGoals()
}

test "prove explicit runtime checked" {
  testProveExplicitRuntimeChecked()
}

test "prove proof required no contracts" {
  testProveProofRequiredNoContracts()
}

test "prove parse error" {
  testProveParseError()
}

test "prove aspect weave no V0031" {
  testProveAspectWeaveNoV0031()
}

test "prove no aspect still works" {
  testProveNoAspectStillWorks()
}

test "prove protected type invariant holds" {
  testProveProtectedTypeInvariantHolds()
}

test "prove protected type invariant violated" {
  testProveProtectedTypeInvariantViolated()
}

test "prove protected func contract violated" {
  testProveProtectedFuncContractViolated()
}

test "prove range bound upper only" {
  testProveRangeBoundUpperOnly()
}

test "prove sort namespacing" {
  testProveSortNamespacing()
}

test "qualified datatype name no collision" {
  testQualifiedDatatypeNameNoCollision()
}

test "summary helpers" {
  testSummaryHelpers()
}

test "prove async contract rejected" {
  testProveAsyncContractRejected()
}

test "prove async no contract allowed" {
  testProveAsyncNoContractAllowed()
}

test "prove sync contract still verifies" {
  testProveSyncContractStillVerifies()
}

test "prove generator contract rejected" {
  testProveGeneratorContractRejected()
}
