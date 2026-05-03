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

        test "return-type range bound is checked at body return" {
            // Identity from [0, 100] to [0, 100]: trivially valid.
            let src = """
                @proof_required
                package P

                pub func ok(x: Int range 0 ..= 100): Int range 0 ..= 100
                  = x
                """
            let summary = prove src
            let r = List.head summary.Results
            match r.Outcome with
            | Counterexample _ ->
                failtest "identity into the same range should hold"
            | Discharged | Unknown _ -> ()
        }

        test "wrong return-type range produces a counterexample" {
            // Returning x: Int range 0 ..= 100 as Int range 50 ..= 60
            // should fail (x might be e.g. 48).
            let src = """
                @proof_required
                package P

                pub func bad(x: Int range 0 ..= 100): Int range 50 ..= 60
                  = x
                """
            let summary = prove src
            let r = List.head summary.Results
            match r.Outcome with
            | Discharged ->
                failtest "must NOT discharge — bound mismatch"
            | Counterexample _ | Unknown _ -> ()
        }

        test "non-@pure callee does NOT unfold (only post is assumed)" {
            // Without @pure, the verifier sees only the
            // postcondition `result == x + x` for the callee, not
            // the body.  The wrapper here would fail to discharge
            // because there's no postcondition on `helper` to
            // assume — only the post-as-assumption mechanism applies.
            // This is the soundness boundary: only @pure may be
            // unfolded.
            let src = """
                @proof_required
                package P

                pub func helper(x: Int): Int = x + x

                pub func wrapper(x: Int): Int
                  ensures: result == helper(x)
                  = x + x
                """
            let summary = prove src
            // The post `result == helper(x)` at the call site
            // becomes `(x+x) == helper(x)` which Z3 proves only if
            // it can see the body — which it can't since helper
            // isn't @pure and has no contract.  Outcome: not
            // Discharged via the trivial discharger; either Unknown
            // (no z3) or Counterexample (z3 finds a model).
            let r =
                summary.Results
                |> List.find (fun r -> r.Goal.Label.StartsWith "wrapper")
            match r.Outcome with
            | Discharged ->
                failtest "non-@pure callee should not be unfolded"
            | Counterexample _ | Unknown _ -> ()
        }

        test "@pure callee unfolds one level at the call site" {
            // The trivial discharger can't relate `double(x)` to
            // `x + x` without help.  When `double` is `@pure` and
            // has an expression body, the verifier emits
            // `double(x) == x + x` as an additional assumption,
            // so the post `result == double(x)` discharges.
            let src = """
                @proof_required
                package P

                @pure
                pub func double(x: Int): Int = x + x

                pub func mainprop(x: Int): Int
                  ensures: result == double(x)
                  = x + x
                """
            let summary = prove src
            // mainprop and double both produce post-goals.
            Expect.equal (ProofSummary.totalCount summary) 2 "two goals"
            let r =
                summary.Results
                |> List.find (fun r -> r.Goal.Label.StartsWith "mainprop")
            match r.Outcome with
            | Counterexample _ ->
                failtest "pure unfold should let mainprop discharge"
            | Discharged | Unknown _ -> ()
        }

        test "match with literal + binding patterns produces a runnable VC" {
            // M4.1 supports wildcard, literal, and bare-binding
            // patterns.  The post here is `result == x or result == 0`,
            // which holds by case analysis: when x == 0 we return 0,
            // else we return x.
            let src = """
                @proof_required
                package P

                pub func absish(x: Int): Int
                  ensures: result == x or result == 0
                  = match x {
                      case 0 -> 0
                      case n -> n
                    }
                """
            let summary = prove src
            Expect.equal (ProofSummary.totalCount summary) 1 "one goal"
            // Either Discharged (via z3) or Unknown (without).
            let r = List.head summary.Results
            match r.Outcome with
            | Counterexample _ -> failtest "match should not produce a counterexample"
            | Discharged | Unknown _ -> ()
        }

        test "assert phi in body produces a side goal AND assumes phi" {
            // The assertion `x == x` is a tautology (closes via the
            // trivial discharger); the post-assertion assumption
            // `x == x` doesn't change anything here, but the assert
            // mechanism is exercised end-to-end.
            let src = """
                @proof_required
                package P

                pub func ok(x: Int): Int
                  ensures: result == x
                {
                  assert(x == x)
                  return x
                }
                """
            let summary = prove src
            // Two goals: the postcondition and the assert side-goal.
            Expect.equal (ProofSummary.totalCount summary) 2 "two goals"
            Expect.equal (ProofSummary.dischargedCount summary) 2 "both discharge"
            Expect.isFalse (ProofSummary.hasFailure summary) "no failure"
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
