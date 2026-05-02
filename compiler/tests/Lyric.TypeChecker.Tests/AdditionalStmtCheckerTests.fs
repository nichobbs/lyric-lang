module Lyric.TypeChecker.Tests.AdditionalStmtCheckerTests

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
    testList "T5 — additional statement / out-param checks" [

        // ----- out / inout l-value validation (T0085) -----

        test "passing a literal to an out-param call reports T0085" {
            let src =
                "pub func setIt(x: out Int): Unit { x = 0 }\n\
                 pub func main(): Unit { setIt(1) }"
            let r = parseAndCheck src
            Expect.contains (codes r) "T0085" "T0085 reported"
        }

        test "passing a local variable to an out-param call is clean" {
            let src =
                "pub func setIt(x: out Int): Unit { x = 0 }\n\
                 pub func main(): Unit { var y: Int = 0 ; setIt(y) }"
            let r = parseAndCheck src
            Expect.isFalse (List.contains "T0085" (codes r))
                "no T0085 for var-named arg"
        }

        // ----- definite-assignment of out parameters (T0086) -----

        test "out parameter never assigned before return reports T0086" {
            let src =
                "pub func setIt(x: out Int): Unit { return }"
            let r = parseAndCheck src
            Expect.contains (codes r) "T0086" "T0086 reported"
        }

        test "out parameter assigned before return is clean" {
            let src =
                "pub func setIt(x: out Int): Unit { x = 42 ; return }"
            let r = parseAndCheck src
            Expect.isFalse (List.contains "T0086" (codes r))
                "no T0086 when assigned"
        }

        // ----- many statement-checker scenarios -----

        test "missing else in if-expression keeps return type-check sound" {
            // `if c { return 1 }` is a statement, so the function still
            // needs an explicit return at the end.
            let r = parseAndCheck
                        "pub func f(c: in Bool): Int { if c { return 1 } ; return 0 }"
            Expect.isEmpty r.Diagnostics "no diags"
        }

        test "for-loop binding is scoped to the body" {
            // `i` from the loop is not in scope after the loop.
            let r = parseAndCheck
                        "pub func sum(xs: in slice[Int]): Int { for i in xs { } ; return 0 }"
            Expect.isEmpty r.Diagnostics "no diags"
        }

        test "var without initializer is allowed; type comes from annotation" {
            let r = parseAndCheck
                        "pub func f(): Int { var n: Int ; n = 1 ; return n }"
            Expect.isEmpty r.Diagnostics "no diags"
        }

        test "while body type-checks expressions inside it" {
            let r = parseAndCheck
                        "pub func f(): Int { var x: Int = 0 ; while x < 10 { x = x + true } ; return x }"
            // `x + true` is invalid arithmetic — T0031 fires.
            Expect.contains (codes r) "T0031" "T0031 in while body"
        }

        // ----- nested function call argument checks -----

        test "function call as positional arg propagates types" {
            let r = parseAndCheck
                        "pub func sq(x: in Int): Int = x * x\n\
                         pub func main(): Int = sq(sq(2))"
            Expect.isEmpty r.Diagnostics "no diags"
        }

        test "function call with mismatched arg type reports T0043" {
            let r = parseAndCheck
                        "pub func sq(x: in Int): Int = x * x\n\
                         pub func main(): Int = sq(true)"
            Expect.contains (codes r) "T0043" "T0043 reported"
        }

        // ----- Unit return -----

        test "function returning Unit accepts a bare return" {
            let r = parseAndCheck
                        "pub func notify(): Unit { return }"
            Expect.isFalse (List.contains "T0064" (codes r))
                "no T0064 for Unit return"
        }
    ]
