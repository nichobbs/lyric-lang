/// Phase 5 §M5.3 — exercises the `Lyric.Generator` supply-chain
/// enforcement helpers through a tiny consumer.
///
/// Compiles `lyric-compiler/lyric/generator/generator_self_test.l` via
/// the bootstrap emitter, runs the resulting program, and asserts that
/// every in-program assertion held (exit code 0 + an "ok" line in
/// stdout).  The self-test imports `Lyric.Generator` and
/// `Lyric.Manifest`; the emitter's auto-resolver pulls all
/// `Lyric.*` libraries from `lyric-compiler/lyric/` transparently.
module Lyric.Emitter.Tests.SelfHostedGeneratorTests

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

/// Walk up from the binary's base dir looking for the self-test consumer.
let private findSelfTestSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate =
            Path.Combine(
                dir.Value.FullName,
                "lyric-compiler", "lyric", "generator", "generator_self_test.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let tests =
    testList "Lyric.Generator self-host (Phase 5 §M5.3)" [

        testCase "[generator_self_test_passes]" <| fun () ->
            let src =
                match findSelfTestSource () with
                | Some path -> File.ReadAllText path
                | None ->
                    failwith
                        "cannot locate lyric-compiler/lyric/generator/generator_self_test.l — run from the source tree"

            let result, stdout, stderr, exitCode =
                compileAndRun "self_hosted_generator" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d ->
                    d.Code.StartsWith "E" || d.Code.StartsWith "T"
                    || d.Code.StartsWith "P")
            Expect.isEmpty errors
                (sprintf "compile errors:\n%s\n\nall diagnostics:\n%s"
                    (errors
                     |> List.map (fun d ->
                         sprintf "  %s @ %d:%d  %s"
                             d.Code
                             d.Span.Start.Line
                             d.Span.Start.Column
                             d.Message)
                     |> String.concat "\n")
                    (result.Diagnostics
                     |> List.map (fun d ->
                         sprintf "  %A %s @ %d:%d  %s"
                             d.Severity
                             d.Code
                             d.Span.Start.Line
                             d.Span.Start.Column
                             d.Message)
                     |> String.concat "\n"))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "ok"
                (sprintf "stdout should contain 'ok' (got: '%s')" stdout)
    ]
