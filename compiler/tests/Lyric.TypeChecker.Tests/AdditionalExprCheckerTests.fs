module Lyric.TypeChecker.Tests.AdditionalExprCheckerTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser
open Lyric.TypeChecker
open Lyric.TypeChecker.Checker
open Lyric.TypeChecker.ExprChecker

let private inferIn (decls: string) (exprSrc: string) : Type * Diagnostic list =
    let parsed = parse ("package P\n" + decls)
    let r = check parsed.File
    let e, parseDiags = parseExprFromString exprSrc
    let scope = Scope()
    let diags = ResizeArray<Diagnostic>(parseDiags)
    let t = inferExpr scope r.Symbols r.Signatures diags e
    t, List.ofSeq diags

let private inferOnly (exprSrc: string) =
    inferIn "" exprSrc

let private codes (diags: Diagnostic list) =
    diags |> List.map (fun d -> d.Code)

let tests =
    testList "T4 — additional expression checks" [

        // ----- equality checks (T0032) -----

        test "equality of incompatible types reports T0032" {
            let _, d = inferOnly "1 == true"
            Expect.contains (codes d) "T0032" "T0032 reported"
        }

        // ----- coalesce (??) checks (T0035) -----

        test "coalesce on non-nullable LHS reports T0035" {
            let _, d = inferOnly "1 ?? 2"
            Expect.contains (codes d) "T0035" "?? non-nullable LHS"
        }

        // ----- prefix (-) on non-numeric (T0036) -----

        test "unary minus on Bool reports T0036" {
            let _, d = inferOnly "-true"
            Expect.contains (codes d) "T0036" "T0036 reported"
        }

        // ----- function call on non-function (T0044) -----

        test "calling a literal value reports T0044" {
            // `42(1)` — the integer literal isn't callable. The call
            // site sees TyPrim PtInt and emits T0044.
            let _, d = inferOnly "42(1)"
            Expect.contains (codes d) "T0044" "T0044 reported"
        }

        // ----- xor / or behaviour (T0034 already covered for and) -----

        test "xor with non-Bool LHS reports T0034" {
            let _, d = inferOnly "1 xor true"
            Expect.contains (codes d) "T0034" "T0034 for xor"
        }

        test "or with non-Bool RHS reports T0034" {
            let _, d = inferOnly "true or 1"
            Expect.contains (codes d) "T0034" "T0034 for or"
        }

        // ----- numeric kind preservation -----

        test "addition of two Doubles produces Double" {
            let t, _ = inferOnly "1.5 + 2.5"
            Expect.equal t (TyPrim PtDouble) "Double + Double = Double"
        }

        test "Long + Long is Long" {
            let t, _ = inferOnly "1i64 + 2i64"
            Expect.equal t (TyPrim PtLong) "Long + Long = Long"
        }

        // ----- nullable propagation -----

        test "?? on nullable Int returns Int" {
            // The right side is the bare type; LHS must be nullable.
            // We bind a nullable via a function returning Int?.
            let decls =
                "pub func maybe(): Int? = 1"
            let t, d = inferIn decls "maybe() ?? 0"
            Expect.isEmpty d "no diagnostics"
            Expect.equal t (TyPrim PtInt) "Int"
        }

        test "?? RHS-type-mismatch with nullable LHS reports T0035" {
            let decls = "pub func maybe(): Int? = 1"
            let _, d = inferIn decls "maybe() ?? true"
            Expect.contains (codes d) "T0035" "?? mismatched RHS"
        }

        // ----- list literal mismatches -----

        test "empty list literal is admitted (no T0041)" {
            let _, d = inferOnly "[]"
            Expect.isFalse (List.contains "T0041" (codes d))
                "no T0041 for empty list"
        }

        // ----- comparison on user type -----

        test "comparing a record value with a primitive reports T0033" {
            let decls =
                "pub record P { x: Int }\n\
                 pub func mk(): P = P(x = 0)"
            let _, d = inferIn decls "mk() < 1"
            Expect.contains (codes d) "T0033" "T0033 for ordered mismatch"
        }

        // ----- contract operator: implies LHS non-Bool -----

        test "implies with non-Bool LHS reports T0034" {
            let _, d = inferOnly "1 implies true"
            Expect.contains (codes d) "T0034" "T0034 for implies"
        }

        // ----- chained range expressions -----

        test "tuple of mixed primitive kinds keeps shape" {
            let t, _ = inferOnly "(1i64, 2.5f32, true)"
            match t with
            | TyTuple [TyPrim PtLong; TyPrim PtFloat; TyPrim PtBool] -> ()
            | other -> failtestf "shape: %A" other
        }
    ]
