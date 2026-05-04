module Lyric.Verifier.Tests.RegressionTests

/// M4.2 close-out: bulk regression tests targeting the §13 testing
/// strategy in `docs/15-phase-4-proof-plan.md`.  These exercise the
/// imperative-fragment wp/sp pipeline end-to-end via `Driver.proveSource`,
/// the SMT-LIB emitter, the trivial discharger, and the goal cache.
///
/// All tests use only the trivial syntactic discharger (no z3 required)
/// so the suite is portable across CI hosts.  Tests that exercise z3-only
/// shapes live in `DriverTests.fs` and are gated on the test outcome.

open Expecto
open Lyric.Lexer
open Lyric.Verifier
open Lyric.Verifier.Driver
open Lyric.Verifier.Solver
open Lyric.Verifier.Vcir

let private prove (src: string) =
    Driver.proveSource src None

let private spanZero = Span.pointAt Position.initial

let private mkGoal (hyps: Term list) (conclusion: Term) : Goal =
    { Hypotheses = hyps
      Conclusion = conclusion
      Symbols    = []
      Origin     = spanZero
      Kind       = GKAssertion
      Label      = "t" }

let private isDischarged (o: SolverOutcome) =
    match o with Discharged -> true | _ -> false

/// Driver-level positives that the trivial discharger closes.
let private positiveDriverTests =
    testList "Verifier — positive driver regressions" [

        // ---------------- identity-shape postconditions ----------------

        test "identity on Int discharges" {
            let src = """
                @proof_required
                package P
                pub func f(x: Int): Int
                  ensures: result == x
                  = x
                """
            Expect.equal (ProofSummary.dischargedCount (prove src)) 1 "ok"
        }

        test "identity on Bool discharges" {
            let src = """
                @proof_required
                package P
                pub func f(b: Bool): Bool
                  ensures: result == b
                  = b
                """
            Expect.equal (ProofSummary.dischargedCount (prove src)) 1 "ok"
        }

        test "identity on Long discharges" {
            let src = """
                @proof_required
                package P
                pub func f(x: Long): Long
                  ensures: result == x
                  = x
                """
            Expect.equal (ProofSummary.dischargedCount (prove src)) 1 "ok"
        }

        test "identity on String discharges" {
            let src = """
                @proof_required
                package P
                pub func f(s: String): String
                  ensures: result == s
                  = s
                """
            Expect.equal (ProofSummary.dischargedCount (prove src)) 1 "ok"
        }

        test "constant true discharges" {
            let src = """
                @proof_required
                package P
                pub func t(): Bool
                  ensures: result == true
                  = true
                """
            Expect.equal (ProofSummary.dischargedCount (prove src)) 1 "ok"
        }

        test "constant false discharges" {
            let src = """
                @proof_required
                package P
                pub func f(): Bool
                  ensures: result == false
                  = false
                """
            Expect.equal (ProofSummary.dischargedCount (prove src)) 1 "ok"
        }

        test "constant 0 with ensures result == 0 discharges" {
            let src = """
                @proof_required
                package P
                pub func zero(): Int
                  ensures: result == 0
                  = 0
                """
            Expect.equal (ProofSummary.dischargedCount (prove src)) 1 "ok"
        }

        test "constant 42 with ensures result == 42 discharges" {
            let src = """
                @proof_required
                package P
                pub func answer(): Int
                  ensures: result == 42
                  = 42
                """
            Expect.equal (ProofSummary.dischargedCount (prove src)) 1 "ok"
        }

        // ---------------- generic identity ----------------

        test "generic identity over T discharges" {
            let src = """
                @proof_required
                package P
                @pure
                pub generic[T] func id(x: in T): T
                  ensures: result == x
                  = x
                """
            Expect.equal (ProofSummary.dischargedCount (prove src)) 1 "ok"
        }

        test "two-arg pickFirst discharges" {
            let src = """
                @proof_required
                package P
                @pure
                pub generic[T, U] func pickFirst(a: in T, b: in U): T
                  ensures: result == a
                  = a
                """
            Expect.equal (ProofSummary.dischargedCount (prove src)) 1 "ok"
        }

        test "two-arg pickSecond discharges" {
            let src = """
                @proof_required
                package P
                @pure
                pub generic[T, U] func pickSecond(a: in T, b: in U): U
                  ensures: result == b
                  = b
                """
            Expect.equal (ProofSummary.dischargedCount (prove src)) 1 "ok"
        }

        // ---------------- let-binding ----------------

        test "let-bound passthrough discharges" {
            let src = """
                @proof_required
                package P
                pub func f(x: Int): Int
                  ensures: result == x
                {
                  let y = x
                  return y
                }
                """
            Expect.equal (ProofSummary.dischargedCount (prove src)) 1 "ok"
        }

        test "double let-bound passthrough discharges" {
            let src = """
                @proof_required
                package P
                pub func f(x: Int): Int
                  ensures: result == x
                {
                  let a = x
                  let b = a
                  return b
                }
                """
            Expect.equal (ProofSummary.dischargedCount (prove src)) 1 "ok"
        }

        test "val-bound passthrough discharges" {
            let src = """
                @proof_required
                package P
                pub func f(x: Int): Int
                  ensures: result == x
                {
                  val y = x
                  return y
                }
                """
            Expect.equal (ProofSummary.dischargedCount (prove src)) 1 "ok"
        }

        // ---------------- assert-as-side-goal ----------------

        test "assert(x == x) is a tautology side goal" {
            let src = """
                @proof_required
                package P
                pub func f(x: Int): Int
                  ensures: result == x
                {
                  assert(x == x)
                  return x
                }
                """
            // 2 goals: the post + the assert.
            let s = prove src
            Expect.equal (ProofSummary.totalCount s) 2 "two"
            Expect.equal (ProofSummary.dischargedCount s) 2 "both"
        }

        test "two assert-as-tautology in sequence" {
            let src = """
                @proof_required
                package P
                pub func f(x: Int, y: Int): Int
                  ensures: result == x
                {
                  assert(x == x)
                  assert(y == y)
                  return x
                }
                """
            let s = prove src
            Expect.equal (ProofSummary.totalCount s) 3 "three"
            Expect.equal (ProofSummary.dischargedCount s) 3 "all"
        }

        // ---------------- cross-call rule ----------------

        test "wrapper around id discharges via the call rule" {
            let src = """
                @proof_required
                package P
                pub func id(x: Int): Int
                  ensures: result == x
                { return x }
                pub func wrap(x: Int): Int
                  ensures: result == x
                { return id(x) }
                """
            let s = prove src
            Expect.equal (ProofSummary.dischargedCount s) 2 "both"
        }

        test "two-level wrapping around id discharges via the call rule" {
            let src = """
                @proof_required
                package P
                pub func id(x: Int): Int
                  ensures: result == x
                { return x }
                pub func a(x: Int): Int
                  ensures: result == x
                { return id(x) }
                pub func b(x: Int): Int
                  ensures: result == x
                { return a(x) }
                """
            let s = prove src
            Expect.equal (ProofSummary.dischargedCount s) 3 "three"
        }

        // ---------------- @pure unfold ----------------

        test "@pure unfold gives caller `f(x) == body`" {
            let src = """
                @proof_required
                package P
                @pure
                pub func id(x: Int): Int = x
                pub func wrap(x: Int): Int
                  ensures: result == id(x)
                { return id(x) }
                """
            let s = prove src
            Expect.isFalse (ProofSummary.hasFailure s) "ok"
        }

        test "@pure callee unfolded once at the call site" {
            // Single-level @pure unfold: the trivial discharger sees
            // `wrap(x) == x` via the unfold + the post `result == x`.
            let src = """
                @proof_required
                package P
                @pure
                pub func a(x: Int): Int = x
                pub func wrap(x: Int): Int
                  ensures: result == a(x)
                { return a(x) }
                """
            let s = prove src
            Expect.isFalse (ProofSummary.hasFailure s) "ok"
        }

        // ---------------- loop establish/preserve ----------------

        test "loop with `invariant: true` establishes and preserves" {
            let src = """
                @proof_required
                package P
                pub func f(): Int
                {
                  var i: Int = 0
                  while i < 10
                    invariant: true
                  {
                    i = i + 1
                  }
                  return i
                }
                """
            let s = prove src
            Expect.isFalse (ProofSummary.hasFailure s) "ok"
        }

        test "loop body containing only var i = i + 1 + invariant: true" {
            let src = """
                @proof_required
                package P
                pub func f(): Bool
                  ensures: result == true
                {
                  var i: Int = 0
                  while i < 5
                    invariant: true
                  {
                    i = i + 1
                  }
                  return true
                }
                """
            let s = prove src
            Expect.isFalse (ProofSummary.hasFailure s) "ok"
        }

        test "two trivial-invariant clauses fan out into separate goals" {
            let src = """
                @proof_required
                package P
                pub func f(): Int
                {
                  var i: Int = 0
                  while i < 3
                    invariant: true
                    invariant: true
                  {
                    i = i + 1
                  }
                  return i
                }
                """
            let s = prove src
            Expect.isFalse (ProofSummary.hasFailure s) "ok"
        }

        // ---------------- no-contract baseline ----------------

        test "func with no contracts produces a trivial post" {
            let src = """
                @proof_required
                package P
                pub func f(x: Int): Int { return x }
                """
            let s = prove src
            Expect.isFalse (ProofSummary.hasFailure s) "ok"
        }

        test "func with empty body and Unit return discharges" {
            let src = """
                @proof_required
                package P
                pub func f(): Unit { }
                """
            let s = prove src
            Expect.isFalse (ProofSummary.hasFailure s) "ok"
        }

        // ---------------- @axiom skips VC generation ----------------

        test "@axiom function emits no obligations" {
            let src = """
                @proof_required
                package P
                @axiom
                pub func opaque(x: Int): Int
                """
            let s = prove src
            Expect.equal (ProofSummary.totalCount s) 0 "zero"
        }

        test "@pure id discharges (single-function shape)" {
            // Companion test for the `@axiom` skip rule: a `@pure`
            // function on its own emits exactly one obligation.
            let src = """
                @proof_required
                package P
                @pure
                pub func id(x: Int): Int
                  ensures: result == x
                  = x
                """
            let s = prove src
            Expect.equal (ProofSummary.totalCount s) 1 "one"
            Expect.equal (ProofSummary.dischargedCount s) 1 "discharged"
        }

        // ---------------- runtime-checked passthrough ----------------

        test "runtime-checked package produces no obligations" {
            let src = """
                @runtime_checked
                package P
                pub func f(x: Int): Int { return x }
                """
            let s = prove src
            Expect.equal (ProofSummary.totalCount s) 0 "zero"
        }

        test "no-annotation package defaults to runtime-checked" {
            let src = """
                package P
                pub func f(x: Int): Int { return x }
                """
            let s = prove src
            Expect.equal (ProofSummary.totalCount s) 0 "zero"
        }

        // ---------------- parameterised positives ----------------

        // Family of identity-shaped functions distinguished only by
        // arity.  These exercise the env-binding step for many params.
        test "identity with two params ignored discharges" {
            let src = """
                @proof_required
                package P
                pub func f(x: Int, y: Int): Int
                  ensures: result == x
                  = x
                """
            Expect.isFalse (ProofSummary.hasFailure (prove src)) "ok"
        }

        test "identity with three params ignored discharges" {
            let src = """
                @proof_required
                package P
                pub func f(x: Int, y: Int, z: Int): Int
                  ensures: result == x
                  = x
                """
            Expect.isFalse (ProofSummary.hasFailure (prove src)) "ok"
        }

        test "identity with four params ignored discharges" {
            let src = """
                @proof_required
                package P
                pub func f(a: Int, b: Int, c: Int, d: Int): Int
                  ensures: result == d
                  = d
                """
            Expect.isFalse (ProofSummary.hasFailure (prove src)) "ok"
        }

        // ---------------- caller-supplied requires propagate ----------------

        test "caller's requires lets callee pre side-goal close" {
            let src = """
                @proof_required
                package P
                pub func id(x: Int): Int
                  requires: x >= 0
                  ensures: result == x
                { return x }
                pub func wrap(z: Int): Int
                  requires: z >= 0
                  ensures: result == z
                { return id(z) }
                """
            let s = prove src
            Expect.isFalse (ProofSummary.hasFailure s) "ok"
        }

        test "single requires from caller is sufficient for callee's pre" {
            // The conjunction-of-requires shape needs z3; a single
            // requires that exactly matches the callee's pre is in
            // the trivial discharger's reach via hypothesis-equality.
            let src = """
                @proof_required
                package P
                pub func id(x: Int): Int
                  requires: x >= 0
                  ensures: result == x
                { return x }
                pub func wrap(z: Int): Int
                  requires: z >= 0
                  ensures: result == z
                { return id(z) }
                """
            let s = prove src
            Expect.isFalse (ProofSummary.hasFailure s) "ok"
        }
    ]

