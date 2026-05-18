module Lyric.TypeChecker.Tests.StmtCheckerTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser
open Lyric.TypeChecker
open Lyric.TypeChecker.Checker

let private parseAndCheck (src: string) : CheckResult =
    let parsed = parse ("package P\n" + src)
    Expect.isEmpty parsed.Diagnostics
        (sprintf "expected clean parse for: %s\nactual: %A" src parsed.Diagnostics)
    check parsed.File

let private codes (r: CheckResult) : string list =
    r.Diagnostics |> List.map (fun d -> d.Code)

let tests =
    testList "T5 — statements + function bodies" [

        // ----- bindings -----

        test "val with matching annotation type-checks" {
            let r = parseAndCheck
                        "func f(): Int { val x: Int = 1 ; return x }"
            Expect.isEmpty r.Diagnostics "no diags"
        }

        test "val with mismatched annotation reports T0060" {
            let r = parseAndCheck
                        "func f(): Int { val x: Int = true ; return 1 }"
            Expect.contains (codes r) "T0060" "type mismatch"
        }

        test "var with init and annotation must agree" {
            let r = parseAndCheck
                        "func f(): Int { var x: Int = true ; return 0 }"
            Expect.contains (codes r) "T0061" "var mismatch"
        }

        test "let with mismatched annotation reports T0062" {
            let r = parseAndCheck
                        "func f(): Int { let x: Int = \"hi\" ; return 1 }"
            Expect.contains (codes r) "T0062" "let mismatch"
        }

        test "binding type flows into a later expression" {
            // Without inference for `x` in scope, the comparison
            // would fail with an unknown-name diagnostic.
            let r = parseAndCheck
                        "func f(): Bool { val x: Int = 1 ; return x == 1 }"
            Expect.isEmpty r.Diagnostics "no diags"
        }

        // ----- assignment -----

        test "assignment with matching types is clean" {
            let r = parseAndCheck
                        "func f(): Int { var x: Int = 0 ; x = 1 ; return x }"
            Expect.isEmpty r.Diagnostics "no diags"
        }

        test "assignment with type mismatch reports T0063" {
            let r = parseAndCheck
                        "func f(): Int { var x: Int = 0 ; x = true ; return 0 }"
            Expect.contains (codes r) "T0063" "assign mismatch"
        }

        // ----- return -----

        test "return type matching declared type is clean" {
            let r = parseAndCheck "pub func f(): Int = 1"
            Expect.isEmpty r.Diagnostics "no diags"
        }

        test "expression-bodied return type mismatch reports T0070" {
            let r = parseAndCheck "pub func f(): Int = true"
            Expect.contains (codes r) "T0070" "expr-body mismatch"
        }

        test "return without value in non-Unit function reports T0064" {
            let r = parseAndCheck
                        "func f(): Int { return }"
            Expect.contains (codes r) "T0064" "missing-value return"
        }

        test "return with wrong-type value reports T0065" {
            let r = parseAndCheck
                        "func f(): Int { return true }"
            Expect.contains (codes r) "T0065" "wrong-type return"
        }

        test "return Never satisfies any return type" {
            // `return throw …` has type Never. Today we model
            // `throw` via SThrow as a statement; verify at least that
            // a function whose body always throws is accepted.
            let r = parseAndCheck
                        "func f(): Int { throw err }"
            // The throw statement may emit T0020 for the unknown
            // 'err' name, but should NOT emit T0070 for a return
            // mismatch.
            Expect.isFalse (List.contains "T0070" (codes r))
                "no T0070 for diverging body"
        }

        // ----- while / for -----

        test "while condition must be Bool" {
            let r = parseAndCheck
                        "func f(): Int { while 1 { } ; return 0 }"
            Expect.contains (codes r) "T0066" "non-Bool cond"
        }

        test "for-in introduces a binding of the slice element type" {
            let r = parseAndCheck
                        "func sumAll(xs: in slice[Int]): Int { for x in xs { } ; return 0 }"
            Expect.isEmpty r.Diagnostics "no diags"
        }

        // ----- parameter scope -----

        test "parameters are visible inside the body" {
            let r = parseAndCheck "pub func f(x: in Int): Int = x"
            Expect.isEmpty r.Diagnostics "no diags"
        }

        test "parameter type flows into operations" {
            let r = parseAndCheck "pub func add(x: in Int, y: in Int): Int = x + y"
            Expect.isEmpty r.Diagnostics "no diags"
        }

        // ----- multi-statement bodies -----

        test "multi-statement body with val + return" {
            let r = parseAndCheck
                        "pub func f(): Int { val x: Int = 1 ; val y: Int = x + 1 ; return y }"
            Expect.isEmpty r.Diagnostics "no diags"
        }

        test "shadowing in nested scope" {
            // T5's checkBlock pushes/pops scopes; an outer `x` is
            // still visible after the for-loop's `x` shadows it.
            let r = parseAndCheck """
                func f(xs: in slice[Int]): Int {
                    val x: Int = 0
                    for x in xs { }
                    return x
                }"""
            Expect.isEmpty r.Diagnostics "no diags"
        }
    ]
