/// Shared helpers for emit tests: compile a Lyric source string,
/// `dotnet exec` the resulting .dll, and return its stdout/stderr/
/// exit-code triple. Lives in its own module so each slice's test
/// file can stay focused on the cases it cares about.
module Lyric.Emitter.Tests.EmitTestKit

open System
open System.Diagnostics
open System.IO
open Lyric.Emitter.Emitter

let private dotnetHost () : string =
    let envPath = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH")
    match Option.ofObj envPath with
    | Some p when File.Exists p -> p
    | _ ->
        let primary = "/root/.dotnet/dotnet"
        if File.Exists primary then primary
        else "dotnet"

/// `dotnet exec` the produced .dll under the same host the test
/// process is using, capturing stdout / stderr / exit code.
let runDll (dll: string) : string * string * int =
    let psi = ProcessStartInfo()
    psi.FileName <- dotnetHost ()
    psi.ArgumentList.Add "exec"
    psi.ArgumentList.Add dll
    psi.RedirectStandardOutput <- true
    psi.RedirectStandardError  <- true
    psi.UseShellExecute         <- false
    psi.CreateNoWindow          <- true
    let proc =
        match Option.ofObj (Process.Start(psi)) with
        | Some p -> p
        | None   -> failwith "failed to start dotnet process"
    use _ = proc
    let stdout = proc.StandardOutput.ReadToEnd()
    let stderr = proc.StandardError.ReadToEnd()
    proc.WaitForExit()
    stdout, stderr, proc.ExitCode

/// Path to the in-tree Lyric.Stdlib.dll that the emitted assembly
/// references. The runtime probing finds it next to the produced PE.
let private stdlibDll () : string =
    let baseDir = AppContext.BaseDirectory
    Path.Combine(baseDir, "Lyric.Stdlib.dll")

/// Produce a clean output directory and copy the stdlib next to it.
let prepareOutputDir (name: string) : string =
    let dir = Path.Combine(Path.GetTempPath(), "lyric-emit-" + name + "-" + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory(dir) |> ignore
    File.Copy(stdlibDll (), Path.Combine(dir, "Lyric.Stdlib.dll"), overwrite = true)
    dir

/// Compile + run a Lyric source string. Returns the stdout/stderr/
/// exit-code triple plus the EmitResult so individual tests can
/// inspect diagnostics.
let compileAndRun (label: string) (source: string) : EmitResult * string * string * int =
    let outDir = prepareOutputDir label
    let dll    = Path.Combine(outDir, label + ".dll")
    let req =
        { Source       = source
          AssemblyName = label
          OutputPath   = dll }
    let r = emit req
    let stdout, stderr, exitCode =
        match r.OutputPath with
        | Some _ -> runDll dll
        | None   -> "", "", -1
    r, stdout, stderr, exitCode
