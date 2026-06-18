module Lyric.Lexer.Tests.SpanTests

open Expecto
open Lyric.Lexer
open Lyric.Lexer.Lexer

/// Spanned-token helpers — span data is dropped by the standard
/// helpers, so this module reaches through `lex` directly.

let private spannedTokens (src: string) =
    let r = lex src
    r.Tokens
    |> List.filter (fun t -> t.Token <> TEof && t.Token <> TStmtEnd)

let tests =
    testList "spans and positions" [

        test "first token starts at line 1, column 1, offset 0" {
            let toks = spannedTokens "foo"
            Expect.equal toks.Length 1 "one token"
            let s = toks.[0].Span
            Expect.equal s.Start.Offset 0 "start offset"
            Expect.equal s.Start.Line   1 "start line"
            Expect.equal s.Start.Column 1 "start column"
            Expect.equal s.End.Offset   3 "end offset"
            Expect.equal s.End.Column   4 "end column"
        }

        test "newline advances Line and resets Column" {
            let toks = spannedTokens "a\nb"
            // toks: TIdent "a", TIdent "b" (TStmtEnd filtered).
            Expect.equal toks.Length 2 "two tokens"
            let bSpan = toks.[1].Span
            Expect.equal bSpan.Start.Line   2 "b is on line 2"
            Expect.equal bSpan.Start.Column 1 "b is at column 1"
        }

        test "span length matches token text length" {
            let toks = spannedTokens "hello world"
            let helloSpan = toks.[0].Span
            Expect.equal helloSpan.Length 5 "hello has length 5"
            let worldSpan = toks.[1].Span
            Expect.equal worldSpan.Length 5 "world has length 5"
        }

        test "multi-char operator span covers all bytes" {
            let toks = spannedTokens "a..=b"
            // a, ..=, b
            Expect.equal toks.Length 3 "three tokens"
            let opSpan = toks.[1].Span
            Expect.equal opSpan.Length 3 "..= has length 3"
            Expect.equal toks.[2].Span.Start.Offset 4 "b at offset 4"
        }

        test "column tracking after a tab" {
            // The lexer treats tab as one column, matching the
            // Position.advanceChar default. This codifies that contract.
            let toks = spannedTokens "a\tb"
            Expect.equal toks.[0].Span.Start.Column 1 "a column"
            Expect.equal toks.[1].Span.Start.Column 3 "b column"
        }

        test "CRLF normalises to LF for line counting" {
            let toks = spannedTokens "a\r\nb"
            Expect.equal toks.Length 2 "two tokens"
            Expect.equal toks.[1].Span.Start.Line 2 "b is on line 2"
            Expect.equal toks.[1].Span.Start.Column 1 "b is at column 1"
        }

        test "bare CR is treated as a newline" {
            let toks = spannedTokens "a\rb"
            Expect.equal toks.Length 2 "two tokens"
            Expect.equal toks.[1].Span.Start.Line 2 "b is on line 2"
        }

        test "EOF token is the last entry of the stream" {
            let r = lex "x"
            let last = r.Tokens |> List.last
            Expect.equal last.Token TEof "last token is TEof"
        }

        test "synthesised TStmtEnd has zero-width span" {
            let r = lex "a\nb"
            let stmtEnds =
                r.Tokens |> List.filter (fun t -> t.Token = TStmtEnd)
            Expect.isNonEmpty stmtEnds "TStmtEnd present"
            for t in stmtEnds do
                Expect.equal t.Span.Length 0 "zero width"
        }
    ]
