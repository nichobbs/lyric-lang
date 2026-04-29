module Lyric.TypeChecker.Tests.WorkedExampleSmokeTests

open System.IO
open Expecto
open Lyric.Lexer
open Lyric.TypeChecker
open Lyric.TypeChecker.Checker

/// Reuse the parser smoke test's documentation walker by re-reading
/// `docs/02-worked-examples.md` from the test binary's working
/// directory.
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

let private looksLikeFile (block: string) : bool =
    block.Split('\n')
    |> Array.exists (fun l -> l.TrimStart().StartsWith("package "))

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

let private wrapFragment (block: string) : string =
    "package SmokeTest\n" + block

let tests =
    testList "type-checker worked-examples smoke (T6)" [

        test "every block in docs/02-worked-examples.md type-checks without exceptions" {
            let path = locateWorkedExamples ()
            let md   = File.ReadAllText path
            let blocks = extractLyricBlocks md

            Expect.isGreaterThan blocks.Length 5
                "expected several code blocks in worked examples"

            let parseable =
                blocks |> Seq.filter (fun (_, b) -> not (isPartialSnippet b))
                       |> List.ofSeq
            let totalParseable = parseable.Length

            let mutable totalLexer  = 0
            let mutable totalParser = 0
            let mutable totalType   = 0
            let mutable cleanBlocks = 0
            let codeFreq = System.Collections.Generic.Dictionary<string, int>()

            let perBlock = ResizeArray<int * int * Diagnostic list>()
            for (lineNo, block) in parseable do
                let src =
                    if looksLikeFile block then block
                    else wrapFragment block
                // The type checker must not throw — that is the load-
                // bearing guarantee. Diagnostics are tallied; only a
                // raised exception fails the test.
                let r = checkSource src
                let lexer  = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "L")
                let parser = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "P")
                let typer  = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "T")
                totalLexer  <- totalLexer  + lexer.Length
                totalParser <- totalParser + parser.Length
                totalType   <- totalType   + typer.Length
                perBlock.Add(lineNo, typer.Length, typer)
                for d in typer do
                    match codeFreq.TryGetValue d.Code with
                    | true, n -> codeFreq.[d.Code] <- n + 1
                    | false, _ -> codeFreq.[d.Code] <- 1
                if List.isEmpty typer then
                    cleanBlocks <- cleanBlocks + 1

            printfn ""
            printfn "[t-smoke] %d / %d parseable blocks have zero T-diagnostics"
                cleanBlocks totalParseable
            printfn "[t-smoke] totals: lexer=%d  parser=%d  type=%d"
                totalLexer totalParser totalType
            let sorted =
                codeFreq
                |> Seq.sortByDescending (fun kv -> kv.Value)
                |> Seq.truncate 10
            for kv in sorted do
                printfn "[t-smoke]   %s × %d" kv.Key kv.Value
            for (line, n, diags) in perBlock do
                if n > 0 then
                    printfn "[t-smoke] block @ line %d: %d T-diagnostic(s)" line n
                    for d in diags |> List.truncate 2 do
                        printfn "          %s @ %d:%d  %s"
                            d.Code d.Span.Start.Line d.Span.Start.Column d.Message

            // T6 acceptance: every parseable block runs to completion
            // without throwing AND the clean ratio stays above a
            // floor. The Phase 1 type checker is intentionally
            // permissive — name-resolution diagnostics are silenced,
            // generic instantiation is shallow, and named/primitive
            // compatibility is relaxed — so the floor is set at 80%
            // to prevent regressions while leaving room for the
            // tighter Phase 2 / Phase 3 checks to push the count
            // back up via real diagnostics.
            let cleanRatio = float cleanBlocks / float totalParseable
            Expect.isGreaterThanOrEqual
                cleanRatio 0.80
                (sprintf "clean-parse ratio %.2f below 0.80 threshold" cleanRatio)
        }
    ]