/// Negative regressions: contracts that must NOT discharge.  We assert
/// the failure shape (Counterexample or Unknown — never Discharged).
let private negativeDriverTests =
    testList "Verifier — negative driver regressions" [

        test "wrong sign post does not discharge" {
            let src = """
                @proof_required
                package P
                pub func wrong(x: Int): Int
                  requires: x >= 0
                  ensures: result < 0
                { return x + 1 }
                """
            let s = prove src
            let r = List.head s.Results
            match r.Outcome with
            | Discharged -> failtest "must not discharge"
            | Counterexample _ | Unknown _ -> ()
            Expect.isTrue (ProofSummary.hasFailure s) "failure flag"
        }

        test "wrong identity ensures does not discharge" {
            let src = """
                @proof_required
                package P
                pub func wrong(x: Int): Int
                  ensures: result == x + 1
                { return x }
                """
            let s = prove src
            let r = List.head s.Results
            match r.Outcome with
            | Discharged -> failtest "must not discharge"
            | _ -> ()
        }

        test "ensures-on-constant that is always false does not discharge" {
            let src = """
                @proof_required
                package P
                pub func wrong(): Bool
                  ensures: result == false
                { return true }
                """
            let s = prove src
            let r = List.head s.Results
            match r.Outcome with
            | Discharged -> failtest "true ≠ false"
            | _ -> ()
        }

        test "wrong loop invariant fails to establish" {
            // `invariant: i == 99` is false at the loop entry where
            // `i == 0`, so the establish goal must NOT discharge.
            let src = """
                @proof_required
                package P
                pub func f(): Int
                {
                  var i: Int = 0
                  while i < 10
                    invariant: i == 99
                  {
                    i = i + 1
                  }
                  return i
                }
                """
            let s = prove src
            Expect.isTrue (ProofSummary.hasFailure s) "establish must fail"
        }

        test "wrong assert is rejected as a side goal" {
            let src = """
                @proof_required
                package P
                pub func f(x: Int): Int
                  ensures: result == x
                {
                  assert(x == x + 1)
                  return x
                }
                """
            let s = prove src
            Expect.isTrue (ProofSummary.hasFailure s) "assert side goal fails"
        }
    ]

