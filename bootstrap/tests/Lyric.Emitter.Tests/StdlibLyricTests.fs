/// Runner for the Lyric-language test suite at `stdlib/tests/*.l`.
///
/// Each `.l` file in that directory is a standalone Lyric program that
/// imports the stdlib modules it covers and uses `Std.Testing` assertions
/// (`assertEqual`, `assertEqualInt`, `assertTrue`) to validate behaviour.
/// A clean exit (code 0) means every assertion held; any failure panics
/// and exits non-zero, surfacing as a test failure here.
///
/// Discovery is automatic: drop a new `<module>_tests.l` file in
/// `stdlib/tests/` and it will be picked up on the next run without any
/// changes to this file.
module Lyric.Emitter.Tests.StdlibLyricTests

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

/// Walk ancestor directories from the test binary's base looking for
/// the `stdlib/tests/` directory that lives at the repo root.
let private locateStdlibTestsDir () : string option =
    let mutable dir = Some (DirectoryInfo(System.AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let d = dir.Value
        let candidate = Path.Combine(d.FullName, "stdlib", "tests")
        if Directory.Exists candidate then found <- Some candidate
        dir <- d.Parent |> Option.ofObj
    found

/// Read `path` and build an assembly name from the filename stem.
/// The assembly name must be valid as a C# identifier; replace hyphens
/// and dots with underscores.
let private assemblyNameOf (path: string) : string =
    let stem =
        match Option.ofObj (Path.GetFileNameWithoutExtension path) with
        | Some s -> s
        | None   -> "stdlib_test"
    stem.Replace('-', '_').Replace('.', '_')

/// Build one Expecto test per `.l` file in `stdlib/tests/`.
/// The test compiles the file and runs the resulting PE; success = exit 0.
let private buildTests (testsDir: string) : Test list =
    Directory.GetFiles(testsDir, "*_tests.l", SearchOption.TopDirectoryOnly)
    |> Array.sort
    |> Array.toList
    |> List.map (fun path ->
        let name   = assemblyNameOf path
        let label  = sprintf "[stdlib/tests/%s]" (Path.GetFileName path)
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
    match locateStdlibTestsDir () with
    | None ->
        testList "stdlib Lyric tests (stdlib/tests/*.l)" [
            testCase "stdlib/tests directory not found" <| fun () ->
                failwithf
                    "could not locate stdlib/tests/ from %s"
                    System.AppContext.BaseDirectory
        ]
    | Some testsDir ->
        testSequenced
        <| testList "stdlib Lyric tests (stdlib/tests/*.l)"
               (buildTests testsDir)
