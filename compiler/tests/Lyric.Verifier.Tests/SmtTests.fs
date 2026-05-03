module Lyric.Verifier.Tests.SmtTests

open Expecto
open Lyric.Lexer
open Lyric.Verifier.Vcir
open Lyric.Verifier.Smt

let private spanZero = Span.pointAt Position.initial

let tests =
    testList "Verifier — SMT-LIB v2.6 emission" [

        test "renderGoal emits set-logic header" {
            let g =
                { Hypotheses = []
                  Conclusion = TLit(LBool true, SBool)
                  Symbols    = []
                  Origin     = spanZero
                  Kind       = GKAssertion
                  Label      = "trivial" }
            let smt = renderGoal g
            Expect.stringContains smt "(set-logic ALL)" "set-logic"
            Expect.stringContains smt "(check-sat)"     "check-sat"
            Expect.stringContains smt "(get-model)"     "get-model"
            Expect.stringContains smt "(declare-datatypes ((Unit 0))" "Unit datatype"
        }

        test "free variables become declare-const" {
            let g =
                { Hypotheses = [ TBuiltin(BOpLte, [TLit(LInt 0L, SInt); TVar("x", SInt)]) ]
                  Conclusion = TBuiltin(BOpGte, [TVar("x", SInt); TLit(LInt 0L, SInt)])
                  Symbols    = []
                  Origin     = spanZero
                  Kind       = GKAssertion
                  Label      = "x-bound" }
            let smt = renderGoal g
            Expect.stringContains smt "(declare-const x Int)" "x declared"
        }

        test "user functions become declare-fun" {
            let g =
                { Hypotheses = []
                  Conclusion = TLit(LBool true, SBool)
                  Symbols    = [ UserFun("amount", [SInt], SInt) ]
                  Origin     = spanZero
                  Kind       = GKAssertion
                  Label      = "fun" }
            let smt = renderGoal g
            Expect.stringContains smt "(declare-fun amount (Int) Int)" "amount fn"
        }

        test "negated implication wraps the claim" {
            let g =
                { Hypotheses = [TVar("p", SBool)]
                  Conclusion = TVar("p", SBool)
                  Symbols    = []
                  Origin     = spanZero
                  Kind       = GKAssertion
                  Label      = "self" }
            let smt = renderGoal g
            Expect.stringContains smt "(assert (not " "wraps in not"
        }

        test "ite term renders with three operands" {
            let g =
                { Hypotheses = []
                  Conclusion = TIte(TVar("c", SBool),
                                    TLit(LInt 1L, SInt),
                                    TLit(LInt 0L, SInt))
                  Symbols    = []
                  Origin     = spanZero
                  Kind       = GKAssertion
                  Label      = "ite" }
            let smt = renderGoal g
            Expect.stringContains smt "(ite c 1 0)" "ite shape"
        }

        test "negative integer literal renders with the (-) operator" {
            let g =
                { Hypotheses = []
                  Conclusion = TBuiltin(BOpEq, [TVar("x", SInt); TLit(LInt -7L, SInt)])
                  Symbols    = []
                  Origin     = spanZero
                  Kind       = GKAssertion
                  Label      = "neg" }
            let smt = renderGoal g
            Expect.stringContains smt "(- 7)" "negative literal"
        }

        test "forall renders with binders and body" {
            let g =
                { Hypotheses = []
                  Conclusion = TForall(
                                  [("k", SInt)],
                                  [],
                                  TBuiltin(BOpEq, [TVar("k", SInt); TVar("k", SInt)]))
                  Symbols    = []
                  Origin     = spanZero
                  Kind       = GKAssertion
                  Label      = "forall" }
            let smt = renderGoal g
            Expect.stringContains smt "(forall ((k Int))" "forall header"
            Expect.stringContains smt "(= k k)" "body"
        }

        test "datatype symbols emit declare-datatypes" {
            let g =
                { Hypotheses = []
                  Conclusion = TLit(LBool true, SBool)
                  Symbols    = [ Datatype("Pair", [("Mk", [("fst", SInt); ("snd", SInt)])]) ]
                  Origin     = spanZero
                  Kind       = GKAssertion
                  Label      = "dt" }
            let smt = renderGoal g
            Expect.stringContains smt "(declare-datatypes ((Pair 0))" "datatype"
            Expect.stringContains smt "(Mk (fst Int) (snd Int))" "ctor"
        }
    ]
