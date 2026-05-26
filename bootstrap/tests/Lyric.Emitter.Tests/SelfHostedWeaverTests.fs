/// Phase 5 §todo/06 — exercises the self-hosted `Lyric.Weaver` library
/// through the `weaver_ci_test.l` consumer.
///
/// Compiles `lyric-compiler/lyric/weaver_ci_test.l` via the
/// bootstrap emitter, runs the resulting program, and asserts that
/// every in-program assertion held (exit code 0 + an "ok" line in
/// stdout).  The consumer is a regular Lyric program (not @test_module)
/// that imports `Lyric.Weaver`, `Lyric.Parser`, and `Lyric.Lexer`;
/// the emitter's auto-resolver pulls those libraries from
/// `lyric-compiler/lyric/` transparently.
///
/// Covers the three todo/06 features (#683 config wiring,
/// #682 call prelude, #681 @inline_template args rewriting).
/// Closes #1347.
module Lyric.Emitter.Tests.SelfHostedWeaverTests

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate =
            Path.Combine(dir.Value.FullName, "lyric-compiler", "lyric", "weaver_ci_test.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let tests =
    testList "Lyric.Weaver self-host (todo/06 — config, call, @inline_template)" [

        testCase "[weaver_ci_test_passes]" <| fun () ->
            let src =
                match findSelfTestSource () with
                | Some path -> File.ReadAllText path
                | None ->
                    failwith
                        "cannot locate lyric-compiler/lyric/weaver_ci_test.l — run from the source tree"

            let result, stdout, stderr, exitCode =
                compileAndRun "self_hosted_weaver" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d ->
                    d.Code.StartsWith "E" || d.Code.StartsWith "T"
                    || d.Code.StartsWith "P")
            Expect.isEmpty errors
                (sprintf "compile errors:\n%s"
                    (errors
                     |> List.map (fun d ->
                         sprintf "  %s @ %d:%d  %s"
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
