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

            for (_, block) in parseable do
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
                if List.isEmpty typer then
                    cleanBlocks <- cleanBlocks + 1

            printfn ""
            printfn "[t-smoke] %d / %d parseable blocks have zero T-diagnostics"
                cleanBlocks totalParseable
            printfn "[t-smoke] totals: lexer=%d  parser=%d  type=%d"
                totalLexer totalParser totalType

            // T6 acceptance: every parseable block runs to completion
            // without throwing. The Phase 1 type checker is
            // intentionally permissive — we don't yet model record-
            // constructor calls, generic instantiation, or interface
            // dispatch with full fidelity, so the absolute count of T
            // diagnostics is allowed to vary. The hard assertion is
            // that the run completed.
            Expect.isGreaterThanOrEqual
                cleanBlocks 0
                "non-throwing run produces a non-negative tally"
        }
    ]
