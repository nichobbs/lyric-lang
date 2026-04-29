module Lyric.Parser.Tests.WorkedExampleSmokeTests

open System.IO
open Expecto
open Lyric.Lexer
open Lyric.Parser.Parser

/// Locate `docs/02-worked-examples.md` from the test binary's working
/// directory. We walk up parent directories until the file is found
/// (typical structure is `compiler/tests/Lyric.Parser.Tests/bin/Debug/
/// net9.0/`, so the doc lives five levels up).
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

/// A code block has a Lyric "header" if it starts with one of:
///   - a leading `// path/to/file.l` comment
///   - a top-level annotation (@runtime_checked / @proof_required / @axiom /
///     @test_module)
///   - a `package` declaration
/// Blocks lacking a header are treated as fragments — they still attempt
/// parsing but do not require `package`.
let private looksLikeFile (block: string) : bool =
    let trimmedLines =
        block.Split('\n')
        |> Array.map (fun l -> l.Trim())
        |> Array.filter (fun l -> l <> "" && not (l.StartsWith("//")))
    if trimmedLines.Length = 0 then false
    else
        let first = trimmedLines.[0]
        first.StartsWith("@runtime_checked")
        || first.StartsWith("@proof_required")
        || first.StartsWith("@axiom")
        || first.StartsWith("@test_module")
        || first.StartsWith("package ")

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

            for (lineNo, block) in blocks do
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
            printfn "[smoke] %d blocks: %d clean, %d with diagnostics (%d lexer, %d parser)"
                blocks.Length cleanBlocks (blocks.Length - cleanBlocks)
                totalLexer totalParser
            for (line, _, diags) in failingBlocks do
                printfn "[smoke] block @ line %d: %d diagnostics" line diags.Length
                for d in diags |> List.truncate 3 do
                    printfn "   %s @ %d:%d  %s"
                        d.Code d.Span.Start.Line d.Span.Start.Column d.Message

            // Acceptance criterion (P9 milestone): at least 40% of
            // blocks parse cleanly AND every block parses to
            // completion (no infinite loops). The latter is the
            // important guarantee — the percentage is a moving
            // target that increases as later slices fill in:
            //
            //   * `try { … } catch …` as an EXPRESSION (currently
            //     statement-only); blocks the `return try { … }
            //     catch …` shape used in the FFI wrapper example.
            //   * `?? return Err(…)` — `return` in the RHS of `??`
            //     requires `return`/`break`/`continue`/`throw` to
            //     be admissible in expression position (today the
            //     parser only allows them in match-arm bodies).
            //   * `opaque type X = record { … }` body-file form
            //     (variant of §3.7 not yet recognised).
            //   * `forall (…) where … implies … and forall (…) …`
            //     — quantifier expressions in contracts; requires
            //     `forall`/`exists` as primary expressions.
            //   * Typed lambda parameters: `{ x: Int -> body }`
            //     needs a `parseTypeExprNoArrow` so the lambda's
            //     `->` is not consumed as a function-type arrow.
            //
            // These are tracked as P10+ polish work; the parser
            // infrastructure (every item kind, every statement,
            // most expressions) is in place and produces a
            // well-typed AST for the majority of the worked
            // examples.
            let cleanRatio = float cleanBlocks / float blocks.Length
            Expect.isGreaterThanOrEqual
                cleanRatio
                0.40
                (sprintf "clean-parse ratio %.2f below 0.40 threshold" cleanRatio)
        }
    ]
