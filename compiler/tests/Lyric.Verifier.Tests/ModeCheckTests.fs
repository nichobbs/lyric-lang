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
    ]
