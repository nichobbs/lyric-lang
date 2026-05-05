module Lyric.Verifier.Tests.ModeCheckTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Parser
open Lyric.Verifier.ModeCheck

let private parseAndCheck (src: string) =
    let parsed = parse src
    Expect.isFalse (parsed.Diagnostics
                    |> List.exists (fun d -> d.Severity = DiagError))
                   (sprintf "expected clean parse:\n%A" parsed.Diagnostics)
    checkFile parsed.File

let private hasDiag (code: string) (diags: Diagnostic list) =
    diags |> List.exists (fun d -> d.Code = code)

let tests =
    testList "Verifier — ModeCheck (V0001/V0002/V0004/V0005)" [

        test "@runtime_checked package emits no mode diagnostics" {
            let src = """
                @runtime_checked
                package P

                pub func f(x: Int): Int { return x }
                """
            let _, diags = parseAndCheck src
            Expect.isEmpty diags "no diagnostics for runtime-checked"
        }

        test "@proof_required calling internal proof-required is fine" {
            let src = """
                @proof_required
                package P

                pub func helper(x: Int): Int { return x }
                pub func wrapper(x: Int): Int { return helper(x) }
                """
            let _, diags = parseAndCheck src
            Expect.isFalse (hasDiag "V0002" diags)
                "intra-package proof-required calls are admissible"
        }

        test "@axiom function with body is V0004" {
            let src = """
                @proof_required
                package P

                @axiom
                pub func bad(x: Int): Int { return x }
                """
            let _, diags = parseAndCheck src
            Expect.isTrue (hasDiag "V0004" diags) "expected V0004"
        }

        test "@axiom function without body is fine" {
            let src = """
                @proof_required
                package P

                @axiom
                pub func ok(x: Int): Int
                """
            let _, diags = parseAndCheck src
            Expect.isFalse (hasDiag "V0004" diags) "no V0004 for body-less @axiom"
        }

        test "loop in proof-required function is V0005" {
            let src = """
                @proof_required
                package P

                pub func loopy(): Int {
                  var i: Int = 0
                  while i < 10 { i = i + 1 }
                  return i
                }
                """
            let _, diags = parseAndCheck src
            Expect.isTrue (hasDiag "V0005" diags) "expected V0005"
        }

        test "forall over Int in proof-required code is V0006" {
            let src = """
                @proof_required
                package P

                pub func bad(x: Int): Int
                  ensures: forall (k: Int) { k == k }
                {
                  return x
                }
                """
            let _, diags = parseAndCheck src
            Expect.isTrue (hasDiag "V0006" diags) "expected V0006"
        }

        test "forall over a slice in proof-required code is fine" {
            let src = """
                @proof_required
                package P

                pub func ok(xs: slice[Int]): Int
                  ensures: forall (k: slice[Int]) { true }
                {
                  return 0
                }
                """
            let _, diags = parseAndCheck src
            Expect.isFalse (hasDiag "V0006" diags) "no V0006 for slice quantifier"
        }

        test "forall over a Bool is admissible" {
            let src = """
                @proof_required
                package P

                pub func ok(x: Bool): Bool
                  ensures: forall (b: Bool) { b or not b }
                {
                  return x
                }
                """
            let _, diags = parseAndCheck src
            Expect.isFalse (hasDiag "V0006" diags) "no V0006 for Bool quantifier"
        }

        test "exists over Int in proof-required code is also V0006" {
            let src = """
                @proof_required
                package P

                pub func bad(x: Int): Bool
                  ensures: exists (k: Int) { k == x }
                {
                  return true
                }
                """
            let _, diags = parseAndCheck src
            Expect.isTrue (hasDiag "V0006" diags) "V0006 also fires on exists"
        }

        test "nested forall with one bounded and one unbounded binder is V0006" {
            let src = """
                @proof_required
                package P

                pub func bad(xs: slice[Int]): Bool
                  ensures: forall (xs: slice[Int], k: Int) { k == k }
                {
                  return true
                }
                """
            let _, diags = parseAndCheck src
            Expect.isTrue (hasDiag "V0006" diags) "unbounded k in nested forall"
        }

        test "@runtime_checked package admits unbounded quantifiers" {
            // V0006 only fires inside proof-required modules.
            let src = """
                @runtime_checked
                package P

                pub func f(x: Int): Int
                  ensures: forall (k: Int) { k == k }
                {
                  return x
                }
                """
            let _, diags = parseAndCheck src
            Expect.isFalse (hasDiag "V0006" diags) "runtime-checked is unrestricted"
        }

        test "[V0003] unsafe block in non-unsafe-allowed package is an error" {
            let src = """
                @proof_required
                package P

                pub func f(x: Int): Int {
                  unsafe { assert(x > 0) }
                  return x
                }
                """
            let parsed = parse src
            let _, diags = checkFile parsed.File
            Expect.isTrue (hasDiag "V0003" diags) "V0003 emitted"
        }

        test "[V0003] unsafe block allowed in unsafe_blocks_allowed package" {
            let src = """
                @proof_required(unsafe_blocks_allowed)
                package P

                pub func f(x: Int): Int {
                  unsafe { assert(x > 0) }
                  return x
                }
                """
            let parsed = parse src
            let _, diags = checkFile parsed.File
            Expect.isFalse (hasDiag "V0003" diags) "no V0003 in unsafe-allowed mode"
        }

        test "[V0009] assume outside unsafe block is an error" {
            let src = """
                @proof_required
                package P

                pub func f(x: Int): Int {
                  assume(x > 0)
                  return x
                }
                """
            let parsed = parse src
            let _, diags = checkFile parsed.File
            Expect.isTrue (hasDiag "V0009" diags) "V0009 emitted"
        }

        test "[V0009] assume inside unsafe block is allowed" {
            let src = """
                @proof_required(unsafe_blocks_allowed)
                package P

                pub func f(x: Int): Int {
                  unsafe { assume(x > 0) }
                  return x
                }
                """
            let parsed = parse src
            let _, diags = checkFile parsed.File
            Expect.isFalse (hasDiag "V0009" diags) "no V0009 inside unsafe block"
        }
    ]