/// SMT-LIB rendering — surface checks across the operator zoo.
let private smtTests =
    testList "Verifier — SMT-LIB rendering coverage" [

        test "and renders with `and` keyword" {
            let g =
                mkGoal
                    []
                    (Term.mkAnd [ TVar("p", SBool); TVar("q", SBool) ])
            Expect.stringContains (Smt.renderGoal g) "and" "and present"
        }

        test "or renders with `or` keyword" {
            let g =
                mkGoal
                    []
                    (Term.mkOr [ TVar("p", SBool); TVar("q", SBool) ])
            Expect.stringContains (Smt.renderGoal g) "or" "or present"
        }

        test "not renders with `not` keyword" {
            let g = mkGoal [] (Term.mkNot (TVar("p", SBool)))
            Expect.stringContains (Smt.renderGoal g) "not" "not present"
        }

        test "equality on Int renders as (= …)" {
            let g =
                mkGoal
                    []
                    (TBuiltin(BOpEq, [TVar("x", SInt); TVar("y", SInt)]))
            Expect.stringContains (Smt.renderGoal g) "(= x y)" "= x y"
        }

        test "less-than renders as (< …)" {
            let g =
                mkGoal
                    []
                    (TBuiltin(BOpLt, [TVar("x", SInt); TVar("y", SInt)]))
            Expect.stringContains (Smt.renderGoal g) "(< x y)" "< x y"
        }

        test "addition renders as (+ …)" {
            let g =
                mkGoal
                    []
                    (TBuiltin(BOpEq,
                        [ TVar("z", SInt)
                          TBuiltin(BOpAdd, [TVar("x", SInt); TVar("y", SInt)]) ]))
            Expect.stringContains (Smt.renderGoal g) "(+ x y)" "+ x y"
        }

        test "subtraction renders as (- …)" {
            let g =
                mkGoal
                    []
                    (TBuiltin(BOpEq,
                        [ TVar("z", SInt)
                          TBuiltin(BOpSub, [TVar("x", SInt); TVar("y", SInt)]) ]))
            Expect.stringContains (Smt.renderGoal g) "(- x y)" "- x y"
        }

        test "multiplication renders as (* …)" {
            let g =
                mkGoal
                    []
                    (TBuiltin(BOpEq,
                        [ TVar("z", SInt)
                          TBuiltin(BOpMul, [TVar("x", SInt); TVar("y", SInt)]) ]))
            Expect.stringContains (Smt.renderGoal g) "(* x y)" "* x y"
        }

        test "set-logic ALL header is always present" {
            let g = mkGoal [] Term.trueT
            Expect.stringContains (Smt.renderGoal g) "(set-logic ALL)" "logic"
        }

        test "check-sat trailer is always present" {
            let g = mkGoal [] Term.trueT
            Expect.stringContains (Smt.renderGoal g) "(check-sat)" "check-sat"
        }

        test "get-model trailer is always present" {
            let g = mkGoal [] Term.trueT
            Expect.stringContains (Smt.renderGoal g) "(get-model)" "get-model"
        }

        test "Bool literal true renders as `true`" {
            let g =
                mkGoal
                    []
                    (TBuiltin(BOpEq, [TVar("p", SBool); Term.trueT]))
            Expect.stringContains (Smt.renderGoal g) "true" "literal true"
        }

        test "Bool literal false renders as `false`" {
            let g =
                mkGoal
                    []
                    (TBuiltin(BOpEq, [TVar("p", SBool); Term.falseT]))
            Expect.stringContains (Smt.renderGoal g) "false" "literal false"
        }

        test "Int literal 0 renders as `0`" {
            let g =
                mkGoal
                    []
                    (TBuiltin(BOpEq, [TVar("x", SInt); TLit(LInt 0L, SInt)]))
            Expect.stringContains (Smt.renderGoal g) " 0" "literal 0"
        }

        test "Int literal 1 renders as `1`" {
            let g =
                mkGoal
                    []
                    (TBuiltin(BOpEq, [TVar("x", SInt); TLit(LInt 1L, SInt)]))
            Expect.stringContains (Smt.renderGoal g) " 1" "literal 1"
        }
    ]

