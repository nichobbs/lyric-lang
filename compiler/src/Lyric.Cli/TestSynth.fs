/// `lyric test` source synthesiser.
///
/// Given a Lyric source string carrying `@test_module` plus zero or
/// more `test "title" { … }` items, produce a *new* source string
/// where:
///
///   * Each `test "title" { body }` becomes a regular
///     `func __lyric_test_<idx>(): Unit { body }`.
///   * A synthesised `func main(): Unit` is appended that runs each
///     test inside a `try`/`catch Bug as b { … }` and prints a
///     TAP-shaped report to stdout.
///   * Properties parse but skip with a `# skip` line.
///   * Fixtures emit a `T0901` diagnostic — the v1 runner does not
///     execute them; users who need fixtures use `wire` blocks
///     today.
///
/// The rewrite operates on *spans into the original source string*
/// so user-authored test bodies stay byte-identical (line numbers
/// reported by the type-checker / emitter still point at user
/// code).  See `docs/24-test-runner-plan.md` for the rationale.
module Lyric.Cli.TestSynth

open System.Text
open Lyric.Lexer
open Lyric.Parser
open Lyric.Parser.Ast

type Outcome =
    | Synthesised of source: string * testCount: int * skipCount: int
    | NoTestModule of Span
    | UserMainExists of Span
    | FixtureUnsupported of Span
    | ParseFailures of Diagnostic list

let private annotationName (a: Annotation) : string =
    String.concat "." a.Name.Segments

let private hasTestModule (file: SourceFile) : bool =
    file.FileLevelAnnotations
    |> List.exists (fun a -> annotationName a = "test_module")

let private fileSpan (file: SourceFile) : Span = file.Span

let private slice (source: string) (span: Span) : string =
    let s = span.Start.Offset
    let e = span.End.Offset
    if s >= 0 && e <= source.Length && e >= s then
        source.Substring(s, e - s)
    else ""

let private escape (s: string) : string =
    let sb = StringBuilder()
    for c in s do
        match c with
        | '"'  -> sb.Append "\\\""    |> ignore
        | '\\' -> sb.Append "\\\\"    |> ignore
        | '\n' -> sb.Append "\\n"     |> ignore
        | '\r' -> sb.Append "\\r"     |> ignore
        | '\t' -> sb.Append "\\t"     |> ignore
        | _    -> sb.Append c         |> ignore
    sb.ToString()

let private filterTitle (filter: string option) (title: string) : bool =
    match filter with
    | None   -> true
    | Some f -> title.Contains(f: string)

let private synthesizeMain
        (testNames: (string * string) list)   // (functionName, title)
        (skipped: (string * string) list)     // (title, reason)
        (filter: string option) : string =
    let total = testNames.Length + skipped.Length
    let sb = StringBuilder()
    sb.AppendLine "func main(): Int {"              |> ignore
    sb.AppendLine (sprintf "  println(\"1..%d\")" total) |> ignore
    sb.AppendLine "  var __lyric_passed: Int = 0"   |> ignore
    sb.AppendLine "  var __lyric_failed: Int = 0"   |> ignore
    sb.AppendLine "  var __lyric_skipped: Int = 0"  |> ignore
    let mutable seq = 1
    for (fname, title) in testNames do
        let titleEsc = escape title
        let n = seq
        seq <- seq + 1
        if not (filterTitle filter title) then
            sb.AppendLine (sprintf
                "  println(\"# skip %d - %s (filter)\")"
                n titleEsc) |> ignore
            sb.AppendLine "  __lyric_skipped = __lyric_skipped + 1" |> ignore
        else
            sb.AppendLine "  try {"                                  |> ignore
            sb.AppendLine (sprintf "    %s()" fname)                 |> ignore
            sb.AppendLine (sprintf "    println(\"ok %d - %s\")"
                            n titleEsc)                              |> ignore
            sb.AppendLine "    __lyric_passed = __lyric_passed + 1"  |> ignore
            sb.AppendLine "  } catch Bug as __lyric_e {"             |> ignore
            sb.AppendLine (sprintf "    println(\"not ok %d - %s\")"
                            n titleEsc)                              |> ignore
            sb.AppendLine "    println(\"  \" + __lyric_e.message)"  |> ignore
            sb.AppendLine "    __lyric_failed = __lyric_failed + 1"  |> ignore
            sb.AppendLine "  }"                                      |> ignore
    for (title, reason) in skipped do
        let titleEsc  = escape title
        let reasonEsc = escape reason
        let n = seq
        seq <- seq + 1
        sb.AppendLine (sprintf "  println(\"# skip %d - %s: %s\")"
                        n titleEsc reasonEsc) |> ignore
        sb.AppendLine "  __lyric_skipped = __lyric_skipped + 1" |> ignore
    sb.AppendLine "  println(\"\")"                              |> ignore
    sb.AppendLine "  println(\"# tests \" + toString(__lyric_passed + __lyric_failed + __lyric_skipped))" |> ignore
    sb.AppendLine "  println(\"# pass  \" + toString(__lyric_passed))"  |> ignore
    sb.AppendLine "  println(\"# fail  \" + toString(__lyric_failed))"  |> ignore
    sb.AppendLine "  println(\"# skip  \" + toString(__lyric_skipped))" |> ignore
    sb.AppendLine "  if __lyric_failed > 0 {"                            |> ignore
    sb.AppendLine "    return 1"                                         |> ignore
    sb.AppendLine "  }"                                                  |> ignore
    sb.AppendLine "  return 0"                                           |> ignore
    sb.AppendLine "}"                                                    |> ignore
    sb.ToString()

