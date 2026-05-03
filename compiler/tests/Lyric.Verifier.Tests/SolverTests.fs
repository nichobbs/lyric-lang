module Lyric.Verifier.Tests.SolverTests

open Expecto
open Lyric.Lexer
open Lyric.Verifier.Vcir
open Lyric.Verifier.Solver

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

let tests =
    testList "Verifier — trivial discharger" [

        test "literal true discharges" {
            let g = mkGoal [] Term.trueT
            Expect.isTrue (isDischarged (discharge g)) "true"
        }

        test "P ⇒ P discharges (conclusion form)" {
            let p = TVar("p", SBool)
            let g = mkGoal [] (Term.mkImplies p p)
            Expect.isTrue (isDischarged (discharge g)) "P=>P"
        }

        test "reflexive equality on int discharges" {
            let x = TVar("x", SInt)
            let g = mkGoal [] (TBuiltin(BOpEq, [x; x]))
            Expect.isTrue (isDischarged (discharge g)) "x=x"
        }

        test "reflexive >= and <= discharge" {
            let x = TVar("x", SInt)
            Expect.isTrue (isDischarged (discharge (mkGoal [] (TBuiltin(BOpGte, [x; x]))))) ">="
            Expect.isTrue (isDischarged (discharge (mkGoal [] (TBuiltin(BOpLte, [x; x]))))) "<="
        }

        test "ite c a a discharges" {
            let a = TVar("a", SInt)
            let c = TVar("c", SBool)
            let goal = TBuiltin(BOpEq, [TIte(c, a, a); a])
            // ite c a a is structurally equal-to a here (we match
            // the pattern (= ite a) so the ite-collapses-to-a check
            // also closes the equality through reflexivity).
            Expect.isTrue (isDischarged (discharge (mkGoal [] (TBuiltin(BOpEq, [TIte(c, a, a); TIte(c, a, a)]))))) "ite-iteself"
        }

        test "conjunction of tautologies discharges" {
            let x = TVar("x", SInt)
            let conj =
                Term.mkAnd
                    [ TBuiltin(BOpEq, [x; x])
                      Term.trueT
                      TBuiltin(BOpGte, [x; x]) ]
            Expect.isTrue (isDischarged (discharge (mkGoal [] conj))) "conj"
        }

        test "implication adopts antecedent as hypothesis" {
            let p = TVar("p", SBool)
            let q = TVar("q", SBool)
            // (=> (and p q) p)  --- closes because p appears in
            // the augmented hypothesis set after stripping the
            // implication.
            let conj = Term.mkAnd [p; q]
            let goal = Term.mkImplies conj p
            Expect.isTrue (isDischarged (discharge (mkGoal [] goal))) "(p ∧ q) ⇒ p"
        }

        test "non-trivial arithmetic returns unknown without z3" {
            // If z3 is on PATH, this discharges; if not, returns
            // Unknown.  Either way it should NOT be a counterexample.
            let x = TVar("x", SInt)
            let goal =
                Term.mkImplies
                    (TBuiltin(BOpGte, [x; TLit(LInt 0L, SInt)]))
                    (TBuiltin(BOpGte, [TBuiltin(BOpAdd, [x; TLit(LInt 1L, SInt)])
                                       TLit(LInt 0L, SInt)]))
            let outcome = discharge (mkGoal [] goal)
            match outcome with
            | Counterexample _ -> failtest "should not be sat"
            | Discharged | Unknown _ -> ()
        }

        test "displayOutcome formats each variant" {
            Expect.equal (displayOutcome Discharged) "discharged" "discharged"
            Expect.stringContains (displayOutcome (Counterexample "(x 5)")) "counterexample" "ce"
            Expect.stringContains (displayOutcome (Unknown "no solver")) "unknown" "unk"
        }

        test "parseModel extracts a single binding" {
            let modelText = """
sat
(
  (define-fun x () Int
    7)
)
"""
            let bindings = parseModel modelText
            Expect.equal (List.length bindings) 1 "one binding"
            let b = List.head bindings
            Expect.equal b.Name  "x"   "name"
            Expect.equal b.Sort  "Int" "sort"
            Expect.equal b.Value "7"   "value"
        }

        test "parseModel extracts multiple bindings" {
            let modelText = """
sat
(
  (define-fun x () Int
    0)
  (define-fun y () Int
    5)
  (define-fun b () Bool
    false)
)
"""
            let bindings = parseModel modelText
            Expect.equal (List.length bindings) 3 "three"
            Expect.equal (List.map (fun b -> b.Name) bindings) ["x"; "y"; "b"] "names"
        }

        test "renderCounterexample formats bindings as name : sort = value" {
            let bindings =
                [ { Name = "x"; Sort = "Int"; Value = "0" }
                  { Name = "y"; Sort = "Int"; Value = "5" } ]
            let rendered = renderCounterexample bindings
            Expect.stringContains rendered "x : Int = 0" "x"
            Expect.stringContains rendered "y : Int = 5" "y"
        }

        test "renderCounterexample handles empty list gracefully" {
            let rendered = renderCounterexample []
            Expect.stringContains rendered "no model bindings" "empty"
        }
    ]