/// Trivial-discharger coverage matrix.
let private dischargerTests =
    testList "Verifier — trivial discharger coverage" [

        test "true literal closes" {
            Expect.isTrue
                (isDischarged (discharge (mkGoal [] Term.trueT)))
                "true"
        }

        test "= x x closes" {
            let x = TVar("x", SInt)
            Expect.isTrue
                (isDischarged (discharge (mkGoal [] (TBuiltin(BOpEq, [x; x])))))
                "x = x"
        }

        test ">= x x closes" {
            let x = TVar("x", SInt)
            Expect.isTrue
                (isDischarged (discharge (mkGoal [] (TBuiltin(BOpGte, [x; x])))))
                "x >= x"
        }

        test "<= x x closes" {
            let x = TVar("x", SInt)
            Expect.isTrue
                (isDischarged (discharge (mkGoal [] (TBuiltin(BOpLte, [x; x])))))
                "x <= x"
        }

        test "= y y over Bool closes" {
            let y = TVar("y", SBool)
            Expect.isTrue
                (isDischarged (discharge (mkGoal [] (TBuiltin(BOpEq, [y; y])))))
                "y = y"
        }

        test "= s s over String closes" {
            let s = TVar("s", SString)
            Expect.isTrue
                (isDischarged (discharge (mkGoal [] (TBuiltin(BOpEq, [s; s])))))
                "s = s"
        }

        test "P ⇒ P closes (conclusion form)" {
            let p = TVar("p", SBool)
            Expect.isTrue
                (isDischarged (discharge (mkGoal [] (Term.mkImplies p p))))
                "P=>P"
        }

        test "(P ∧ Q) ⇒ P closes (member projection)" {
            let p = TVar("p", SBool)
            let q = TVar("q", SBool)
            Expect.isTrue
                (isDischarged
                    (discharge (mkGoal [] (Term.mkImplies (Term.mkAnd [p;q]) p))))
                "(P∧Q)⇒P"
        }

        test "(P ∧ Q) ⇒ Q closes (member projection)" {
            let p = TVar("p", SBool)
            let q = TVar("q", SBool)
            Expect.isTrue
                (isDischarged
                    (discharge (mkGoal [] (Term.mkImplies (Term.mkAnd [p;q]) q))))
                "(P∧Q)⇒Q"
        }

        test "hypothesis P, conclusion P closes" {
            let p = TVar("p", SBool)
            Expect.isTrue
                (isDischarged (discharge (mkGoal [p] p)))
                "{P} ⊢ P"
        }

        test "implication (P ∧ Q) ⇒ Q closes via flatten-on-adopt" {
            // The discharger flattens an `and` when adopting it as
            // the antecedent's hypothesis set.
            let p = TVar("p", SBool)
            let q = TVar("q", SBool)
            Expect.isTrue
                (isDischarged
                    (discharge (mkGoal [] (Term.mkImplies (Term.mkAnd [p;q]) q))))
                "(P∧Q) ⇒ Q"
        }

        test "conjunction of three reflexive equalities closes" {
            let x = TVar("x", SInt)
            let y = TVar("y", SInt)
            let z = TVar("z", SBool)
            let conj =
                Term.mkAnd
                    [ TBuiltin(BOpEq, [x; x])
                      TBuiltin(BOpEq, [y; y])
                      TBuiltin(BOpEq, [z; z]) ]
            Expect.isTrue
                (isDischarged (discharge (mkGoal [] conj)))
                "conj of refl"
        }
    ]

