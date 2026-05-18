module Lyric.Lexer.Tests.SmokeTests

open System
open System.IO
open Expecto
open Lyric.Lexer
open Lyric.Lexer.Lexer

/// Extract every code block delimited by triple-backtick lines.
/// A line whose trimmed form is exactly "```" toggles in/out of a block.
/// Blocks whose opening fence has a language tag other than "" or "lyric"
/// are skipped (the worked-examples doc currently uses no tag, but we
/// future-proof for "```json" etc.).
let private extractCodeBlocks (md: string) : (int * string) list =
    let lines = md.Replace("\r\n", "\n").Split('\n')
    let mutable blocks = []
    let mutable inBlock = false
    let mutable currentLang = ""
    let mutable currentSb = System.Text.StringBuilder()
    let mutable currentStart = 0
    for i in 0 .. lines.Length - 1 do
        let line = lines.[i]
        let trimmed = line.TrimStart(' ')
        if trimmed.StartsWith("```") then
            if inBlock then
                let lang = currentLang.ToLowerInvariant()
                if lang = "" || lang = "lyric" then
                    blocks <- (currentStart, currentSb.ToString()) :: blocks
                inBlock <- false
                currentSb <- System.Text.StringBuilder()
            else
                inBlock <- true
                currentLang <- trimmed.Substring(3).Trim()
                currentStart <- i + 1
        elif inBlock then
            currentSb.AppendLine(line) |> ignore
    List.rev blocks

let private docsPath () =
    Path.Combine(AppContext.BaseDirectory, "02-worked-examples.md")

let tests =
    testList "smoke (worked examples)" [

        test "the docs file is reachable" {
            Expect.isTrue (File.Exists(docsPath ()))
                (sprintf "expected docs at %s" (docsPath ()))
        }

        test "the docs file contains at least 10 lyric code blocks" {
            let md = File.ReadAllText(docsPath ())
            let blocks = extractCodeBlocks md
            Expect.isGreaterThan blocks.Length 10
                (sprintf "found %d blocks" blocks.Length)
        }

        test "every code block in 02-worked-examples.md lexes without diagnostics" {
            let md = File.ReadAllText(docsPath ())
            let blocks = extractCodeBlocks md
            let mutable failures = 0
            let report = System.Text.StringBuilder()
            for (lineStart, code) in blocks do
                let r = lex code
                if not (List.isEmpty r.Diagnostics) then
                    failures <- failures + 1
                    report
                        .AppendLine(sprintf "Block at line %d (%d diagnostics):"
                                            lineStart r.Diagnostics.Length)
                        |> ignore
                    for d in r.Diagnostics do
                        report
                            .AppendLine(sprintf "  %s: %s @ line %d col %d"
                                                d.Code d.Message
                                                d.Span.Start.Line
                                                d.Span.Start.Column)
                            |> ignore
            Expect.equal failures 0
                (sprintf "lex errors in worked-examples blocks:\n%s" (report.ToString()))
        }

        test "lexing each block produces a non-empty token stream" {
            let md = File.ReadAllText(docsPath ())
            let blocks = extractCodeBlocks md
            for (lineStart, code) in blocks do
                let r = lex code
                let nonEof = r.Tokens |> Seq.filter (fun t -> t.Token <> TEof) |> Seq.length
                Expect.isGreaterThan nonEof 0
                    (sprintf "block at line %d produced no tokens" lineStart)
        }
    ]
