module Lyric.Parser.Tests.WorkedExampleSmokeTests

open System.IO
open Expecto
open Lyric.Lexer
open Lyric.Parser.Parser

/// Locate `docs/02-worked-examples.md` from the test binary's working
/// directory. We walk up parent directories until the file is found
/// (typical structure is `compiler/tests/Lyric.Parser.Tests/bin/Debug/
/// net10.0/`, so the doc lives five levels up).
let private locateWorkedExamples () : string =
    let mutable dir = Some (DirectoryInfo(System.AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let d = dir.Value
        let candidate = Path.Combine(d.FullName, "docs", "02-worked-examples.md")
        if File.Exists candidate then found <- Some candidate
        dir <- d.Parent |> Option.ofObj
    match found with
    | Some p -> p
    | None ->
        failwithf "could not locate docs/02-worked-examples.md from %s"
            System.AppContext.BaseDirectory

/// Extract every triple-backtick code block. Blocks that start with
/// ```lyric or no language tag (the worked examples typically omit the
/// tag) are returned; blocks tagged with another language (e.g. `json`,
/// `cs`) are dropped.
let private extractLyricBlocks (markdown: string) : (int * string) list =
    let lines = markdown.Replace("\r\n", "\n").Split('\n')
    let xs = ResizeArray<int * string>()
    let mutable inBlock = false
    let mutable blockStart = 0
    let mutable currentLang = ""
    let mutable buf = System.Text.StringBuilder()
    for i in 0 .. lines.Length - 1 do
        let line = lines.[i]
        let trimmed = line.TrimStart()
        if trimmed.StartsWith("```") then
            if inBlock then
                let isLyric =
                    currentLang = "" || currentLang = "lyric" || currentLang = "lyr"
                if isLyric then
                    xs.Add(blockStart + 1, buf.ToString())
                inBlock <- false
                buf.Clear() |> ignore
            else
                inBlock <- true
                blockStart <- i
                currentLang <- trimmed.Substring(3).Trim()
        elif inBlock then
            buf.AppendLine(line) |> ignore
    List.ofSeq xs

/// A code block is treated as a complete file when it contains an
/// explicit `package …` declaration. Worked-example blocks that
/// start with a `@axiom`/`@runtime_checked`/etc. annotation but
/// omit `package` are treated as fragments and prepended with a
/// synthetic `package SmokeTest` so the parser's P0020 doesn't
/// fire trivially.
let private looksLikeFile (block: string) : bool =
    block.Split('\n')
    |> Array.exists (fun l -> l.TrimStart().StartsWith("package "))

/// True for blocks that are clearly illustrative snippets rather
/// than parseable Lyric source — a stand-alone `ensures:` clause,
/// a single expression, etc. The smoke test skips these.
let private isPartialSnippet (block: string) : bool =
    let firstReal =
        block.Split('\n')
        |> Array.map (fun l -> l.Trim())
        |> Array.tryFind (fun l -> l <> "" && not (l.StartsWith("//")))
    match firstReal with
    | None -> true
    | Some line ->
        line.StartsWith("requires:")
        || line.StartsWith("ensures:")
        || line.StartsWith("invariant:")
        || line.StartsWith("when:")

/// Add a `package SmokeTest` prelude for fragments so the parser does
/// not fire P0020.
let private wrapFragment (block: string) : string =
    "package SmokeTest\n" + block

let tests =
    testList "worked-examples smoke (P9)" [

        test "every block in docs/02-worked-examples.md parses without exceptions" {
            let path = locateWorkedExamples ()
            let md   = File.ReadAllText path
            let blocks = extractLyricBlocks md

            Expect.isGreaterThan blocks.Length 5
                "expected several code blocks in worked examples"

            let mutable totalLexer = 0
            let mutable totalParser = 0
            let mutable cleanBlocks = 0
            let mutable failingBlocks = ResizeArray<int * string * Diagnostic list>()

            // Filter out illustrative snippets that aren't intended
            // to parse as standalone Lyric source.
            let parseable =
                blocks |> Seq.filter (fun (_, b) -> not (isPartialSnippet b))
                       |> List.ofSeq
            let totalParseable = parseable.Length

            for (lineNo, block) in parseable do
                let src =
                    if looksLikeFile block then block
                    else wrapFragment block
                // The parser must not throw — that would be the only
                // hard-fail. Diagnostics are tallied but tolerated.
                let r = parse src
                let lexer = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "L")
                let parser = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "P")
                totalLexer  <- totalLexer  + lexer.Length
                totalParser <- totalParser + parser.Length
                if List.isEmpty r.Diagnostics then
                    cleanBlocks <- cleanBlocks + 1
                else
                    failingBlocks.Add(lineNo, block, r.Diagnostics)

            // Print a short summary on success / failure for visibility.
            printfn ""
            printfn "[smoke] %d / %d parseable blocks clean (%d lexer, %d parser diagnostics; %d total blocks, %d skipped as illustrative)"
                cleanBlocks totalParseable totalLexer totalParser blocks.Length
                (blocks.Length - totalParseable)
            for (line, _, diags) in failingBlocks do
                printfn "[smoke] block @ line %d: %d diagnostics" line diags.Length
                for d in diags |> List.truncate 3 do
                    printfn "   %s @ %d:%d  %s"
                        d.Code d.Span.Start.Line d.Span.Start.Column d.Message

            // Acceptance criterion (P11 milestone): at least 80% of
            // parseable blocks produce zero diagnostics, AND every
            // block parses to completion (no infinite loops). The
            // latter is the load-bearing guarantee. P12 added two
            // language features that were the dominant residual
            // sources of parse errors:
            //
            //   * `(TypeExpr).method(...)` — type-as-expression
            //     for static-method dispatch on a refined type
            //     (e.g. `(Nat range 1 ..= 100).tryFrom(x)`).
            //   * `lhs -> rhs` rule entries inside `{ … }` lambdas
            //     for the stub-builder DSL.
            //
            // The remaining residual is Kotlin-style trailing-lambda
            // sugar: `obj.method { … }` where `{ … }` is a single
            // lambda argument. Adding this requires plumbing a
            // "no-trailing-lambda" flag through the expression
            // tower so `if cond { … }`/`while …`/`for …`/`match …`
            // scrutinees do not eagerly slurp the following block.
            // Tracked as P13 polish.
            let cleanRatio = float cleanBlocks / float totalParseable
            Expect.isGreaterThanOrEqual
                cleanRatio
                0.80
                (sprintf "clean-parse ratio %.2f below 0.80 threshold" cleanRatio)
        }
    ]
