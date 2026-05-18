// verifier_self_test.l — exercises the self-hosted Lyric.Verifier library.
// Compiled and executed by SelfHostedVerifierTests.fs.
// Exit 0 + "ok" in stdout means all checks held.
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
    conclusion  = trueT(),
    symbols     = syms,
    origin      = zeroSpan(),
    kind        = GKAssertion,
    label       = "test-true")
}

func makeGoalHypMatch(p: in Term): Goal {
  val hyps: List[Term] = newList()
  hyps.add(p)
  val syms: List[SymbolDecl] = newList()
  Goal(
    hypotheses = hyps,
    conclusion  = p,
    symbols     = syms,
    origin      = zeroSpan(),
    kind        = GKAssertion,
    label       = "test-hyp")
}

func makeGoalFalseConclusion(): Goal {
  val hyps: List[Term] = newList()
  val syms: List[SymbolDecl] = newList()
  Goal(
    hypotheses = hyps,
    conclusion  = falseT(),
    symbols     = syms,
    origin      = zeroSpan(),
    kind        = GKAssertion,
    label       = "test-false")
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
    case Some(Discharged) -> {}
    case _ -> { assertTrue(false, "trivial-true: expected Discharged") }
  }
}

func testTrivialDischargeHyp(): Unit {
  val p = TVar(name = "p", sort = SBool)
  val g = makeGoalHypMatch(p)
  match trivialDischarge(g) {
    case Some(Discharged) -> {}
    case _ -> { assertTrue(false, "trivial-hyp: expected Discharged") }
  }
}

func testTrivialDiscargeFalseNone(): Unit {
  val g = makeGoalFalseConclusion()
  match trivialDischarge(g) {
    case None -> {}
    case Some(_) -> { assertTrue(false, "trivial-false: expected None") }
  }
}

func testTrivialDischargeReflexiveEq(): Unit {
  val x = TVar(name = "x", sort = SInt)
  val eq = TBuiltin(op = BOpEq, args = termList2(x, x))
  val hyps: List[Term] = newList()
  val syms: List[SymbolDecl] = newList()
  val g = Goal(
    hypotheses = hyps,
    conclusion  = eq,
    symbols     = syms,
    origin      = zeroSpan(),
    kind        = GKAssertion,
    label       = "refl-eq")
  match trivialDischarge(g) {
    case Some(Discharged) -> {}
    case _ -> { assertTrue(false, "trivial-refl-eq: expected Discharged") }
  }
}

func testTrivialDischargeImpliesSelf(): Unit {
  val p = TVar(name = "p", sort = SBool)
  val imp = TBuiltin(op = BOpImplies, args = termList2(p, p))
  val hyps: List[Term] = newList()
  val syms: List[SymbolDecl] = newList()
  val g = Goal(
    hypotheses = hyps,
    conclusion  = imp,
    symbols     = syms,
    origin      = zeroSpan(),
    kind        = GKAssertion,
    label       = "implies-self")
  match trivialDischarge(g) {
    case Some(Discharged) -> {}
    case _ -> { assertTrue(false, "trivial-implies-self: expected Discharged") }
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
    case VLRuntimeChecked -> {}
    case _ -> { assertTrue(false, "prove-rc: expected VLRuntimeChecked") }
  }
  assertEqualInt(summaryTotalCount(summary), 0, "prove-rc: no goals")
  assertTrue(not summaryHasFailure(summary), "prove-rc: no failure")
  assertTrue(not summaryHasErrorDiag(summary), "prove-rc: no error diags")
}

func testProveExplicitRuntimeChecked(): Unit {
  val src = "@runtime_checked\npackage P\nfunc g(): Bool { true }\n"
  val summary = prove(src)
  match summary.level {
    case VLRuntimeChecked -> {}
    case _ -> { assertTrue(false, "prove-explicit-rc: expected VLRuntimeChecked") }
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
    conclusion  = gteRefl,
    symbols     = syms,
    origin      = zeroSpan(),
    kind        = GKAssertion,
    label       = "gte-refl")
  match trivialDischarge(g) {
    case Some(Discharged) -> {}
    case _ -> { assertTrue(false, "trivial-gte-refl: expected Discharged") }
  }
}

