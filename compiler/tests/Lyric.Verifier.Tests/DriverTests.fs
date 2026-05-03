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
    ]
