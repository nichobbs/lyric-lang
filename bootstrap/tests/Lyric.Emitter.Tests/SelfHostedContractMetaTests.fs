/// Phase 5 — exercises the self-hosted `Lyric.ContractMeta.parseFromJson`
/// in-process JSON parser through a tiny consumer.
///
/// Compiles `lyric-compiler/lyric/contract_meta_self_test.l` via the
/// bootstrap emitter, runs the resulting program, and asserts that
/// every in-program assertion held (exit code 0 + an "ok" line in
/// stdout).  Mirrors the manifest / cfg / fmt / verifier self-test
/// shape — only carries discovery + process plumbing, never any test
/// logic.
module Lyric.Emitter.Tests.SelfHostedContractMetaTests

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

/// Walk up from the test binary's base directory looking for the
/// self-test consumer.
let private findSelfTestSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate =
            Path.Combine(dir.Value.FullName, "lyric-compiler", "lyric", "contract_meta_self_test.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let tests =
    testList "Lyric.ContractMeta self-host (#1229 Phase A)" [
        // DEFERRED: Test pending #2580 (in-process bridge compiler-package resolution).
        // The contract_meta_self_test.l file imports Lyric.ContractMeta and Lyric.Parser
        // (compiler packages), which the bootstrap F# emitter cannot load via the in-process
        // bridge. This is a known infrastructure limitation. The test will pass once #2580
        // is fixed and the bridge gains compiler-package resolution support.
        ptestCase "[contract_meta_self_test_passes (DEFERRED #2580)]" <| fun () ->
            let src =
                match findSelfTestSource () with
                | Some path -> File.ReadAllText path
                | None ->
                    failwith
                        "cannot locate lyric-compiler/lyric/contract_meta_self_test.l — run from the source tree"

            let result, stdout, stderr, exitCode =
                compileAndRun "self_hosted_contract_meta" src

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
