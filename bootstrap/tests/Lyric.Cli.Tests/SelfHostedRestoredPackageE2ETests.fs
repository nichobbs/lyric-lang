/// Slice 3 of #1229 — end-to-end proof that the self-hosted MSIL bridge
/// builds DLLs whose embedded `Lyric.Contract` resource can be read by
/// the in-process restored-packages loader and used to compile a
/// downstream consumer.  Routes the entire build chain through the
/// self-hosted pipeline (`Msil.Bridge`), so a passing run demonstrates
/// the F# `--internal-project-build` subprocess fallback is no longer on
/// the critical path for `.NET` cross-package builds.
module Lyric.Cli.Tests.SelfHostedRestoredPackageE2ETests

open System
open System.IO
open System.Diagnostics
open Expecto
open Lyric.Cli
open Lyric.Emitter

let private runDll (dll: string) : string * string * int =
    let dotnet =
        let env = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH")
        match Option.ofObj env with
        | Some p when File.Exists p -> p
        | _ ->
            let p = "/root/.dotnet/dotnet"
            if File.Exists p then p else "dotnet"
    let psi = ProcessStartInfo()
    psi.FileName <- dotnet
    psi.ArgumentList.Add "exec"
    psi.ArgumentList.Add dll
    psi.RedirectStandardOutput <- true
    psi.RedirectStandardError  <- true
    psi.UseShellExecute         <- false
    psi.CreateNoWindow          <- true
    let proc =
        match Option.ofObj (Process.Start psi) with
        | Some p -> p
        | None   -> failwith "failed to start dotnet process"
    use _ = proc
    let stdoutTask = System.Threading.Tasks.Task.Run(fun () -> proc.StandardOutput.ReadToEnd())
    let stderrTask = System.Threading.Tasks.Task.Run(fun () -> proc.StandardError.ReadToEnd())
    let exited = proc.WaitForExit(60_000)
    if not exited then
        try proc.Kill() with _ -> ()
        // Bounded post-Kill wait — on Linux SIGKILL / Windows TerminateProcess
        // the OS normally collects within milliseconds, but a zombie kernel
        // state shouldn't hang the test runner indefinitely.  Temp files are
        // already in workDir which cleanup handles.
        let _ = proc.WaitForExit(5_000)
        ()
    stdoutTask.Result, stderrTask.Result, proc.ExitCode

