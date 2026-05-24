/// Generic runner for the compiler self-tests at
/// `lyric-compiler/lyric/*_self_test.l`.
///
/// Each `.l` file in that directory is a standalone Lyric program that
/// imports the compiler subsystem it covers and uses `Std.Testing`
/// assertions to validate behaviour.  A clean exit (code 0) plus an
/// "ok" line in stdout means every in-program assertion held; any
/// failure panics and exits non-zero, surfacing as a test failure
/// here.
///
/// Discovery is automatic: drop a new `<subsystem>_self_test.l` file
/// in `lyric-compiler/lyric/` and it will be picked up on the next
/// run without any per-file F# scaffolding.
///
/// The runner intentionally skips files that are already covered by
/// a dedicated `SelfHosted<X>Tests.fs` wrapper so the same test does
/// not run twice during the migration window.  As wrappers are
/// removed in follow-up cleanup PRs, names should be removed from
/// `coveredByDedicatedWrapper` below.
module Lyric.Emitter.Tests.LyricCompilerSelfTests

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

/// File basenames (without `.l`) that already have a dedicated
/// `SelfHosted<X>Tests.fs` runner.  This runner skips them to avoid
/// double execution.  Shrinks over time as those wrappers are
/// deleted.
let private coveredByDedicatedWrapper : Set<string> =
    Set.ofList [
        "lexer_self_test"
        "parser_self_test"
        "typechecker_self_test"
        "fmt_self_test"
        "modechecker_self_test"
        "contract_elaborator_self_test"
        "test_synth_self_test"
        "manifest_self_test"
        "verifier_self_test"
        "derives_self_test"
        "mono_self_test"
        "generator_self_test"
    ]

/// Walk ancestor directories from the test binary's base looking for
/// the `lyric-compiler/lyric/` directory at the repo root.
let private locateCompilerLyricDir () : string option =
    let mutable dir = Some (DirectoryInfo(System.AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let d = dir.Value
        let candidate = Path.Combine(d.FullName, "lyric-compiler", "lyric")
        if Directory.Exists candidate then found <- Some candidate
        dir <- d.Parent |> Option.ofObj

    found

/// Build an assembly name from the file stem; replace non-identifier
/// characters with underscores.
let private assemblyNameOf (path: string) : string =
    let stem =
        match Option.ofObj (Path.GetFileNameWithoutExtension path) with
        | Some s -> s
        | None   -> "compiler_self_test"
    stem.Replace('-', '_').Replace('.', '_')

let private isCovered (path: string) : bool =
    let stem =
        match Option.ofObj (Path.GetFileNameWithoutExtension path) with
        | Some s -> s
        | None   -> ""
    coveredByDedicatedWrapper.Contains stem

/// Build one Expecto test per discovered `*_self_test.l` file that
/// is not already covered by a dedicated wrapper.
let private buildTests (rootDir: string) : Test list =
    Directory.GetFiles(rootDir, "*_self_test.l", SearchOption.AllDirectories)
    |> Array.filter (isCovered >> not)
    |> Array.sort
    |> Array.toList
    |> List.map (fun path ->
        let name   = assemblyNameOf path
        let label  = sprintf "[lyric-compiler/lyric/%s]" (Path.GetFileName path)
        testCase label <| fun () ->
            let source  = File.ReadAllText path
            let result, stdout, stderr, exitCode = compileAndRun name source
            Expect.equal exitCode 0
                (sprintf
                    "exit 0 (stderr=%s diagnostics=%A)"
                    stderr result.Diagnostics)
            Expect.stringContains stdout "ok"
                (sprintf "stdout should contain 'ok' (got: %s)" stdout))

let tests =
    match locateCompilerLyricDir () with
    | None ->
        testList "compiler self-tests (lyric-compiler/lyric/*_self_test.l)" [
            testCase "lyric-compiler/lyric directory not found" <| fun () ->
                failwithf
                    "could not locate lyric-compiler/lyric/ from %s"
                    System.AppContext.BaseDirectory
        ]
    | Some rootDir ->
        testSequenced
        <| testList "compiler self-tests (lyric-compiler/lyric/*_self_test.l)"
               (buildTests rootDir)
