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

/// Produce a clean output directory and stage every precompiled
/// `Lyric.Stdlib.<X>.dll` next to it so emitted assemblies that
/// `import Std.X` resolve their cross-assembly references at runtime.
/// `Lyric.Jvm.Hosts.dll` (Bucket D) and `FSharp.Core.dll` are copied
/// unconditionally — non-JVM / non-FSharp programs don't reference
/// them, but staging them uniformly keeps the test runner simple.
let prepareOutputDir (name: string) : string =
    let dir = Path.Combine(Path.GetTempPath(), "lyric-emit-" + name + "-" + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory(dir) |> ignore
    let jvmHosts =
        Path.Combine(AppContext.BaseDirectory, "Lyric.Jvm.Hosts.dll")
    if File.Exists jvmHosts then
        File.Copy(jvmHosts, Path.Combine(dir, "Lyric.Jvm.Hosts.dll"), overwrite = true)
    let fsharpCore =
        Path.Combine(AppContext.BaseDirectory, "FSharp.Core.dll")
    if File.Exists fsharpCore then
        File.Copy(fsharpCore, Path.Combine(dir, "FSharp.Core.dll"), overwrite = true)
    copyAllStdlibDlls dir
    dir

/// Compile + run a Lyric source string while the output directory
/// is still alive — the caller's `inspect` callback runs *before*
/// cleanup, so post-emit reads against the produced DLL (e.g.
/// `ContractMeta.readFromAssembly`) work.  The temporary output
/// directory is always deleted after `inspect` returns.
let compileAndRunWith
        (label:   string)
        (source:  string)
        (inspect: EmitResult * string * string * int -> 'a)
        : 'a =
    let outDir = prepareOutputDir label
    try
        let dll = Path.Combine(outDir, label + ".dll")
        let req =
            { Source             = source
              AssemblyName       = label
              OutputPath         = dll
              RestoredPackages   = []
              NugetAssemblyPaths = []
              ExternShimRoot     = None
              Target             = Dotnet
              ActiveFeatures     = Set.empty
              DeclaredFeatures   = Set.empty }
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
        inspect (r, stdout, stderr, exitCode)
    finally
        try Directory.Delete(outDir, recursive = true) with _ -> ()

/// Compile + run a Lyric source string. Returns the stdout/stderr/
/// exit-code triple plus the EmitResult so individual tests can
/// inspect diagnostics.  The temporary output directory is always
/// deleted after the run so test suites don't fill the disk.  Tests
/// that need to read the produced DLL (e.g. for embedded resources)
/// should use `compileAndRunWith` instead.
let compileAndRun (label: string) (source: string) : EmitResult * string * string * int =
    compileAndRunWith label source id
