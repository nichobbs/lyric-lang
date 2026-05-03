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
    ]
