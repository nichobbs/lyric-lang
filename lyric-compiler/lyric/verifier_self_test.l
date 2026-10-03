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

// #4848: a `val` binding annotated with an inline range refinement now
// carries a range hypothesis into the WP goal (vcgen.l LBVal case). `x` is
// constrained in-range by `requires:` (an inline refinement is transparent
// for type equivalence — docs/01 §2.2 — so assigning `x` to `p` inserts no
// runtime/proof check of its own; the `requires:` is what makes the
// assignment sound), but WITHOUT `p`'s own range hypothesis flowing into the
// WP goal, the postcondition `result <= 100` doesn't obviously follow from
// `p`'s otherwise-unconstrained `Int` slot — the point of this test is that
// discharge succeeds only because `rangeHypotheses` attaches `p`'s declared
// bound directly, not by re-deriving it from `x`'s `requires:` through the
// assignment.
func testProveValBindingRangeHypothesis(): Unit {
  val src = "@proof_required\npackage P\nfunc clip(x: in Int): Int\n  requires: x >= 0 and x <= 100\n  ensures: result >= 0 and result <= 100\n{\n  val p: Int range 0 ..= 100 = x\n  return p\n}\n"
  val summary = prove(src)
  match summary.level {
    case VLProofRequired -> {
    }
    case _ -> {
      assertTrue(false, "val-range-hyp: expected VLProofRequired")
    }
  }
  assertTrue(not summaryHasErrorDiag(summary), "val-range-hyp: no error diags")
  assertTrue(not summaryHasFailure(summary), "val-range-hyp: ensures discharges using the val's range hypothesis")
}

