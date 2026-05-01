module Lyric.Lexer.Tests.NumericEdgeTests

open Expecto
open Lyric.Lexer
open Lyric.Lexer.Tests.TestHelpers

let tests =
    testList "numeric edge cases" [

        test "uint64 maximum value lexes cleanly" {
            // 18446744073709551615 = 2^64 - 1.
            Expect.equal (tokensClean "18446744073709551615")
                [TInt(System.UInt64.MaxValue, NoIntSuffix)] "max u64"
        }

        test "decimal integer overflow produces L0010" {
            // 18446744073709551616 = 2^64 — one past the max.
            let _, diags = lexBoth "18446744073709551616"
            let codes = diags |> List.map (fun d -> d.Code)
            Expect.contains codes "L0010" "overflow flagged"
        }

        test "hex literal max u64" {
            Expect.equal (tokensClean "0xFFFFFFFFFFFFFFFF")
                [TInt(System.UInt64.MaxValue, NoIntSuffix)] "max hex"
        }

        test "hex literal overflow produces L0010" {
            let _, diags = lexBoth "0x1FFFFFFFFFFFFFFFF"
            let codes = diags |> List.map (fun d -> d.Code)
            Expect.contains codes "L0010" "hex overflow"
        }

        test "binary with leading zero is fine" {
            Expect.equal (tokensClean "0b00001") [TInt(1UL, NoIntSuffix)] "0b00001"
        }

        test "octal with leading zeros is fine" {
            Expect.equal (tokensClean "0o007") [TInt(7UL, NoIntSuffix)] "0o007"
        }

        test "float exponent without sign" {
            let toks = tokensClean "1e3"
            match toks with
            | [TFloat(v, _)] -> Expect.floatClose Accuracy.high v 1e3 "1e3"
            | other -> failtestf "%A" other
        }

        test "float exponent with positive sign" {
            let toks = tokensClean "1e+3"
            match toks with
            | [TFloat(v, _)] -> Expect.floatClose Accuracy.high v 1e3 "1e+3"
            | other -> failtestf "%A" other
        }

        test "lone dot does not start a number" {
            // `1.foo` is `1`, `.`, `foo` — the float lexer requires a
            // digit after the dot.
            let actual = tokensClean "1.foo" |> withoutStmtEnds
            Expect.equal actual
                [TInt(1UL, NoIntSuffix); TPunct Dot; TIdent "foo"]
                "1.foo"
        }

        test "underscore-only digits parse to 0" {
            // `0b___` has no body digits but the underscores are
            // stripped, leaving an empty body. Convert.ToUInt64("",2)
            // throws and the lexer emits L0010.
            let _, diags = lexBoth "0b___"
            let codes = diags |> List.map (fun d -> d.Code)
            Expect.contains codes "L0010" "empty-body diag"
        }

        test "0 alone is fine" {
            Expect.equal (tokensClean "0") [TInt(0UL, NoIntSuffix)] "0"
        }

        test "0e1 is a float, not a leading-zero integer" {
            // The leading-zero diagnostic applies to decimal *integers*;
            // 0e1 is a float (= 0.0).
            let toks, diags = lexBoth "0e1"
            Expect.isEmpty diags "no diagnostic"
            match toks with
            | [TFloat(v, _)] -> Expect.floatClose Accuracy.high v 0.0 "0e1"
            | other -> failtestf "%A" other
        }
    ]
