/// End-to-end tests for `Std.Testing.Snapshot` (Phase 3 / D-progress-063).
///
/// Each test runs a Lyric program in a temp dir and verifies the
/// snapshot file is created on first run, returns true on match,
/// and returns false on mismatch.
module Lyric.Emitter.Tests.SnapshotTestingTests

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private tempDir () : string =
    let d = Path.Combine(Path.GetTempPath(),
                         "lyric-snapshot-" + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory d |> ignore
    d

let private withTempDir (action: string -> 'a) : 'a =
    let dir = tempDir ()
    let cwd = Directory.GetCurrentDirectory()
    try
        Directory.SetCurrentDirectory(dir)
        try action dir
        finally Directory.SetCurrentDirectory(cwd)
    finally
        try Directory.Delete(dir, true) with _ -> ()

let tests =
    testSequenced
    <| testList "Std.Testing.Snapshot (D-progress-063)" [

        testCase "[first run writes snapshot and returns true]" <| fun () ->
            withTempDir (fun dir ->
                let source =
                    "package STS1\nimport Std.Core\nimport Std.Testing.Snapshot\n\n"
                    + "func main(): Unit {\n"
                    + "  match snapshot(\"hello\", \"hi from snapshot\") {\n"
                    + "    case Ok(b) -> println(toString(b))\n"
                    + "    case Err(_) -> println(\"err\")\n"
                    + "  }\n"
                    + "}\n"
                let _, stdout, stderr, exitCode = compileAndRun "snap_first_run" source
                Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
                Expect.equal (stdout.TrimEnd()) "True" "first run accepts"
                let snapPath = Path.Combine(dir, "snapshots", "hello.txt")
                Expect.isTrue (File.Exists snapPath) "snapshot file written"
                Expect.equal (File.ReadAllText snapPath) "hi from snapshot"
                    "snapshot content matches actual")

        testCase "[matching second run returns true]" <| fun () ->
            withTempDir (fun dir ->
                Directory.CreateDirectory(Path.Combine(dir, "snapshots")) |> ignore
                File.WriteAllText(
                    Path.Combine(dir, "snapshots", "match.txt"),
                    "expected content")
                let source =
                    "package STS2\nimport Std.Core\nimport Std.Testing.Snapshot\n\n"
                    + "func main(): Unit {\n"
                    + "  match snapshot(\"match\", \"expected content\") {\n"
                    + "    case Ok(b) -> println(toString(b))\n"
                    + "    case Err(_) -> println(\"err\")\n"
                    + "  }\n"
                    + "}\n"
                let _, stdout, stderr, exitCode = compileAndRun "snap_match" source
                Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
                Expect.equal (stdout.TrimEnd()) "True" "match returns true")

        testCase "[mismatched second run returns false]" <| fun () ->
            withTempDir (fun dir ->
                Directory.CreateDirectory(Path.Combine(dir, "snapshots")) |> ignore
                File.WriteAllText(
                    Path.Combine(dir, "snapshots", "diff.txt"),
                    "stored content")
                let source =
                    "package STS3\nimport Std.Core\nimport Std.Testing.Snapshot\n\n"
                    + "func main(): Unit {\n"
                    + "  match snapshot(\"diff\", \"different content\") {\n"
                    + "    case Ok(b) -> println(toString(b))\n"
                    + "    case Err(_) -> println(\"err\")\n"
                    + "  }\n"
                    + "}\n"
                let _, stdout, stderr, exitCode = compileAndRun "snap_mismatch" source
                Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
                Expect.equal (stdout.TrimEnd()) "False" "mismatch returns false")

        testCase "[snapshotMatch panics on mismatch]" <| fun () ->
            withTempDir (fun dir ->
                Directory.CreateDirectory(Path.Combine(dir, "snapshots")) |> ignore
                File.WriteAllText(
                    Path.Combine(dir, "snapshots", "fail.txt"),
                    "old")
                let source =
                    "package STS4\nimport Std.Core\nimport Std.Testing.Snapshot\n\n"
                    + "func main(): Unit {\n"
                    + "  snapshotMatch(\"fail\", \"new\")\n"
                    + "}\n"
                let _, _, _, exitCode = compileAndRun "snap_panic" source
                Expect.notEqual exitCode 0 "snapshotMatch panics on mismatch")
    ]
