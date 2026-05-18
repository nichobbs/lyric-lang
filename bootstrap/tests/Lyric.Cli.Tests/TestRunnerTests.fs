module Lyric.Cli.Tests.TestRunnerTests

/// End-to-end CLI tests for `lyric test`.  Each test writes a
/// Lyric source file, invokes the CLI, and asserts on stdout/stderr
/// + exit code.  Pinned shape:
///
///   * passing run    — exit 0, stdout contains TAP-style summary.
///   * failing run    — exit 1, "not ok" line for the failing test.
///   * no @test_module — exit 64, T0900 on stderr.
///   * user main      — exit 2,  T0902 on stderr.
///   * fixture        — exit 2,  T0901 on stderr.
///   * --list         — exit 0, prints titles only.
///   * --filter       — exit 0, only matching tests run, others
///                      reported as `# skip … (filter)`.
///   * property       — exit 0, property reported as skip.
///
/// See `docs/24-test-runner-plan.md` for the design.

open System
open System.Diagnostics
open System.IO
open Expecto

let private cliDll () : string =
    Path.Combine(AppContext.BaseDirectory, "lyric.dll")

let private runCli (args: string list) : string * string * int =
    let psi = ProcessStartInfo()
    psi.FileName <- "dotnet"
    psi.ArgumentList.Add "exec"
    psi.ArgumentList.Add (cliDll ())
    for a in args do psi.ArgumentList.Add a
    psi.UseShellExecute <- false
    psi.RedirectStandardOutput <- true
    psi.RedirectStandardError  <- true
    psi.CreateNoWindow <- true
    match Option.ofObj (Process.Start(psi)) with
    | None -> failwith "Process.Start returned null"
    | Some proc ->
        use proc = proc
        let stdout = proc.StandardOutput.ReadToEnd()
        let stderr = proc.StandardError.ReadToEnd()
        proc.WaitForExit()
        stdout, stderr, proc.ExitCode

let private freshSourcePath (label: string) (contents: string) : string =
    let dir =
        Path.Combine(Path.GetTempPath(),
                     "lyric-test-runner-" + label + "-"
                     + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory dir |> ignore
    let path = Path.Combine(dir, "tests.l")
    File.WriteAllText(path, contents)
    path

let private passingSource =
    "@test_module\n"
    + "package PassingTests\n"
    + "\n"
    + "import Std.Testing\n"
    + "\n"
    + "test \"addition\" { assertEqualInt(1 + 1, 2, \"add\") }\n"
    + "test \"truth\"    { assertTrue(true, \"yes\") }\n"

let private failingSource =
    "@test_module\n"
    + "package FailingTests\n"
    + "\n"
    + "import Std.Testing\n"
    + "\n"
    + "test \"good\" { assertTrue(true, \"yes\") }\n"
    + "test \"bad\"  { assertEqualInt(1 + 1, 3, \"math\") }\n"

let private noModuleSource =
    "package NoModule\n"
    + "\n"
    + "func main(): Unit { println(\"nothing\") }\n"

let private userMainSource =
    "@test_module\n"
    + "package UserMain\n"
    + "\n"
    + "import Std.Testing\n"
    + "\n"
    + "func main(): Unit { println(\"user\") }\n"
    + "test \"x\" { assertTrue(true, \"yes\") }\n"

let private fixtureSource =
    "@test_module\n"
    + "package WithFixture\n"
    + "\n"
    + "import Std.Testing\n"
    + "\n"
    + "fixture clock: Int = 0\n"
    + "\n"
    + "test \"x\" { assertTrue(true, \"yes\") }\n"

let private propertySource =
    "@test_module\n"
    + "package WithProperty\n"
    + "\n"
    + "import Std.Testing\n"
    + "\n"
    + "test \"passes\" { assertTrue(true, \"yes\") }\n"
    + "property \"prop\" forall (n: Int) { assertTrue(true, \"ok\") }\n"

let tests =
    testList "Lyric.Cli.Test" [

        testCase "passing tests exit 0 with TAP summary" <| fun () ->
            let path = freshSourcePath "pass" passingSource
            let stdout, _stderr, exitCode = runCli ["test"; path]
            Expect.equal exitCode 0 "passing tests should exit 0"
            Expect.stringContains stdout "1..2"          "TAP plan line"
            Expect.stringContains stdout "ok 1 - addition" "ok 1"
            Expect.stringContains stdout "ok 2 - truth"    "ok 2"
            Expect.stringContains stdout "# pass  2"     "pass count"
            Expect.stringContains stdout "# fail  0"     "fail count"

        testCase "failing tests exit 1 and report 'not ok'" <| fun () ->
            let path = freshSourcePath "fail" failingSource
            let stdout, _stderr, exitCode = runCli ["test"; path]
            Expect.equal exitCode 1 "a single failing test should exit 1"
            Expect.stringContains stdout "ok 1 - good"     "ok 1"
            Expect.stringContains stdout "not ok 2 - bad"  "failed test"
            Expect.stringContains stdout "# pass  1"       "pass count"
            Expect.stringContains stdout "# fail  1"       "fail count"

        testCase "missing @test_module exits 64 with T0900" <| fun () ->
            let path = freshSourcePath "nomod" noModuleSource
            let _stdout, stderr, exitCode = runCli ["test"; path]
            Expect.equal exitCode 64 "missing @test_module should be a usage error"
            Expect.stringContains stderr "T0900" "T0900 diagnostic"

        testCase "user-declared main exits 2 with T0902" <| fun () ->
            let path = freshSourcePath "usrmain" userMainSource
            let _stdout, stderr, exitCode = runCli ["test"; path]
            Expect.equal exitCode 2 "user main should be a compile-class error"
            Expect.stringContains stderr "T0902" "T0902 diagnostic"

        testCase "fixture declarations exit 2 with T0901" <| fun () ->
            let path = freshSourcePath "fix" fixtureSource
            let _stdout, stderr, exitCode = runCli ["test"; path]
            Expect.equal exitCode 2 "fixture is not yet supported"
            Expect.stringContains stderr "T0901" "T0901 diagnostic"

        testCase "--list prints titles only and runs nothing" <| fun () ->
            let path = freshSourcePath "list" passingSource
            let stdout, _stderr, exitCode = runCli ["test"; path; "--list"]
            Expect.equal exitCode 0 "--list always exits 0"
            Expect.stringContains stdout "addition" "first test title"
            Expect.stringContains stdout "truth"    "second test title"
            Expect.isFalse (stdout.Contains "1..")  "no TAP plan line"
            Expect.isFalse (stdout.Contains "# pass") "no summary"

        testCase "--filter restricts run, others reported as skip" <| fun () ->
            let path = freshSourcePath "filt" passingSource
            let stdout, _stderr, exitCode =
                runCli ["test"; path; "--filter"; "add"]
            Expect.equal exitCode 0 "filtered run with all matching tests passing"
            Expect.stringContains stdout "ok 1 - addition" "filter kept this"
            Expect.stringContains stdout "# skip 2 - truth (filter)"
                                          "filter dropped this"
            Expect.stringContains stdout "# pass  1" "pass count"
            Expect.stringContains stdout "# skip  1" "skip count"

        testCase "property declarations are reported as skipped" <| fun () ->
            let path = freshSourcePath "prop" propertySource
            let stdout, _stderr, exitCode = runCli ["test"; path]
            Expect.equal exitCode 0 "property is skipped, no failures"
            Expect.stringContains stdout "ok 1 - passes" "test ran"
            Expect.stringContains stdout "# skip 2 - prop" "property skipped"
            Expect.stringContains stdout "# skip  1" "skip count"
    ]