/// Counterexample-binding parser surface.
let private modelParseTests =
    testList "Verifier — parseModel coverage" [

        test "parseModel skips an empty model body" {
            let m = "sat\n(\n)\n"
            Expect.equal (parseModel m) [] "empty"
        }

        test "parseModel handles a single Int binding" {
            let m = """
sat
(
  (define-fun n () Int
    42)
)"""
            let bs = parseModel m
            Expect.equal (List.length bs) 1 "one"
            Expect.equal (List.head bs).Name  "n"   "name"
            Expect.equal (List.head bs).Sort  "Int" "sort"
            Expect.equal (List.head bs).Value "42"  "value"
        }

        test "parseModel handles a Bool binding" {
            let m = """
sat
(
  (define-fun b () Bool
    true)
)"""
            let bs = parseModel m
            Expect.equal (List.length bs) 1 "one"
            Expect.equal (List.head bs).Sort "Bool" "sort"
        }

        test "parseModel handles three bindings" {
            let m = """
sat
(
  (define-fun x () Int
    0)
  (define-fun y () Int
    1)
  (define-fun z () Int
    2)
)"""
            Expect.equal (List.length (parseModel m)) 3 "three"
        }

        test "parseModel returns empty for `unknown` blob" {
            Expect.equal (parseModel "unknown") [] "no bindings"
        }

        test "renderCounterexample renders pairs as `n : Sort = v`" {
            let bs =
                [ { Name = "x"; Sort = "Int"; Value = "0" }
                  { Name = "y"; Sort = "Int"; Value = "5" } ]
            let txt = renderCounterexample bs
            Expect.stringContains txt "x : Int = 0" "x"
            Expect.stringContains txt "y : Int = 5" "y"
        }

        test "renderCounterexample handles Bool sort" {
            let bs = [ { Name = "b"; Sort = "Bool"; Value = "true" } ]
            let txt = renderCounterexample bs
            Expect.stringContains txt "b : Bool = true" "b"
        }
    ]

