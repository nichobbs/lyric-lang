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

/// Copy every cached `Lyric.Stdlib.<X>.dll` into `outDir` so user
/// programs that import multiple `Std.X` modules can resolve every
/// cross-assembly reference at runtime.
let private copyAllStdlibDlls (outDir: string) : unit =
    for p in Lyric.Emitter.Emitter.stdlibAssemblyPaths () do
        if File.Exists p then
            let fname =
                match Option.ofObj (Path.GetFileName p) with
                | Some f -> f
                | None   -> "Lyric.Stdlib.Core.dll"
            File.Copy(p, Path.Combine(outDir, fname), overwrite = true)

/// Produce a clean output directory and copy the stdlib next to it.
/// Also copies any precompiled `Lyric.Stdlib.<X>.dll` if it exists,
/// so emitted assemblies that `import Std.X` can satisfy their
/// cross-assembly references at runtime.
let prepareOutputDir (name: string) : string =
    let dir = Path.Combine(Path.GetTempPath(), "lyric-emit-" + name + "-" + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory(dir) |> ignore
    File.Copy(stdlibDll (), Path.Combine(dir, "Lyric.Stdlib.dll"), overwrite = true)
    copyAllStdlibDlls dir
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
    // The emit may have lazily precompiled extra `Std.X` modules.
    // Copy any newly cached DLLs over so the runtime probing path
    // resolves every cross-assembly reference.
    copyAllStdlibDlls outDir
    let stdout, stderr, exitCode =
        match r.OutputPath with
        | Some _ -> runDll dll
        | None ->
            let diagText =
                r.Diagnostics
                |> List.map (fun d ->
                    sprintf "[%A %s] %s" d.Severity d.Code d.Message)
                |> String.concat "\n"
            "", diagText, -1
    r, stdout, stderr, exitCode
