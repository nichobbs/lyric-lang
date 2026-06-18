module Lyric.Lexer.Tests.TestHelpers

open Expecto
open Lyric.Lexer
open Lyric.Lexer.Lexer

/// Lex and return only the Token values, with the trailing TEof dropped.
let tokens (src: string) : Token list =
    let result = lex src
    result.Tokens
    |> Seq.map (fun t -> t.Token)
    |> Seq.filter (fun t -> t <> TEof)
    |> List.ofSeq

/// Lex with the assertion that no diagnostics were produced.
let tokensClean (src: string) : Token list =
    let result = lex src
    if not (List.isEmpty result.Diagnostics) then
        failtestf "expected no diagnostics for %A, got: %A" src result.Diagnostics
    result.Tokens
    |> Seq.map (fun t -> t.Token)
    |> Seq.filter (fun t -> t <> TEof)
    |> List.ofSeq

/// Lex and return both tokens and diagnostics for assertions.
let lexBoth (src: string) =
    let r = lex src
    let toks =
        r.Tokens
        |> Seq.map (fun t -> t.Token)
        |> Seq.filter (fun t -> t <> TEof)
        |> List.ofSeq
    toks, r.Diagnostics

/// Drop TStmtEnd tokens from a list — useful when the test only cares
/// about the non-terminator content.
let withoutStmtEnds (toks: Token list) : Token list =
    toks |> List.filter (fun t -> t <> TStmtEnd)