/// Walk `source`'s items in source order.  Build a list of
/// `(spanStart, spanEnd, replacementOpt)` segments where
/// `replacementOpt = None` means "emit the original slice" and
/// `Some s` means "emit `s` instead of the slice".
///
/// Items that aren't `ITest` / `IProperty` / `IFixture` are kept
/// untouched.  Tests / properties get rewritten; fixtures stop the
/// synthesis with a `T0901`-shaped diagnostic.
let synthesize (source: string) (filter: string option) : Outcome =
    let pf = Lyric.Parser.Parser.parse source
    let parseErrors =
        pf.Diagnostics
        |> List.filter (fun d -> d.Severity = DiagError)
    if not parseErrors.IsEmpty then
        ParseFailures parseErrors
    elif not (hasTestModule pf.File) then
        NoTestModule (fileSpan pf.File)
    else
        // Reject `func main` declared by the user.
        let userMain =
            pf.File.Items
            |> List.tryPick (fun it ->
                match it.Kind with
                | IFunc fn when fn.Name = "main" -> Some it.Span
                | _ -> None)
        match userMain with
        | Some sp -> UserMainExists sp
        | None ->
        // Reject fixtures (T0901).
        let fixtureItem =
            pf.File.Items
            |> List.tryPick (fun it ->
                match it.Kind with
                | IFixture _ -> Some it.Span
                | _ -> None)
        match fixtureItem with
        | Some sp -> FixtureUnsupported sp
        | None ->
        // Walk items.  For ITest, replace with a synthesised
        // `func __lyric_test_<i>(): Unit <body>` (the body span
        // covers the braces, so the slice already includes them).
        // For IProperty, drop the source range and record a skip.
        // For everything else, leave the source slice in place.
        let sb = StringBuilder()
        let mutable cursor = 0
        let testNames = ResizeArray<string * string>()
        let skipped = ResizeArray<string * string>()
        let mutable testIdx = 0
        for it in pf.File.Items do
            let s = it.Span.Start.Offset
            let e = it.Span.End.Offset
            // Emit everything from the previous cursor up to this
            // item's start verbatim.  This preserves the package
            // header, imports, doc comments, surrounding whitespace.
            sb.Append(source.Substring(cursor, max 0 (s - cursor))) |> ignore
            cursor <- e
            match it.Kind with
            | ITest t ->
                let bodyText = slice source t.Body.Span
                let fname = sprintf "__lyric_test_%d" testIdx
                testIdx <- testIdx + 1
                sb.AppendLine() |> ignore
                sb.Append (sprintf "func %s(): Unit %s" fname bodyText) |> ignore
                testNames.Add((fname, t.Title))
            | IProperty p ->
                // Drop the property item entirely; record as skip.
                skipped.Add((p.Title, "property: not implemented in v1"))
            | _ ->
                // Keep the item verbatim.
                sb.Append(source.Substring(s, e - s)) |> ignore
        // Tail: anything after the last item.
        sb.Append(source.Substring(cursor)) |> ignore
        // Append synthesised main.
        sb.AppendLine() |> ignore
        sb.AppendLine() |> ignore
        sb.Append(synthesizeMain
            (List.ofSeq testNames) (List.ofSeq skipped) filter) |> ignore
        Synthesised(
            sb.ToString(),
            testNames.Count,
            skipped.Count)

/// Render a list-only summary: `lyric test --list` walks every
/// `test "…"` declaration and prints titles without compiling.
type ListEntry =
    | TestEntry of title: string
    | PropertyEntry of title: string * reason: string
    | FixtureEntry of name: string

let listEntries (source: string) : Result<ListEntry list, Diagnostic list> =
    let pf = Lyric.Parser.Parser.parse source
    let parseErrors =
        pf.Diagnostics
        |> List.filter (fun d -> d.Severity = DiagError)
    if not parseErrors.IsEmpty then
        Error parseErrors
    else
        let xs = ResizeArray<ListEntry>()
        for it in pf.File.Items do
            match it.Kind with
            | ITest t     -> xs.Add(TestEntry t.Title)
            | IProperty p ->
                xs.Add(PropertyEntry(p.Title, "property: not implemented in v1"))
            | IFixture f  -> xs.Add(FixtureEntry f.Name)
            | _ -> ()
        Ok (List.ofSeq xs)