/// Goal helpers + IR coverage.
let private vcirCoverageTests =
    testList "Verifier — IR construction coverage" [

        test "mkAnd of [] is the literal true" {
            Expect.equal (Term.mkAnd []) Term.trueT "empty"
        }

        test "mkOr of [] is the literal false" {
            Expect.equal (Term.mkOr []) Term.falseT "empty"
        }

        test "mkAnd of [x] returns x" {
            let x = TVar("x", SBool)
            Expect.equal (Term.mkAnd [x]) x "singleton"
        }

        test "mkOr of [x] returns x" {
            let x = TVar("x", SBool)
            Expect.equal (Term.mkOr [x]) x "singleton"
        }

        test "Term.isClosed on a literal is true" {
            Expect.isTrue (Term.isClosed (TLit(LInt 0L, SInt))) "literal closed"
        }

        test "Term.isClosed on a free variable is false" {
            Expect.isFalse (Term.isClosed (TVar("x", SInt))) "var open"
        }

        test "Term.isClosed on application of literals is true" {
            let t = TBuiltin(BOpAdd, [TLit(LInt 1L, SInt); TLit(LInt 2L, SInt)])
            Expect.isTrue (Term.isClosed t) "app closed"
        }

        test "Term.sortOf agrees on a Bool builtin" {
            let t = TBuiltin(BOpAnd, [Term.trueT; Term.falseT])
            Expect.equal (Term.sortOf t) SBool "and:Bool"
        }

        test "Term.sortOf agrees on an Int builtin" {
            let t = TBuiltin(BOpAdd, [TLit(LInt 1L, SInt); TLit(LInt 2L, SInt)])
            Expect.equal (Term.sortOf t) SInt "add:Int"
        }

        test "Term.sortOf reads the literal sort directly" {
            Expect.equal (Term.sortOf (TLit(LInt 1L, SInt))) SInt "lit"
        }

        test "Term.subst replaces a free variable" {
            let t = TBuiltin(BOpEq, [TVar("x", SInt); TLit(LInt 5L, SInt)])
            let env = Map.ofList [("x", TLit(LInt 7L, SInt))]
            let r = Term.subst env t
            Expect.equal r
                (TBuiltin(BOpEq, [TLit(LInt 7L, SInt); TLit(LInt 5L, SInt)]))
                "x↦7"
        }

        test "Term.subst leaves untouched bindings alone" {
            let t = TVar("y", SInt)
            let env = Map.ofList [("x", TLit(LInt 7L, SInt))]
            Expect.equal (Term.subst env t) t "y unchanged"
        }

        test "Goal.asImplication wraps a single hypothesis" {
            let p = TVar("p", SBool)
            let q = TVar("q", SBool)
            let g = mkGoal [p] q
            match Goal.asImplication g with
            | TBuiltin(BOpImplies, [_; _]) -> ()
            | _ -> failtest "expected implication"
        }

        test "Goal.asImplication wraps a conjunction of hypotheses" {
            let p = TVar("p", SBool)
            let q = TVar("q", SBool)
            let r = TVar("r", SBool)
            let g = mkGoal [p; q] r
            match Goal.asImplication g with
            | TBuiltin(BOpImplies, [_; _]) -> ()
            | _ -> failtest "expected implication"
        }

        test "Sort.display prints SBool as Bool" {
            Expect.equal (Sort.display SBool) "Bool" "Bool"
        }

        test "Sort.display prints SInt as Int" {
            Expect.equal (Sort.display SInt) "Int" "Int"
        }

        test "Sort.display prints SString as String" {
            Expect.equal (Sort.display SString) "String" "String"
        }

        test "GoalKind.display formats GKAssertion" {
            Expect.equal (GoalKind.display GKAssertion) "user assertion" "assert"
        }

        test "GoalKind.display formats GKLoopEstablish" {
            Expect.equal (GoalKind.display GKLoopEstablish)
                "loop invariant (establish)" "establish"
        }

        test "GoalKind.display formats GKLoopPreserve" {
            Expect.equal (GoalKind.display GKLoopPreserve)
                "loop invariant (preserve)" "preserve"
        }

        test "GoalKind.display formats GKLoopConclude" {
            Expect.equal (GoalKind.display GKLoopConclude)
                "loop invariant (conclude)" "conclude"
        }

        test "GoalKind.display formats GKPrecondition" {
            Expect.stringContains
                (GoalKind.display (GKPrecondition "f"))
                "precondition" "pre"
        }

        test "GoalKind.display formats GKPostcondition" {
            Expect.stringContains
                (GoalKind.display (GKPostcondition "f"))
                "postcondition" "post"
        }

        test "Builtin.display prints `+` for BOpAdd" {
            Expect.equal (Builtin.display BOpAdd) "+" "+"
        }

        test "Builtin.display prints `=` for BOpEq" {
            Expect.equal (Builtin.display BOpEq) "=" "="
        }

        test "Builtin.display prints `<=` for BOpLte" {
            Expect.equal (Builtin.display BOpLte) "<=" "<="
        }

        test "Builtin.display prints `not` for BOpNot" {
            Expect.equal (Builtin.display BOpNot) "not" "not"
        }
    ]

