/// Phase 5 §M5.1 stage 2b — exercises the self-hosted `Lyric.Lexer`
/// library through a tiny Lyric.LexerSelfTest consumer.
///
/// Compiles `lyric-compiler/lyric/lexer_self_test.l` via the bootstrap
/// emitter, runs the resulting program, and asserts that every
/// in-program assertion held (exit code 0 + an "ok" line in stdout).
/// The self-test `import Lyric.Lexer`; the emitter's auto-resolver
/// (`Emitter.fs:isBuiltinHead`) pulls the library source in
/// transparently.
module Lyric.Emitter.Tests.SelfHostedLexerTests

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

/// Walk up from `start` looking for the self-test consumer.
let private findSelfTestSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate =
            Path.Combine(dir.Value.FullName, "lyric-compiler", "lyric", "lexer_self_test.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let tests =
    testList "Lyric.Lexer self-host (Phase 5 §M5.1 stage 2b)" [

        testCase "[lexer_self_test_passes]" <| fun () ->
            let src =
                match findSelfTestSource () with
                | Some path -> File.ReadAllText path
                | None ->
                    failwith
                        "cannot locate lyric-compiler/lyric/lexer_self_test.l — run from the source tree"

            let result, stdout, stderr, exitCode =
                compileAndRun "self_hosted_lexer" src

            // 1. Compilation must succeed.  Filter for genuine errors;
            //    a stray warning should not fail the test.  Source
            //    locations are included so any future regression
            //    pinpoints the offending span without rebuilds.
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

            // 2. Program must exit 0.
            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            // 3. Program must signal "ok".
            Expect.stringContains stdout "ok"
                (sprintf "stdout should contain 'ok' (got: '%s')" stdout)
    ]
