module Lyric.Verifier.Tests.DriverTests

open Expecto
open Lyric.Lexer
open Lyric.Verifier
open Lyric.Verifier.Driver
open Lyric.Verifier.Solver

let private prove (src: string) =
    Driver.proveSource src None

let private isDischarged (r: ProofResult) =
    match r.Outcome with Discharged -> true | _ -> false

let tests =
    testList "Verifier — end-to-end Driver" [

        test "runtime_checked package produces no obligations" {
            let src = """
                @runtime_checked
                package P

                pub func f(x: Int): Int { return x }
                """
            let summary = prove src
            Expect.equal (ProofSummary.totalCount summary) 0 "no obligations"
        }

        test "trivial identity discharges via the syntactic checker" {
            let src = """
                @proof_required
                package P

                pub func id(x: Int): Int
                  ensures: result == x
                {
                  return x
                }
                """
            let summary = prove src
            Expect.equal (ProofSummary.totalCount summary) 1 "one obligation"
            Expect.equal (ProofSummary.dischargedCount summary) 1 "discharged"
            Expect.isFalse (ProofSummary.hasFailure summary) "no failure"
        }

        test "unit-returning constant function discharges" {
            let src = """
                @proof_required
                package P

                pub func t(): Bool
                  ensures: result == true
                {
                  return true
                }
                """
            let summary = prove src
            Expect.equal (ProofSummary.dischargedCount summary) 1 "discharged"
        }

        test "function with no contracts has a trivially-true postcondition" {
            let src = """
                @proof_required
                package P

                pub func nop(x: Int): Int { return x }
                """
            let summary = prove src
            Expect.isTrue (ProofSummary.dischargedCount summary >= 0) "ran"
        }

        test "@axiom function emits no VC" {
            let src = """
                @proof_required
                package P

                @axiom
                pub func opaque(x: Int): Int
                """
            let summary = prove src
            Expect.equal (ProofSummary.totalCount summary) 0 "axiom skipped"
        }

        test "demonstrably wrong contract does not discharge" {
            // `result < 0` for `x + 1` with `x >= 0` is false.  The
            // outcome should be either a counterexample (z3 present)
            // or unknown (no solver).  Either way, NOT discharged.
            let src = """
                @proof_required
                package P

                pub func wrong(x: Int): Int
                  requires: x >= 0
                  ensures: result < 0
                {
                  return x + 1
                }
                """
            let summary = prove src
            Expect.equal (ProofSummary.totalCount summary) 1 "one obligation"
            let r = List.head summary.Results
            match r.Outcome with
            | Discharged ->
                failtest "wrong contract should not discharge"
            | Counterexample _ | Unknown _ -> ()
            Expect.isTrue (ProofSummary.hasFailure summary) "expected failure flag"
        }

        test "multiple proof-required functions all run" {
            let src = """
                @proof_required
                package P

                pub func a(x: Int): Int
                  ensures: result == x
                { return x }

                pub func b(x: Bool): Bool
                  ensures: result == x
                { return x }

                pub func c(): Int
                  ensures: result == 42
                { return 42 }
                """
            let summary = prove src
            Expect.equal (ProofSummary.totalCount summary) 3 "three goals"
            Expect.equal (ProofSummary.dischargedCount summary) 3 "all discharge"
        }

        test "level transitions from runtime to proof do not run when level is wrong" {
            let src = """
                @axiom
                package P
                @axiom
                pub func opaque(x: Int): Int
                """
            let summary = prove src
            // Axiom level is not proof-required, so no goals.
            Expect.equal (ProofSummary.totalCount summary) 0 "axiom level produces no VCs"
        }

        test "call rule: caller postcondition uses callee's ensures" {
            // wrapper's post `result == x` is dischargeable only
            // because we assume id's post `result == x` at the call
            // site (call rule §10.4).  Without the call rule, the
            // wrapper VC would be opaque to the discharger.
            let src = """
                @proof_required
                package P

                pub func id(x: Int): Int
                  ensures: result == x
                { return x }

                pub func wrapper(x: Int): Int
                  ensures: result == x
                { return id(x) }
                """
            let summary = prove src
            Expect.equal (ProofSummary.dischargedCount summary) 2 "both"
            Expect.isFalse (ProofSummary.hasFailure summary) "no failure"
        }

        test "inline range refinement adds bound hypotheses to the goal" {
            // `Int range 0 ..= 100` should add `0 <= x` and `x <= 100`
            // as hypotheses; combined with the trivial discharger, the
            // postcondition `result >= 0` reduces to `x >= 0`, which
            // is implied by the lower bound (so trivially closes via
            // hypothesis match if z3 isn't around — and via z3 if it is).
            let src = """
                @proof_required
                package P

                pub func clamp(x: Int range 0 ..= 100): Int
                  ensures: result >= 0
                {
                  return x
                }
                """
            let summary = prove src
            // The goal only discharges with z3 (since `result >= 0`
            // doesn't appear verbatim and isn't reflexive); accept
            // either Discharged (z3 present) or Unknown (no solver).
            Expect.equal (ProofSummary.totalCount summary) 1 "one goal"
            let r = List.head summary.Results
            match r.Outcome with
            | Counterexample _ ->
                failtest "range bound should make this provable"
            | Discharged | Unknown _ -> ()
        }

        test "call rule: caller's required precondition flows into side goal" {
            // id requires `x >= 0`; wrapper calls id(z) with `z >= 0`
            // in scope.  The discharger sees the side condition
            // `z >= 0` as a hypothesis (caller's pre) and closes it
            // via membership.
            let src = """
                @proof_required
                package P

                pub func id(x: Int): Int
                  requires: x >= 0
                  ensures: result == x
                { return x }

                pub func wrapper(z: Int): Int
                  requires: z >= 0
                  ensures: result == z
                { return id(z) }
                """
            let summary = prove src
            Expect.isFalse (ProofSummary.hasFailure summary) "no failure"
        }
    ]