/// Mode-level option helpers.
let private optionsTests =
    testList "Verifier — ProveOptions defaults" [

        test "default AllowUnverified is false" {
            Expect.isFalse
                Driver.ProveOptions.defaults.AllowUnverified
                "default false"
        }

        test "explicit AllowUnverified=false matches default" {
            let opts = { Driver.ProveOptions.AllowUnverified = false }
            Expect.equal opts Driver.ProveOptions.defaults "match"
        }

        test "explicit AllowUnverified=true reads back true" {
            let opts = { Driver.ProveOptions.AllowUnverified = true }
            Expect.isTrue opts.AllowUnverified "true"
        }
    ]

/// Sort/builtin coverage matrix.
let private sortCoverageTests =
    testList "Verifier — Sort and Builtin display" [

        test "Sort.display formats SBitVec[8]" {
            Expect.equal (Sort.display (SBitVec 8)) "BitVec[8]" "bv8"
        }

        test "Sort.display formats SBitVec[32]" {
            Expect.equal (Sort.display (SBitVec 32)) "BitVec[32]" "bv32"
        }

        test "Sort.display formats SBitVec[64]" {
            Expect.equal (Sort.display (SBitVec 64)) "BitVec[64]" "bv64"
        }

        test "Sort.display formats SFloat32" {
            Expect.equal (Sort.display SFloat32) "Float32" "f32"
        }

        test "Sort.display formats SFloat64" {
            Expect.equal (Sort.display SFloat64) "Float64" "f64"
        }

        test "Sort.display formats SDatatype with no args" {
            Expect.equal (Sort.display (SDatatype("Pair", []))) "Pair" "Pair"
        }

        test "Sort.display formats SDatatype with one arg" {
            Expect.equal
                (Sort.display (SDatatype("Box", [SInt])))
                "Box[Int]"
                "Box[Int]"
        }

        test "Sort.display formats SDatatype with two args" {
            Expect.equal
                (Sort.display (SDatatype("Pair", [SInt; SBool])))
                "Pair[Int, Bool]"
                "Pair[Int, Bool]"
        }

        test "Sort.display formats SSlice[Int]" {
            Expect.equal (Sort.display (SSlice SInt)) "Slice[Int]" "slice"
        }

        test "Sort.display formats SUninterp" {
            Expect.equal (Sort.display (SUninterp "Bag")) "Bag" "Bag"
        }

        test "Builtin.display formats `or`" {
            Expect.equal (Builtin.display BOpOr) "or" "or"
        }

        test "Builtin.display formats `xor`" {
            Expect.equal (Builtin.display BOpXor) "xor" "xor"
        }

        test "Builtin.display formats `=>`" {
            Expect.equal (Builtin.display BOpImplies) "=>" "implies"
        }

        test "Builtin.display formats `<`" {
            Expect.equal (Builtin.display BOpLt) "<" "lt"
        }

        test "Builtin.display formats `>`" {
            Expect.equal (Builtin.display BOpGt) ">" "gt"
        }

        test "Builtin.display formats `>=`" {
            Expect.equal (Builtin.display BOpGte) ">=" "gte"
        }

        test "Builtin.display formats `*`" {
            Expect.equal (Builtin.display BOpMul) "*" "*"
        }

        test "Builtin.display formats `div`" {
            Expect.equal (Builtin.display BOpDiv) "div" "div"
        }

        test "Builtin.display formats `mod`" {
            Expect.equal (Builtin.display BOpMod) "mod" "mod"
        }

        test "Builtin.display formats `ite`" {
            Expect.equal (Builtin.display BOpIte) "ite" "ite"
        }

        test "Builtin.display formats `slice.length`" {
            Expect.equal (Builtin.display BOpSliceLength) "slice.length" "len"
        }

        test "Builtin.display formats `slice.select`" {
            Expect.equal (Builtin.display BOpSliceIndex) "slice.select" "idx"
        }
    ]

