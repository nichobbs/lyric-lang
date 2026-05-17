module Lyric.Lexer.Tests.IntLiteralTests

open Expecto
open Lyric.Lexer
open Lyric.Lexer.Tests.TestHelpers

let tests =
    testList "integer literals" [

        test "decimal integer literals" {
            let cases : (string * uint64) list =
                [ "0",         0UL
                  "1",         1UL
                  "42",        42UL
                  "1_000",     1000UL
                  "1_000_000", 1000000UL ]
            for src, expected in cases do
                Expect.equal (tokensClean src) [TInt(expected, NoIntSuffix)] src
        }

        test "based integer literals" {
            let cases : (string * uint64) list =
                [ "0xFF",       255UL
                  "0xff",       255UL
                  "0xDEAD_BEEF", 3735928559UL
                  "0o755",      493UL
                  "0b1010",     10UL
                  "0b1111_1111", 255UL ]
            for src, expected in cases do
                Expect.equal (tokensClean src) [TInt(expected, NoIntSuffix)] src
        }

        test "integer suffixes" {
            let cases : (string * IntSuffix) list =
                [ "0i8",    I8
                  "1i16",   I16
                  "100i32", I32
                  "100i64", I64
                  "0u8",    U8
                  "1u16",   U16
                  "100u32", U32
                  "100u64", U64 ]
            for src, expected in cases do
                let toks = tokensClean src
                match toks with
                | [TInt(_, sfx)] -> Expect.equal sfx expected src
                | _ -> failtestf "expected one int token for %s, got %A" src toks
        }

        test "leading-zero decimal is rejected" {
            let _, diags = lexBoth "0755"
            Expect.isNonEmpty diags "expected a diagnostic"
            Expect.equal (List.head diags).Code "L0012" "diag code"
        }

        test "hex with valid suffix lexes one token" {
            Expect.equal (tokensClean "0xFFu32") [TInt(255UL, U32)] "0xFFu32"
        }
    ]