func testProveProofRequiredNoContracts(): Unit {
  // A @proof_required function with a loop invariant generates VCs that
  // the trivial discharger closes (establish: 0 >= 0; preserve: i+1 >= 0
  // under i >= 0 ∧ i < 3).
  val src = "@proof_required\npackage P\nfunc f(): Int {\n  var i = 0\n  while i < 3\n    invariant: i >= 0\n  {\n    i = i + 1\n  }\n  i\n}\n"
  val summary = prove(src)
  match summary.level {
    case VLProofRequired -> {}
    case _ -> { assertTrue(false, "prove-pr-no-contracts: expected VLProofRequired") }
  }
  assertTrue(not summaryHasErrorDiag(summary), "prove-pr-no-contracts: no error diags")
}

func testProveParseError(): Unit {
  val src = "package P\nfunc broken(: Int { 0 }\n"
  val summary = prove(src)
  assertTrue(summaryHasErrorDiag(summary), "prove-parse-error: has error diag")
  assertEqualInt(summaryTotalCount(summary), 0, "prove-parse-error: no goals")
}

func testSummaryHelpers(): Unit {
  // Build a ProofSummary manually to test helpers.
  val hyps: List[Term] = newList()
  val syms: List[SymbolDecl] = newList()
  val g = Goal(
    hypotheses = hyps,
    conclusion  = trueT(),
    symbols     = syms,
    origin      = zeroSpan(),
    kind        = GKAssertion,
    label       = "test")
  val r1 = ProofResult(goal = g, outcome = Discharged)
  val r2 = ProofResult(goal = g, outcome = Unknown(reason = "no solver"))
  val results: List[ProofResult] = newList()
  results.add(r1)
  results.add(r2)
  val diags: List[Diagnostic] = newList()
  val summary = ProofSummary(
    level       = VLProofRequired,
    diagnostics = diags,
    results     = results)
  assertEqualInt(summaryTotalCount(summary), 2, "summary-total-2")
  assertEqualInt(summaryDischargedCount(summary), 1, "summary-discharged-1")
  assertTrue(summaryHasFailure(summary), "summary-has-failure")
  assertTrue(not summaryHasCounterexample(summary), "summary-no-counterexample")
  assertTrue(not summaryHasErrorDiag(summary), "summary-no-error-diag")
}

// ─────────────────────────────────────────────────────────────────────────────
// Main.
// ─────────────────────────────────────────────────────────────────────────────

func main(): Unit {
  testSmtSortBool()
  testSmtSortInt()
  testSmtSortFloat32()
  testSmtSortString()
  testSmtSortBitVec()
  testSmtSortDatatype()
  testSmtSortSlice()

  testSmtSanitizeAlpha()
  testSmtSanitizeWithDot()
  testSmtSanitizeSpecial()

  testSmtTermBoolTrue()
  testSmtTermBoolFalse()
  testSmtTermVar()
  testSmtTermIntLit()
  testSmtTermNegIntLit()
  testSmtTermAdd()
  testSmtTermNot()
  testSmtTermIte()

  testSmtGoalContainsPreamble()

  testTermEqSame()
  testTermEqDiff()
  testTermEqLit()
  testTermEqLitDiff()

  testSubstTermTForallCapture()
  testSubstTermTExistsCapture()
  testSubstTermNoCapture()

  testTrivialDischargeTrue()
  testTrivialDischargeHyp()
  testTrivialDiscargeFalseNone()
  testTrivialDischargeReflexiveEq()
  testTrivialDischargeImpliesSelf()
  testTrivialDischargeGteRefl()

  testParseModelEmpty()
  testParseModelOneDef()

  testProveRuntimeCheckedNoGoals()
  testProveExplicitRuntimeChecked()
  testProveProofRequiredNoContracts()
  testProveParseError()
  testSummaryHelpers()

  println("verifier self-test: ok")
}