// #4848: a protected-type entry with a range-typed field. `goalsForProtectedEntry`
// now calls `rangeHypothesesForTerm` per field and threads the result through
// `goalsForFunctionWithExtraHyps`, so an entry's `ensures:` clause referencing
// the field's bound is provable purely from the field's declared range.
func testProveProtectedTypeRangeFieldHypothesis(): Unit {
  val src = "@proof_required\npackage P\nprotected type Meter {\n  var level: Int range 0 ..= 100\n  entry read(): Int requires: true ensures: result >= 0 and result <= 100 {\n    level\n  }\n}\n"
  val summary = prove(src)
  match summary.level {
    case VLProofRequired -> {
    }
    case _ -> {
      assertTrue(false, "prot-range-field-hyp: expected VLProofRequired")
    }
  }
  assertTrue(not summaryHasErrorDiag(summary), "prot-range-field-hyp: no error diags")
  assertTrue(
    not summaryHasFailure(summary),
    "prot-range-field-hyp: ensures discharges from the field's range hypothesis"
  )
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

// Trailing expression body: `result` must carry the declared return sort, not Unit.
// Without the fix the `result` TVar had sort `Unit` and the ensures discharged as
// V0007 (solver: unknown) rather than Discharged.
func testProveTrailingExprResultSort(): Unit {
  val src = "@proof_required\npackage P\n" + "func identity(x: in Int): Int ensures: result == x { x }\n"
  val summary = prove(src)
  assertTrue(
    not summaryHasDiagCode(summary, "V0007"),
    "trailing-expr-result: no V0007 (result sort was Unit before fix)"
  )
  assertTrue(not summaryHasFailure(summary), "trailing-expr-result: goal discharged")
  assertTrue(summaryTotalCount(summary) > 0, "trailing-expr-result: at least one goal generated")
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

test "prove val binding range hypothesis" {
  testProveValBindingRangeHypothesis()
}

test "prove protected type range field hypothesis" {
  testProveProtectedTypeRangeFieldHypothesis()
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

test "prove trailing expr result sort" {
  testProveTrailingExprResultSort()
}

// A `break` leaves a loop without the invariant or the negated condition, so
// the verifier's post-loop assumption (`invariant and not cond`) would be
// unsound on that path. The verifier does not model `break`: it falls into
// the generic V0026 "unsupported statement" error, so a proof through one fails rather than discharging
// against the wrong assumption. Supporting `break` must drop that
// assumption for a loop that can break (#7396).
test "a proof through a loop break is rejected, not discharged (#7396)" {
  val src = "@proof_required\npackage Br\n\nfunc f(n: in Int): Int\n  ensures: result >= 0\n{\n  var i = 0\n  while i < n\n    invariant: i >= 0\n  {\n    if i == 3 {\n      i = -1\n      break\n    }\n    i = i + 1\n  }\n  i\n}\n"
  val summary = prove(src)
  assertTrue(summaryHasErrorDiag(summary), "break is a V0026 error, so the proof fails")
  var sawV0026 = false
  var i = 0
  while i < summary.diagnostics.count {
    if summary.diagnostics[i].code == "V0026" {
      sawV0026 = true
    }
    i = i + 1
  }
  assertTrue(sawV0026, "the error is V0026")
}

// ─────────────────────────────────────────────────────────────────────────────
// Unsigned literals, ranges and operators (#7848); signed minimum literals
// (#7853).  The prove-level cases need a real solver (z3 on CI), like the
// protected-entry range goal above.
// ─────────────────────────────────────────────────────────────────────────────
func provePkg(body: in String): ProofSummary {
  prove("@proof_required\npackage U\n" + body)
}

func assertDischarged(body: in String, label: in String): Unit {
  val s = provePkg(body)
  assertTrue(summaryTotalCount(s) > 0, label + ": goals generated")
  assertTrue(not summaryHasErrorDiag(s), label + ": no error diagnostics")
  assertTrue(not summaryHasFailure(s), label + ": every goal discharged")
}

func assertRefuted(body: in String, label: in String): Unit {
  val s = provePkg(body)
  assertTrue(summaryHasCounterexample(s), label + ": the solver finds a counterexample")
  assertTrue(not summaryHasDiagCode(s, "V0033"), label + ": the obligation is translatable")
}

func assertUntranslatable(body: in String, label: in String): Unit {
  val s = provePkg(body)
  assertTrue(summaryHasDiagCode(s, "V0033"), label + ": V0033 reported")
  assertTrue(summaryHasErrorDiag(s), label + ": the proof fails closed")
}

func bvVar(name: in String, w: in Int): Term {
  TVar(name = name, sort = SBitVec(width = w))
}

test "smt renders unsigned constants as bitvectors of their width (#7848)" {
  val max64 = TLit(value = VLBitVec(bits = -1i64, width = 64), sort = SBitVec(width = 64))
  assertEqual(smtRenderTerm(max64), "(_ bv18446744073709551615 64)", "u64 max is its unsigned value")
  val signBit64 = TLit(value = VLBitVec(bits = -9223372036854775807i64 - 1i64, width = 64), sort = SBitVec(width = 64))
  assertEqual(smtRenderTerm(signBit64), "(_ bv9223372036854775808 64)", "u64 sign bit")
  val max32 = TLit(value = VLBitVec(bits = 4294967295i64, width = 32), sort = SBitVec(width = 32))
  assertEqual(smtRenderTerm(max32), "(_ bv4294967295 32)", "u32 max")
  assertEqual(unsignedLongToString(-2i64), "18446744073709551614", "unsigned decimal of -2")
  assertEqual(unsignedLongToString(0i64), "0", "unsigned decimal of 0")
}

test "smt renders unsigned ordering, division and remainder with the unsigned bitvector operators (#7848)" {
  val x = bvVar("x", 32)
  val y = bvVar("y", 32)
  assertEqual(smtRenderTerm(TBuiltin(op = BOpLt, args = termList2(x, y))), "(bvult x y)", "<")
  assertEqual(smtRenderTerm(TBuiltin(op = BOpLte, args = termList2(x, y))), "(bvule x y)", "<=")
  assertEqual(smtRenderTerm(TBuiltin(op = BOpGt, args = termList2(x, y))), "(bvugt x y)", ">")
  assertEqual(smtRenderTerm(TBuiltin(op = BOpGte, args = termList2(x, y))), "(bvuge x y)", ">=")
  assertEqual(smtRenderTerm(TBuiltin(op = BOpDiv, args = termList2(x, y))), "(bvudiv x y)", "/")
  assertEqual(smtRenderTerm(TBuiltin(op = BOpMod, args = termList2(x, y))), "(bvurem x y)", "%")
  assertEqual(smtRenderTerm(TBuiltin(op = BOpAdd, args = termList2(x, y))), "(bvadd x y)", "+")
  assertEqual(smtRenderTerm(TBuiltin(op = BOpSub, args = termList2(x, y))), "(bvsub x y)", "-")
  assertEqual(smtRenderTerm(TBuiltin(op = BOpMul, args = termList2(x, y))), "(bvmul x y)", "*")
  assertEqual(smtRenderTerm(TBuiltin(op = BOpEq, args = termList2(x, y))), "(= x y)", "==")
}

test "an integer constant next to an unsigned operand becomes a bitvector; a signed variable does not (#7848)" {
  val x = bvVar("x", 32)
  match unifyOperands(x, TLit(value = VLInt(n = 3000000000i64), sort = SInt)) {
    case Ok(p) -> assertEqual(smtRenderTerm(p.rhs), "(_ bv3000000000 32)", "literal takes the operand's width")
    case Err(r) -> assertTrue(false, "unify literal: " + r)
  }
  match unifyOperands(x, TLit(value = VLInt(n = -1i64), sort = SInt)) {
    case Ok(_) -> assertTrue(false, "a negative constant is not a UInt")
    case Err(_) -> ()
  }
  match unifyOperands(x, TLit(value = VLInt(n = 4294967296i64), sort = SInt)) {
    case Ok(_) -> assertTrue(false, "2^32 does not fit a UInt")
    case Err(_) -> ()
  }
  match unifyOperands(x, TVar(name = "i", sort = SInt)) {
    case Ok(_) -> assertTrue(false, "a UInt and an Int variable have no common sort")
    case Err(_) -> ()
  }
  match unifyOperands(x, bvVar("u", 64)) {
    case Ok(p) -> assertEqual(smtRenderTerm(p.lhs), "((_ zero_extend 32) x)", "UInt widens to ULong by zero-extension")
    case Err(r) -> assertTrue(false, "widen: " + r)
  }
  match unifyOperands(bvVar("b", 8), TVar(name = "i", sort = SInt)) {
    case Ok(p) -> assertEqual(smtRenderTerm(p.lhs), "(bv2nat b)", "Byte widens into the signed chain by value")
    case Err(r) -> assertTrue(false, "byte widen: " + r)
  }
}

test "a UInt literal above the sign bit is ordered unsigned (#7848)" {
  assertDischarged(
    "func f(x: in UInt): UInt\n  requires: x > 3000000000\n  ensures: result >= 2147483648\n{\n  x\n}\n",
    "u32-order-discharge"
  )
  assertRefuted(
    "func f(x: in UInt): UInt\n  requires: x > 3000000000\n  ensures: result < 2147483648\n{\n  x\n}\n",
    "u32-order-refute"
  )
}

test "a ULong literal above the sign bit is its unsigned value (#7848)" {
  assertDischarged(
    "func g(x: in ULong): ULong\n  requires: x >= 18446744073709551615u64\n  ensures: result == 18446744073709551615u64\n{\n  x\n}\n",
    "u64-max-discharge"
  )
  assertDischarged(
    "func g(x: in ULong): ULong\n  requires: x > 9223372036854775807\n  ensures: result >= 0x8000_0000_0000_0000u64\n{\n  x\n}\n",
    "u64-sign-bit-discharge"
  )
  assertRefuted(
    "func g(x: in ULong): ULong\n  requires: x > 9223372036854775807\n  ensures: result < 9223372036854775807\n{\n  x\n}\n",
    "u64-sign-bit-refute"
  )
}

test "an unsigned range subtype's bounds are folded unsigned (#7848)" {
  val big = "ULong range 9223372036854775808u64 ..= 18446744073709551615u64"
  assertDischarged(
    "func h(x: in " + big + "): ULong\n  ensures: result > 9223372036854775807u64\n{\n  x\n}\n",
    "u64-range-discharge"
  )
  assertRefuted(
    "func h(x: in " + big + "): ULong\n  ensures: result < 18446744073709551615u64\n{\n  x\n}\n",
    "u64-range-refute"
  )
  val small = "UInt range 0 ..= 100"
  assertDischarged("func c(x: in UInt): " + small + "\n  requires: x <= 100\n{\n  x\n}\n", "u32-range-result-discharge")
  assertRefuted("func c(x: in UInt): " + small + "\n  requires: x <= 101\n{\n  x\n}\n", "u32-range-result-refute")
  assertUntranslatable("func c(x: in UInt): UInt range -1 ..= 5\n{\n  x\n}\n", "negative-unsigned-bound")
  assertUntranslatable("func c(x: in UInt): UInt range 0 ..= 4294967296\n{\n  x\n}\n", "over-wide-unsigned-bound")
}

test "a counterexample over a bitvector sort keeps the whole sort (#7848)" {
  val model = "sat\n(\n  (define-fun x () (_ BitVec 32)\n    #x00000000)\n)\n"
  val bindings = parseModel(model)
  assertEqualInt(bindings.count, 1, "one binding")
  assertEqual(bindings[0].sort, "(_ BitVec 32)", "the sort is the full bitvector sort")
  assertEqual(bindings[0].value, "#x00000000", "the value")
}

test "unsigned division and remainder are unsigned (#7848)" {
  assertDischarged(
    "func half(x: in UInt): UInt\n  requires: x == 4294967295\n  ensures: result == 2147483647\n{\n  x / 2\n}\n",
    "udiv-discharge"
  )
  assertRefuted(
    "func half(x: in UInt): UInt\n  requires: x == 4294967295\n  ensures: result == 0\n{\n  x / 2\n}\n",
    "udiv-refute-signed-reading"
  )
  assertDischarged(
    "func rem(x: in UInt): UInt\n  requires: x == 4294967295\n  ensures: result == 5\n{\n  x % 10\n}\n",
    "urem-discharge"
  )
  assertDischarged("func half2(x: in UInt): UInt\n  ensures: result <= x\n{\n  x / 2\n}\n", "udiv-bound")
}

test "unsigned widening zero-extends and wraps are modelled (#7848)" {
  assertDischarged(
    "func w(a: in UInt, b: in ULong): ULong\n  requires: a == 4294967295 and b == 1\n  ensures: result == 4294967296\n{\n  a + b\n}\n",
    "zero-extend-discharge"
  )
  assertRefuted(
    "func w(a: in UInt, b: in ULong): ULong\n  requires: a == 4294967295 and b == 1\n  ensures: result == 0\n{\n  a + b\n}\n",
    "zero-extend-refute"
  )
  assertDischarged(
    "func bytes(b: in Byte): Byte\n  requires: b >= 200\n  ensures: result > 199\n{\n  b\n}\n",
    "byte-literal-discharge"
  )
}

test "checked arithmetic proves unsigned operations do not wrap (#7848)" {
  val checked = "@proof_required(checked_arithmetic)\npackage C\n"
  val bad = prove(checked + "func inc(x: in UInt): UInt\n{\n  x + 1\n}\n")
  assertTrue(summaryHasCounterexample(bad), "x + 1 can wrap")
  val good = prove(checked + "func inc(x: in UInt): UInt\n  requires: x < 4294967295\n{\n  x + 1\n}\n")
  assertTrue(not summaryHasFailure(good) and not summaryHasErrorDiag(good), "x + 1 cannot wrap below the maximum")
  val sub = prove(checked + "func dec(x: in UInt): UInt\n{\n  x - 1\n}\n")
  assertTrue(summaryHasCounterexample(sub), "x - 1 can wrap below zero")
  val mul = prove(checked + "func dbl(x: in UInt): UInt\n  requires: x <= 2147483647\n{\n  x * 2\n}\n")
  assertTrue(not summaryHasFailure(mul) and not summaryHasErrorDiag(mul), "x * 2 cannot wrap below 2^31")
}

test "an obligation that mixes unsigned and signed operands fails closed (#7848)" {
  assertUntranslatable("func m(a: in UInt, i: in Int): Bool\n  ensures: result\n{\n  a < i\n}\n", "uint-vs-int")
  assertUntranslatable("func n(): UInt\n  ensures: result == 1\n{\n  -1\n}\n", "negative-literal-as-uint")
  assertUntranslatable("func neg(x: in UInt): UInt\n  ensures: result == 0\n{\n  -x\n}\n", "unsigned-negation")
}

test "Long.MinValue is negative, however it is spelled (#7853)" {
  assertDischarged("func mn(): Long\n  ensures: result < 0\n{\n  -9223372036854775808\n}\n", "long-min-discharge")
  assertRefuted("func mn(): Long\n  ensures: result > 0\n{\n  -9223372036854775808\n}\n", "long-min-refute")
  assertDischarged(
    "func mh(): Long\n  ensures: result == 0 - 9223372036854775807 - 1\n{\n  -0x8000_0000_0000_0000\n}\n",
    "long-min-hex-discharge"
  )
  assertRefuted("func mh(): Long\n  ensures: result >= 0\n{\n  -0x8000_0000_0000_0000\n}\n", "long-min-hex-refute")
  val s = provePkg("func mn(): Long\n  ensures: result < 0\n{\n  -9223372036854775808\n}\n")
  assertTrue(s.results.count > 0, "long-min: a goal")
  val smt = smtRenderGoal(s.results[0].goal)
  assertTrue(smt.contains("(- 9223372036854775808)"), "long-min is one negative SMT constant")
  assertTrue(not smt.contains("-9223372036854775808"), "no bare negative numeral")
}

test "a signed suffix's minimum is one negative constant (#7853)" {
  assertDischarged(
    "func mi(): Int\n  ensures: result == 0 - 2147483647 - 1\n{\n  -2147483648i32\n}\n",
    "i32-min-discharge"
  )
  assertRefuted("func mi(): Int\n  ensures: result > 0\n{\n  -2147483648i32\n}\n", "i32-min-refute")
  assertDischarged("func mb(): Int\n  ensures: result == 0 - 128\n{\n  -128i8\n}\n", "i8-min-discharge")
  assertRefuted("func mb(): Int\n  ensures: result == 128\n{\n  -128i8\n}\n", "i8-min-refute")
  assertDischarged("func ml(): Long\n  ensures: result < 0\n{\n  -9223372036854775808i64\n}\n", "i64-min-discharge")
}

test "a range bound at Long.MinValue is folded signed (#7853)" {
  val neg = "Long range -9223372036854775808 ..= -1"
  assertDischarged("func k(x: in " + neg + "): Long\n  ensures: result < 0\n{\n  x\n}\n", "min-bound-discharge")
  assertRefuted(
    "func k(x: in " + neg + "): Long\n  ensures: result > -9223372036854775808\n{\n  x\n}\n",
    "min-bound-refute"
  )
}

test "a literal bound, assigned or passed at an unsigned type takes that type (#7848)" {
  assertDischarged(
    "func v(): UInt\n  ensures: result == 2147483647\n{\n  val y: UInt = 4294967295\n  y / 2\n}\n",
    "val-binding"
  )
  assertDischarged(
    "func a(): UInt\n  ensures: result == 5\n{\n  var z: UInt = 1\n  z = 4294967295\n  z % 10\n}\n",
    "var-assignment"
  )
  assertDischarged(
    "func callee(x: in UInt): UInt\n  requires: x > 2147483648\n  ensures: result == x\n{\n  x\n}\n" +
      "func caller(): UInt\n  ensures: result > 2147483648\n{\n  callee(4294967295)\n}\n",
    "call-argument"
  )
  assertRefuted(
    "func v(): UInt\n  ensures: result == 0\n{\n  val y: UInt = 4294967295\n  y / 2\n}\n",
    "val-binding-refute"
  )
}

test "a signed variable passed at an unsigned parameter fails closed (#7848)" {
  val callee = "func callee(x: in UInt): UInt\n  requires: x > 2147483648\n  ensures: result == x\n{\n  x\n}\n"
  assertUntranslatable(
    callee +
      "func caller(i: in Int): UInt\n  requires: i > 2147483648\n  ensures: result > 2147483648\n{\n  callee(i)\n}\n",
    "signed-variable-argument"
  )
  assertUntranslatable(
    callee +
      "func caller(i: in Int): UInt\n  requires: i > 0\n  ensures: result > 2147483648\n{\n  callee(i + 2147483648)\n}\n",
    "signed-expression-argument"
  )
}

func intVar(name: in String): Term {
  TVar(name = name, sort = SInt)
}

test "smt renders signed / and % through the truncating definitions (#7870)" {
  val a = intVar("a")
  val b = intVar("b")
  assertEqual(smtRenderTerm(TBuiltin(op = BOpDiv, args = termList2(a, b))), "(lyric!tdiv a b)", "signed /")
  assertEqual(smtRenderTerm(TBuiltin(op = BOpMod, args = termList2(a, b))), "(lyric!trem a b)", "signed %")
  val r = TVar(name = "r", sort = SFloat64)
  assertEqual(smtRenderTerm(TBuiltin(op = BOpRealDiv, args = termList2(r, r))), "(/ r r)", "real / is unchanged")
  val preamble = smtRenderPreamble()
  assertTrue(
    preamble.contains(
      "(define-fun lyric!tdiv ((a Int) (b Int)) Int (ite (= b 0) (div a 0) (ite (= (>= a 0) (>= b 0)) (div (abs a) (abs b)) (- (div (abs a) (abs b))))))"
    ),
    "tdiv is defined in the preamble"
  )
  assertTrue(
    preamble.contains(
      "(define-fun lyric!trem ((a Int) (b Int)) Int (ite (= b 0) (mod a 0) (- a (* b (lyric!tdiv a b)))))"
    ),
    "trem is defined in the preamble"
  )
  val s = provePkg("func q(a: in Int, b: in Int): Int\n  requires: b != 0\n  ensures: result == a / b\n{\n  a / b\n}\n")
  assertTrue(s.results.count > 0, "q: a goal")
  val smt = smtRenderGoal(s.results[0].goal)
  assertTrue(smt.contains("(lyric!tdiv a b)"), "a goal divides through tdiv")
  assertTrue(not smt.contains("(div a b)"), "no Euclidean div of the operands")
}

func divBody(op: in String, a: in String, b: in String, post: in String): String {
  "func f(a: in Int, b: in Int): Int\n  requires: a == " + a + " and b == " + b + "\n  ensures: " + post + "\n{\n  a " +
    op +
    " b\n}\n"
}

test "signed / truncates toward zero (#7870)" {
  assertDischarged(divBody("/", "-7", "2", "result == -3"), "neg-by-pos-discharge")
  assertRefuted(divBody("/", "-7", "2", "result == -4"), "neg-by-pos-euclidean-refute")
  assertDischarged(divBody("/", "7", "-2", "result == -3"), "pos-by-neg-discharge")
  assertRefuted(divBody("/", "7", "-2", "result == -4"), "pos-by-neg-floor-refute")
  assertDischarged(divBody("/", "-7", "-2", "result == 3"), "neg-by-neg-discharge")
  assertRefuted(divBody("/", "-7", "-2", "result == 4"), "neg-by-neg-euclidean-refute")
}

test "signed % takes the dividend's sign (#7870)" {
  assertDischarged(divBody("%", "-7", "2", "result == -1"), "neg-by-pos-discharge")
  assertRefuted(divBody("%", "-7", "2", "result == 1"), "neg-by-pos-euclidean-refute")
  assertDischarged(divBody("%", "7", "-2", "result == 1"), "pos-by-neg-discharge")
  assertRefuted(divBody("%", "7", "-2", "result == -1"), "pos-by-neg-floor-refute")
  assertDischarged(divBody("%", "-7", "-2", "result == -1"), "neg-by-neg-discharge")
  assertRefuted(divBody("%", "-7", "-2", "result == 1"), "neg-by-neg-euclidean-refute")
}

test "truncating division satisfies its identities symbolically (#7870)" {
  assertDischarged(
    "func r(a: in Int, b: in Int): Int\n  requires: a < 0 and b != 0\n  ensures: result <= 0\n{\n  a % b\n}\n",
    "negative-dividend-remainder-is-non-positive"
  )
  assertRefuted(
    "func r(a: in Int, b: in Int): Int\n  requires: a < 0 and b != 0\n  ensures: result < 0\n{\n  a % b\n}\n",
    "remainder-can-be-zero"
  )
  assertDischarged(
    "func q(a: in Long, b: in Long): Long\n  requires: b != 0\n  ensures: result == a - b * (a / b)\n{\n  a % b\n}\n",
    "division-identity"
  )
  assertDischarged(
    "func n(a: in Long, b: in Long): Long\n  requires: b != 0\n  ensures: result == 0 - (0 - a) / b\n{\n  a / b\n}\n",
    "negating-the-dividend-negates-the-quotient"
  )
  assertDischarged(
    "func c(x: in Int): Int\n  requires: x == -9\n  ensures: result == -2\n{\n  var y = x\n  y /= 4\n  y\n}\n",
    "compound-assignment"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Signed overflow is checked at the operand's width: 32 bits for `Int`, 64
// for `Long` (D163, #7871).
// ─────────────────────────────────────────────────────────────────────────────
func proveChecked(body: in String): ProofSummary {
  prove("@proof_required(checked_arithmetic)\npackage C\n" + body)
}

func assertCheckedDischarged(body: in String, label: in String): Unit {
  val s = proveChecked(body)
  assertTrue(summaryTotalCount(s) > 0, label + ": goals generated")
  assertTrue(not summaryHasErrorDiag(s), label + ": no error diagnostics")
  assertTrue(not summaryHasFailure(s), label + ": every goal discharged")
}

func assertCheckedRefuted(body: in String, label: in String): Unit {
  val s = proveChecked(body)
  assertTrue(summaryHasCounterexample(s), label + ": the solver finds a counterexample")
  assertTrue(not summaryHasDiagCode(s, "V0033"), label + ": the obligation is translatable")
}

test "Int addition overflows past Int.MaxValue, not Long.MaxValue (#7871)" {
  assertCheckedRefuted("func inc(x: in Int): Int\n{\n  x + 1\n}\n", "int-inc-unconstrained")
  assertCheckedRefuted("func inc(x: in Int): Int\n  requires: x >= 2147483647\n{\n  x + 1\n}\n", "int-inc-at-max")
  assertCheckedDischarged("func inc(x: in Int): Int\n  requires: x < 2147483647\n{\n  x + 1\n}\n", "int-inc-below-max")
  assertCheckedDischarged(
    "func inc(x: in Long): Long\n  requires: x == 2147483647\n{\n  x + 1\n}\n",
    "long-inc-past-int-max"
  )
  assertCheckedRefuted(
    "func inc(x: in Long): Long\n  requires: x == 9223372036854775807\n{\n  x + 1\n}\n",
    "long-inc-at-max"
  )
  assertCheckedDischarged(
    "func inc(x: in Long): Long\n  requires: x < 9223372036854775807\n{\n  x + 1\n}\n",
    "long-inc-below-max"
  )
}

test "Int subtraction, multiplication and negation overflow at Int.MinValue (#7871)" {
  assertCheckedRefuted("func dec(x: in Int): Int\n  requires: x <= -2147483648\n{\n  x - 1\n}\n", "int-dec-at-min")
  assertCheckedDischarged("func dec(x: in Int): Int\n  requires: x > -2147483648\n{\n  x - 1\n}\n", "int-dec-above-min")
  assertCheckedDischarged(
    "func dec(x: in Long): Long\n  requires: x == -2147483648\n{\n  x - 1\n}\n",
    "long-dec-past-int-min"
  )
  assertCheckedRefuted(
    "func dec(x: in Long): Long\n  requires: x == -9223372036854775808\n{\n  x - 1\n}\n",
    "long-dec-at-min"
  )
  assertCheckedRefuted("func neg(x: in Int): Int\n{\n  -x\n}\n", "int-neg-of-min")
  assertCheckedDischarged("func neg(x: in Int): Int\n  requires: x > -2147483648\n{\n  -x\n}\n", "int-neg-above-min")
  assertCheckedRefuted("func neg(x: in Long): Long\n{\n  -x\n}\n", "long-neg-of-min")
  assertCheckedDischarged(
    "func dbl(x: in Int): Int\n  requires: x >= -1073741824 and x <= 1073741823\n{\n  x * 2\n}\n",
    "int-mul-in-range"
  )
  assertCheckedRefuted("func dbl(x: in Int): Int\n  requires: x == 1073741824\n{\n  x * 2\n}\n", "int-mul-past-max")
  assertCheckedDischarged(
    "func dbl(x: in Long): Long\n  requires: x == 1073741824\n{\n  x * 2\n}\n",
    "long-mul-past-int-max"
  )
}

test "a binding's initializer and a compound assignment are checked at the binding's width (#7871)" {
  assertCheckedRefuted("func f(x: in Int): Int\n{\n  val y = x + 1\n  y\n}\n", "val-initializer")
  assertCheckedDischarged(
    "func f(x: in Int): Int\n  requires: x < 100\n{\n  val y = x + 1\n  y\n}\n",
    "val-initializer-bounded"
  )
  assertCheckedDischarged(
    "func f(x: in Int): Long\n  requires: x == 2147483647\n{\n  val y: Long = x\n  y + 1\n}\n",
    "long-binding-of-int"
  )
  assertCheckedRefuted("func f(x: in Int): Int\n{\n  var y = x\n  y += 1\n  y\n}\n", "compound-add")
  assertCheckedDischarged(
    "func f(x: in Int): Int\n  requires: x < 2147483647\n{\n  var y = x\n  y += 1\n  y\n}\n",
    "compound-add-bounded"
  )
  assertCheckedRefuted("func f(x: in UInt): UInt\n{\n  var y = x\n  y += 1\n  y\n}\n", "compound-unsigned-wrap")
}

test "a record field is checked at its declared width (#7871)" {
  val rec = "record Counter {\n  count: Long\n  small: Int\n}\n"
  assertCheckedDischarged(
    rec + "func bump(c: in Counter): Long\n  requires: c.count == 2147483647\n{\n  c.count + 1\n}\n",
    "long-field"
  )
  assertCheckedRefuted(
    rec + "func bump(c: in Counter): Int\n  requires: c.small == 2147483647\n{\n  c.small + 1\n}\n",
    "int-field"
  )
}

test "Int and Long parameters and callee results lie within their width (#7871)" {
  assertDischarged(
    "func f(x: in Int): Bool\n  ensures: result\n{\n  x <= 2147483647 and x >= -2147483648\n}\n",
    "int-param-width"
  )
  assertRefuted("func f(x: in Long): Bool\n  ensures: result\n{\n  x <= 2147483647\n}\n", "long-param-wider")
  assertDischarged(
    "func id(x: in Int): Int\n{\n  x\n}\nfunc g(y: in Int): Long\n  ensures: result < 2147483648\n{\n  id(y)\n}\n",
    "int-callee-result-width"
  )
}

test "a binding's initializer discharges its callee's precondition (#7871)" {
  val pos = "func pos(x: in Int): Int\n  requires: x > 0\n{\n  x\n}\n"
  assertRefuted(pos + "func f(y: in Int): Int\n{\n  val r = pos(y)\n  r\n}\n", "val-call-precondition")
  assertDischarged(
    pos + "func f(y: in Int): Int\n  requires: y > 0\n{\n  val r = pos(y)\n  r\n}\n",
    "val-call-precondition-met"
  )
  assertRefuted(pos + "func f(y: in Int): Int\n{\n  var r = 1\n  r = pos(y)\n  r\n}\n", "assign-call-precondition")
}

// ─────────────────────────────────────────────────────────────────────────────
// An untranslatable construct is reported once, and its goal stays failed
// (#7874).
// ─────────────────────────────────────────────────────────────────────────────
func countDiagCode(s: in ProofSummary, code: in String): Int {
  var n = 0
  var i = 0
  while i < s.diagnostics.count {
    if s.diagnostics[i].code == code {
      n = n + 1
    }
    i = i + 1
  }
  n
}

test "a UInt beside an Int is reported once and its goal fails (#7874)" {
  val s = provePkg("func m(a: in UInt, i: in Int): Bool\n  ensures: result\n{\n  a < i\n}\n")
  assertEqualInt(countDiagCode(s, "V0033"), 1, "one V0033 for one mix")
  assertTrue(summaryHasFailure(s), "the goal is not discharged")
  assertEqualInt(summaryDischargedCount(s), 0, "nothing is discharged")
}

test "an untranslatable result range keeps the postcondition failed (#7874)" {
  val s = provePkg("func c(x: in UInt): UInt range -1 ..= 5\n  ensures: result == x\n{\n  x\n}\n")
  assertEqualInt(countDiagCode(s, "V0033"), 1, "one V0033 for the bound")
  assertTrue(summaryHasFailure(s), "the postcondition is not reported discharged")
}

test "an untranslatable callee contract is reported once across calls (#7874)" {
  val s = provePkg(
    "func k(a: in UInt, i: in Int): Bool\n  requires: a < i\n{\n  true\n}\n" +
      "func u(a: in UInt, i: in Int): Bool\n{\n  k(a, i) and k(a, i)\n}\n"
  )
  assertEqualInt(countDiagCode(s, "V0033"), 1, "one V0033 for the contract")
  assertTrue(summaryHasFailure(s), "the goals that use it are not discharged")
}

// ─────────────────────────────────────────────────────────────────────────────
// A callee's contract takes each argument at the parameter it names, and an
// omitted parameter's default (#7873).
// ─────────────────────────────────────────────────────────────────────────────
test "named arguments bind by name in the callee's contract (#7873)" {
  val sub = "func sub(a: in Int, b: in Int): Int\n  ensures: result == a - b\n{\n  a - b\n}\n"
  assertDischarged(sub + "func g(): Int\n  ensures: result == 7\n{\n  sub(b = 3, a = 10)\n}\n", "reordered-discharge")
  assertRefuted(sub + "func g(): Int\n  ensures: result == -7\n{\n  sub(b = 3, a = 10)\n}\n", "reordered-refute")
  assertDischarged(
    sub + "func g(): Int\n  ensures: result == 7\n{\n  sub(b = 3, 10)\n}\n",
    "positional-fills-free-slot"
  )
  val clamp = "func clamp(x: in Int, lo: in Int, hi: in Int): Int\n  requires: lo <= hi\n" +
    "  ensures: result >= lo and result <= hi\n{\n  if x < lo { lo } else { if x > hi { hi } else { x } }\n}\n"
  assertDischarged(
    clamp + "func g(v: in Int): Int\n  ensures: result >= 0 and result <= 10\n{\n  clamp(hi = 10, lo = 0, x = v)\n}\n",
    "clamp-discharge"
  )
  assertRefuted(
    clamp + "func g(v: in Int): Int\n  ensures: result >= 0 and result <= 10\n{\n  clamp(hi = 0, lo = 10, x = v)\n}\n",
    "clamp-precondition-refute"
  )
}

test "an omitted parameter takes its default in the callee's contract (#7873)" {
  val addk = "func addk(x: in Int, k: in Int = 5): Int\n  ensures: result == x + k\n{\n  x + k\n}\n"
  assertDischarged(addk + "func g(y: in Int): Int\n  ensures: result == y + 5\n{\n  addk(y)\n}\n", "default-discharge")
  assertRefuted(addk + "func g(y: in Int): Int\n  ensures: result == y\n{\n  addk(y)\n}\n", "default-refute")
  assertDischarged(
    addk + "func g(y: in Int): Int\n  ensures: result == y + 2\n{\n  addk(k = 2, x = y)\n}\n",
    "default-overridden"
  )
  val div = "func half(n: in Int, d: in Int = 2): Int\n  requires: d != 0\n{\n  n / d\n}\n"
  assertDischarged(div + "func g(): Int\n{\n  half(7)\n}\n", "default-meets-precondition")
  assertRefuted(div + "func g(): Int\n{\n  half(d = 0, n = 7)\n}\n", "named-violates-precondition")
}

test "record constructor arguments bind by field name, with field defaults (#7873)" {
  val rec = "record P {\n  x: Int\n  y: Int = 7\n}\n"
  assertDischarged(
    rec + "func mk(): P\n  ensures: result.x == 2 and result.y == 1\n{\n  P(y = 1, x = 2)\n}\n",
    "record-named"
  )
  assertRefuted(rec + "func mk(): P\n  ensures: result.x == 1\n{\n  P(y = 1, x = 2)\n}\n", "record-named-refute")
  assertDischarged(rec + "func mk(): P\n  ensures: result.y == 7\n{\n  P(x = 1)\n}\n", "record-default")
}

test "a call whose arguments do not match the callee fails closed (#7873)" {
  val sub = "func sub(a: in Int, b: in Int): Int\n  ensures: result == a - b\n{\n  a - b\n}\n"
  assertUntranslatable(sub + "func g(): Int\n  ensures: result == 7\n{\n  sub(c = 3, a = 10)\n}\n", "unknown-name")
  assertUntranslatable(sub + "func g(): Int\n  ensures: result == 7\n{\n  sub(10)\n}\n", "missing-argument")
}
