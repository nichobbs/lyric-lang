/// End-to-end tests for the self-hosted MULTI-package MSIL bridge
/// (`Msil.Bridge.compileProjectToMsilEncoded`).  Compiles a list of
/// Lyric package payloads through the full self-hosted pipeline against
/// a single shared `LoweringCtx` and runs the resulting bundled DLL,
/// asserting on stdout output.
///
/// Phase 1 scope (#1183): independent packages — each package compiles
/// standalone, no cross-package imports between them.  The bug fix from
/// #1180 (cross-package `Result[Option[T]]` `case None`) is regression-
/// covered for the F# `emitProject` path in
/// `Lyric.Emitter.Tests.CrossPackageOptionMatchTests`; the same coverage
/// will be added against this self-hosted path once Phase 2
/// (cross-package import resolution) lands.
module Lyric.Cli.Tests.SelfHostedMsilProjectBridgeTests

open System
open System.IO
open System.Diagnostics
open Expecto
open Lyric.Cli

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
        proc.WaitForExit()
    stdoutTask.Result, stderrTask.Result, proc.ExitCode

let tests =
    testList "self-hosted MSIL multi-package bridge (#1183)" [

        // Two independent packages bundle into one PE.  The library
        // package defines a helper `pub func`; the consumer is a single-
        // package program with `main` that doesn't import the library.
        // This pins the multi-package row-numbering refactor: package B's
        // `addPackageTokens` resumes from where package A left off, so the
        // bundle's MethodDef table is well-formed and `dotnet exec` loads
        // the assembly without complaint.
        testCase "[two_independent_packages_bundle]" <| fun () ->
            let dir =
                Path.Combine(
                    Path.GetTempPath(),
                    "lyric-msil-proj-bridge-twoindep-" + Guid.NewGuid().ToString("N"))
            Directory.CreateDirectory dir |> ignore
            try
                let dllPath = Path.Combine(dir, "TwoIndep.dll")
                let pkgLib =
                    "package TwoIndep.Lib\n" +
                    "\n" +
                    "pub func doubled(x: in Int): Int { x + x }\n"
                let pkgApp =
                    "package TwoIndep.App\n" +
                    "\n" +
                    "func main(): Unit {\n" +
                    "  println(7)\n" +
                    "}\n"
                let ok =
                    SelfHostedMsilProject.compileProjectToDll
                        [ "TwoIndep.Lib", pkgLib
                          "TwoIndep.App", pkgApp ]
                        "TwoIndep"
                        dllPath
                Expect.isTrue ok
                    "self-hosted multi-package compile should succeed for two independent packages"
                Expect.isTrue (File.Exists dllPath)
                    (sprintf "bundled DLL exists at %s" dllPath)
                let stdout, stderr, exitCode = runDll dllPath
                Expect.equal exitCode 0
                    (sprintf "exit 0 (stderr=%s)" stderr)
                Expect.equal (stdout.TrimEnd()) "7"
                    "main() in second package runs after both packages are bundled"
            finally
                try Directory.Delete(dir, recursive = true) with _ -> ()

        // Verify the row-counter refactor: when the FIRST package contains
        // a record (which contributes a .ctor MethodDef row), the second
        // package's funcs must land at row N + 1, not row 2.  Pre-refactor
        // this would have miscounted and the bundle would have failed
        // verification at runtime.
        testCase "[first_package_with_record_does_not_disturb_second]" <| fun () ->
            let dir =
                Path.Combine(
                    Path.GetTempPath(),
                    "lyric-msil-proj-bridge-rowoffset-" + Guid.NewGuid().ToString("N"))
            Directory.CreateDirectory dir |> ignore
            try
                let dllPath = Path.Combine(dir, "RowOffset.dll")
                // Pkg A defines a record (so its lowerMRecord contributes one
                // FieldDef + one .ctor MethodDef row before any IFunc rows).
                let pkgA =
                    "package RowOffset.A\n" +
                    "\n" +
                    "pub record Point { x: Int }\n" +
                    "\n" +
                    "pub func makeOne(): Int { 1 }\n"
                // Pkg B is a plain main-bearing program.
                let pkgB =
                    "package RowOffset.B\n" +
                    "\n" +
                    "func main(): Unit {\n" +
                    "  println(42)\n" +
                    "}\n"
                let ok =
                    SelfHostedMsilProject.compileProjectToDll
                        [ "RowOffset.A", pkgA
                          "RowOffset.B", pkgB ]
                        "RowOffset"
                        dllPath
                Expect.isTrue ok
                    "compile succeeds even when the first package contributes record + func rows"
                let stdout, stderr, exitCode = runDll dllPath
                Expect.equal exitCode 0
                    (sprintf "exit 0 (stderr=%s)" stderr)
                Expect.equal (stdout.TrimEnd()) "42"
                    "main() in package B picks up the correct entry-point token after the row offset"
            finally
                try Directory.Delete(dir, recursive = true) with _ -> ()
    ]