let tests =
    testList "Lyric.Cli.SelfHostedRestoredPackageE2E (#1229 slice 3)" [

        testCase "[self_hosted_bridge_round_trip]" <| fun () ->
            // 1. Build a producer library DLL through the self-hosted MSIL
            //    bridge.  Slice 2b's `embedLyricContract` is what makes
            //    this DLL a valid restored dep.
            let workDir =
                Path.Combine(Path.GetTempPath(),
                             "lyric-self-hosted-e2e-" + Guid.NewGuid().ToString("N"))
            Directory.CreateDirectory workDir |> ignore
            try
                let producerDll = Path.Combine(workDir, "Lyric.SelfHostedE2E.Greeter.dll")
                let producerSource = """package Lyric.SelfHostedE2E.Greeter

pub func greet(name: in String): String { "hello, " + name }

func main(): Unit { () }
"""
                let producerOk = SelfHostedMsil.compileToDll producerSource producerDll
                Expect.isTrue producerOk
                    "self-hosted bridge produced the producer DLL"
                Expect.isTrue (File.Exists producerDll)
                    (sprintf "producer DLL exists at %s" producerDll)

                // 2. Confirm the producer DLL ships an embedded
                //    `Lyric.Contract` resource — this is the slice-2b
                //    deliverable that makes the in-process loader path
                //    work.  Reading via the F#-side
                //    `ContractMeta.readFromAssembly` is just byte-level
                //    inspection; the bytes themselves were written by
                //    the self-hosted PE writer.
                let contractJson =
                    match Lyric.Emitter.ContractMeta.readFromAssembly producerDll with
                    | Some json -> json
                    | None      -> failwith "producer DLL has no embedded Lyric.Contract resource"
                Expect.stringContains contractJson "Lyric.SelfHostedE2E.Greeter"
                    "contract resource names the producer package"
                // Match `"name":"greet"` (no spaces — `contractToJson` emits
                // compact JSON) so the assertion fires on the JSON name
                // field rather than any substring of the package name or
                // a private field that happens to contain "greet".
                Expect.stringContains contractJson "\"name\":\"greet\""
                    "contract resource includes the public greet function"

                // 3. Build a consumer through the self-hosted bridge,
                //    threading the producer DLL as a restored dep.  The
                //    bridge internally loads + synthesises the contract
                //    so the consumer's `import Lyric.SelfHostedE2E.Greeter`
                //    typechecks.
                let consumerDll = Path.Combine(workDir, "consumer.dll")
                let consumerSource = """package Lyric.SelfHostedE2E.Consumer

import Lyric.SelfHostedE2E.Greeter

func main(): Unit {
  println(greet("world"))
}
"""
                let consumerOk =
                    SelfHostedMsilProject.compileProjectWithRestored
                        [("Lyric.SelfHostedE2E.Consumer", consumerSource)]
                        "consumer"
                        consumerDll
                        [producerDll]
                        ""
                Expect.isTrue consumerOk
                    "self-hosted bridge built the consumer with the restored dep"
                Expect.isTrue (File.Exists consumerDll)
                    "consumer DLL exists"

                // 4. `dotnet exec` the consumer.  The producer DLL is
                //    already in `workDir` next to the consumer, so .NET
                //    app-base probing resolves the cross-assembly call.
                //    Assert the greeting bubbled through from the
                //    restored package.
                let stdout, stderr, exitCode = runDll consumerDll
                Expect.equal exitCode 0
                    (sprintf "consumer exit 0 expected (stderr=%s)" stderr)
                Expect.equal (stdout.TrimEnd()) "hello, world"
                    "cross-package call returned the producer's greeting"
            finally
                try Directory.Delete(workDir, recursive = true) with _ -> ()

        testCase "[manifest_version_threads_to_assembly_and_contract]" <| fun () ->
            // #1364 — when the CLI threads a `[package].version` string
            // through `compileToMsilWithVersion`, the bridge writes that
            // version into the embedded `Lyric.Contract` resource and the
            // Assembly row's major/minor.  Slice 3's E2E test exercised
            // the threading-disabled (empty version) path; this test
            // exercises the threading-enabled path.
            let workDir =
                Path.Combine(Path.GetTempPath(),
                             "lyric-version-thread-e2e-" + Guid.NewGuid().ToString("N"))
            Directory.CreateDirectory workDir |> ignore
            try
                let producerDll = Path.Combine(workDir, "Lyric.VersionTest.Demo.dll")
                let producerSource = """package Lyric.VersionTest.Demo

pub func answer(): Int { 42 }

func main(): Unit { () }
"""
                let producerOk =
                    SelfHostedMsil.compileToDllWithVersion
                        producerSource producerDll "2.3.4"
                Expect.isTrue producerOk
                    "self-hosted bridge produced the producer DLL with version"
                Expect.isTrue (File.Exists producerDll)
                    "producer DLL exists"

                let contractJson =
                    match Lyric.Emitter.ContractMeta.readFromAssembly producerDll with
                    | Some json -> json
                    | None      -> failwith "producer DLL has no embedded Lyric.Contract"
                // The threaded "2.3.4" lands in the contract's top-level
                // `version` JSON field.  `contractToJson` emits pretty
                // formatting (one field per line, space after colon) for
                // the outer Contract record, so match that shape.  Empty-
                // version compiles previously wrote "0.0.0" here; this
                // assertion proves the threading.
                Expect.stringContains contractJson "\"version\": \"2.3.4\""
                    "manifest version threaded into Lyric.Contract"

                // The Assembly metadata row should carry major=2, minor=3 —
                // the patch segment is dropped (ECMA-335 only has major /
                // minor / build / revision).  Read it back via
                // `AssemblyName.Version` for a structural assertion.
                let asmName =
                    System.Reflection.AssemblyName.GetAssemblyName producerDll
                let ver =
                    match Option.ofObj asmName.Version with
                    | Some v -> v
                    | None   -> failwith "Assembly had no Version row"
                Expect.equal ver.Major 2 "Assembly row carries major=2"
                Expect.equal ver.Minor 3 "Assembly row carries minor=3"
            finally
                try Directory.Delete(workDir, recursive = true) with _ -> ()
    ]
