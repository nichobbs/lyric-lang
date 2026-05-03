module Lyric.Verifier.Tests.VcirTests

open Expecto
open Lyric.Lexer
open Lyric.Verifier.Vcir

let tests =
    testList "Verifier — Vcir IR" [

        test "mkAnd of empty list is true" {
            Expect.equal (Term.mkAnd []) (TLit(LBool true, SBool)) "true"
        }

        test "mkAnd of singleton is the element" {
            let t = TVar("x", SBool)
            Expect.equal (Term.mkAnd [t]) t "singleton"
        }

        test "mkOr of empty list is false" {
            Expect.equal (Term.mkOr []) (TLit(LBool false, SBool)) "false"
        }

        test "subst replaces a free variable" {
            let term = TBuiltin(BOpEq, [TVar("x", SInt); TLit(LInt 5L, SInt)])
            let env = Map.ofList [("x", TLit(LInt 7L, SInt))]
            let result = Term.subst env term
            let expected = TBuiltin(BOpEq, [TLit(LInt 7L, SInt); TLit(LInt 5L, SInt)])
            Expect.equal result expected "x replaced by 7"
        }

        test "subst skips bound variables in forall" {
            let inner = TBuiltin(BOpEq, [TVar("x", SInt); TVar("y", SInt)])
            let term = TForall([("x", SInt)], [], inner)
            let env = Map.ofList [("x", TLit(LInt 0L, SInt))]
            let result = Term.subst env term
            // The forall-bound x is shadowed; only free y could be substituted
            // (and y isn't in env), so result should equal term.
            Expect.equal result term "forall-bound x is unchanged"
        }

        test "Goal.asImplication wraps hypotheses" {
            let g =
                { Hypotheses = [ TVar("p", SBool) ]
                  Conclusion = TVar("q", SBool)
                  Symbols    = []
                  Origin     = Span.pointAt Position.initial
                  Kind       = GKAssertion
                  Label      = "t" }
            let imp = Goal.asImplication g
            match imp with
            | TBuiltin(BOpImplies, [_; _]) -> ()
            | _ -> failtest "expected an implication"
        }
    ]
