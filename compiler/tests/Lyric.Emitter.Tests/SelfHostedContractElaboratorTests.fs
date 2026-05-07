/// Phase 5 §M5.2 stage 2 — exercises the self-hosted
/// `Lyric.ContractElaborator` library through a tiny consumer.
///
/// Compiles `compiler/lyric/lyric/contract_elaborator_self_test.l` via
/// the bootstrap emitter, runs the resulting program, and asserts that
/// every in-program assertion held (exit code 0 + an "ok" line in
/// stdout).  The self-test imports `Lyric.Parser` and
/// `Lyric.ContractElaborator`; the emitter's auto-resolver pulls all
/// multi-file libraries from `compiler/lyric/lyric/` transparently.
module Lyric.Emitter.Tests.SelfHostedContractElaboratorTests

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
            Path.Combine(dir.Value.FullName, "lyric", "lyric", "contract_elaborator_self_test.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let tests =
    testList "Lyric.ContractElaborator self-host (Phase 5 §M5.2)" [

        testCase "[contract_elaborator_self_test_passes]" <| fun () ->
            let src =
                match findSelfTestSource () with
                | Some path -> File.ReadAllText path
                | None ->
                    failwith
                        "cannot locate compiler/lyric/lyric/contract_elaborator_self_test.l — run from the source tree"

            let result, stdout, stderr, exitCode =
                compileAndRun "self_hosted_contract_elaborator" src

            // 1. Compilation must succeed.
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