/// More driver positive coverage — additional small shapes that close
/// trivially.
let private morePositiveDriverTests =
    testList "Verifier — more positive driver regressions" [

        test "ensures with `and` between two reflexive facts" {
            let src = """
                @proof_required
                package P
                pub func f(x: Int): Int
                  ensures: result == x and result == x
                  = x
                """
            Expect.isFalse (ProofSummary.hasFailure (prove src)) "ok"
        }

        test "ensures with `and` between three reflexive facts" {
            let src = """
                @proof_required
                package P
                pub func f(x: Int): Int
                  ensures: result == x and x == x and result == x
                  = x
                """
            Expect.isFalse (ProofSummary.hasFailure (prove src)) "ok"
        }

        test "result == x assertEq with let intermediate" {
            let src = """
                @proof_required
                package P
                pub func f(x: Int): Int
                  ensures: result == x
                {
                  let y = x
                  assert(y == x)
                  return y
                }
                """
            let s = prove src
            Expect.equal (ProofSummary.totalCount s) 2 "post + assert"
        }

        test "result == y on val-bound y == x" {
            let src = """
                @proof_required
                package P
                pub func f(x: Int): Int
                  ensures: result == x
                {
                  val y = x
                  return y
                }
                """
            Expect.isFalse (ProofSummary.hasFailure (prove src)) "ok"
        }

        test "Unit-returning func with empty body discharges trivially" {
            let src = """
                @proof_required
                package P
                pub func f(): Unit { }
                """
            Expect.isFalse (ProofSummary.hasFailure (prove src)) "ok"
        }

        test "Two no-op functions both close" {
            let src = """
                @proof_required
                package P
                pub func a(x: Int): Int { return x }
                pub func b(y: Int): Int { return y }
                """
            Expect.isFalse (ProofSummary.hasFailure (prove src)) "ok"
        }

        test "Three identity-shape functions all close" {
            let src = """
                @proof_required
                package P
                pub func a(x: Int): Int
                  ensures: result == x
                  = x
                pub func b(x: Int): Int
                  ensures: result == x
                  = x
                pub func c(x: Int): Int
                  ensures: result == x
                  = x
                """
            let s = prove src
            Expect.equal (ProofSummary.totalCount s) 3 "three"
            Expect.equal (ProofSummary.dischargedCount s) 3 "all"
        }

        test "loop ten with invariant: true and result discharge" {
            let src = """
                @proof_required
                package P
                pub func f(): Bool
                  ensures: result == true
                {
                  var i: Int = 0
                  while i < 10
                    invariant: true
                  {
                    i = i + 1
                  }
                  return true
                }
                """
            let s = prove src
            Expect.isFalse (ProofSummary.hasFailure s) "ok"
        }

        test "two-iteration loop discharges with invariant: true" {
            let src = """
                @proof_required
                package P
                pub func f(): Int
                {
                  var i: Int = 0
                  while i < 2
                    invariant: true
                  {
                    i = i + 1
                  }
                  return i
                }
                """
            Expect.isFalse (ProofSummary.hasFailure (prove src)) "ok"
        }

        test "loop with constant body assignment discharges" {
            let src = """
                @proof_required
                package P
                pub func f(): Int
                {
                  var i: Int = 0
                  while i < 1
                    invariant: true
                  {
                    i = 1
                  }
                  return i
                }
                """
            Expect.isFalse (ProofSummary.hasFailure (prove src)) "ok"
        }

        test "ensures result == x compositional through let chain" {
            let src = """
                @proof_required
                package P
                pub func f(x: Int): Int
                  ensures: result == x
                {
                  let a = x
                  let b = a
                  let c = b
                  let d = c
                  return d
                }
                """
            Expect.isFalse (ProofSummary.hasFailure (prove src)) "ok"
        }

        test "two-arg identity shape discharges with second result" {
            let src = """
                @proof_required
                package P
                pub func f(a: Int, b: Int): Int
                  ensures: result == b
                  = b
                """
            Expect.isFalse (ProofSummary.hasFailure (prove src)) "ok"
        }

        test "Bool identity in proof_required code" {
            let src = """
                @proof_required
                package P
                pub func f(b: Bool): Bool
                  ensures: result == b
                  = b
                """
            Expect.isFalse (ProofSummary.hasFailure (prove src)) "ok"
        }

        test "String identity in proof_required code" {
            let src = """
                @proof_required
                package P
                pub func f(s: String): String
                  ensures: result == s
                  = s
                """
            Expect.isFalse (ProofSummary.hasFailure (prove src)) "ok"
        }

        test "Long identity in proof_required code" {
            let src = """
                @proof_required
                package P
                pub func f(n: Long): Long
                  ensures: result == n
                  = n
                """
            Expect.isFalse (ProofSummary.hasFailure (prove src)) "ok"
        }

        test "ProofSummary.totalCount on a Discharged result equals goal count" {
            let src = """
                @proof_required
                package P
                pub func a(x: Int): Int
                  ensures: result == x
                  = x
                pub func b(x: Int): Int
                  ensures: result == x
                  = x
                """
            Expect.equal (ProofSummary.totalCount (prove src)) 2 "two"
        }

        test "wrapper of identity discharges" {
            let src = """
                @proof_required
                package P
                pub func id(x: Int): Int
                  ensures: result == x
                { return x }
                pub func wrap(x: Int): Int
                  ensures: result == x
                { return id(x) }
                """
            Expect.isFalse (ProofSummary.hasFailure (prove src)) "ok"
        }
    ]

let tests =
    testList "Verifier — M4.2 close-out regressions" [
        positiveDriverTests
        morePositiveDriverTests
        negativeDriverTests
        smtTests
        dischargerTests
        modelParseTests
        vcirCoverageTests
        sortCoverageTests
        optionsTests
    ]
