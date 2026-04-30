/// `lyric` — bootstrap CLI front-end for the Lyric compiler.
///
/// Usage
/// -----
/// ```
/// lyric build <source.l> [-o <output.dll>]
///   Compiles the given source to a runnable .dll alongside its
///   runtimeconfig.json and any precompiled stdlib DLLs.
///
/// lyric run <source.l> [-- <args>...]
///   Builds (to a temp dir) and immediately executes the program.
///
/// lyric --version
///   Prints the bootstrap compiler version.
/// ```
///
/// The CLI is a thin wrapper over `Lyric.Emitter.Emitter.emit`: it
/// resolves the source path, picks a default output path next to the
/// source if `-o` is omitted, copies `Lyric.Stdlib.dll` and any
/// precompiled `Lyric.Stdlib.<X>.dll` into the output directory, and
/// writes a sibling `runtimeconfig.json` so `dotnet exec` can pick up
/// the right runtime version.  Diagnostics are printed in the same
/// `<code> <line>:<col>: <message>` shape the test kit produces.
module Lyric.Cli.Program

open System
open System.IO
open Lyric.Lexer
open Lyric.Emitter

let private VERSION = "0.1.0-bootstrap"

let private printErr (s: string) : unit =
    Console.Error.WriteLine s

let private safeStr (s: string | null) (fallback: string) : string =
    match Option.ofObj s with
    | Some v -> v
    | None   -> fallback

let private printDiag (d: Diagnostic) : unit =
    let sev =
        match d.Severity with
        | DiagError   -> "error"
        | DiagWarning -> "warning"
    let span = d.Span
    printErr (sprintf "%s %s [%d:%d]: %s"
                d.Code sev span.Start.Line span.Start.Column d.Message)

let private locateStdlibDll () : string option =
    // Adjacent to the CLI assembly during `dotnet run` and also after
    // `dotnet publish`; the build copies Lyric.Stdlib.dll over via
    // the project reference.
    let candidate =
        Path.Combine(AppContext.BaseDirectory, "Lyric.Stdlib.dll")
    if File.Exists candidate then Some candidate else None

/// Write a minimal `runtimeconfig.json` next to the produced PE so
/// `dotnet exec` knows which runtime to load.
let private writeRuntimeConfig (dllPath: string) : unit =
    let configPath =
        safeStr (Path.ChangeExtension(dllPath, ".runtimeconfig.json"))
                (dllPath + ".runtimeconfig.json")
    let runtimeVersion = Environment.Version
    let json =
        let sb = System.Text.StringBuilder()
        sb.AppendLine "{" |> ignore
        sb.AppendLine "  \"runtimeOptions\": {" |> ignore
        sb.AppendLine (sprintf "    \"tfm\": \"net%d.%d\","
                        runtimeVersion.Major runtimeVersion.Minor) |> ignore
        sb.AppendLine "    \"framework\": {" |> ignore
        sb.AppendLine "      \"name\": \"Microsoft.NETCore.App\"," |> ignore
        sb.AppendLine (sprintf "      \"version\": \"%s\""
                        (runtimeVersion.ToString())) |> ignore
        sb.AppendLine "    }" |> ignore
        sb.AppendLine "  }" |> ignore
        sb.AppendLine "}" |> ignore
        sb.ToString()
    File.WriteAllText(configPath, json)

/// Copy the F# stdlib shim + any precompiled `Lyric.Stdlib.<X>.dll`
/// into `outDir` so `dotnet exec` resolves cross-assembly references.
let private copyStdlibArtifacts (outDir: string) : unit =
    match locateStdlibDll () with
    | Some src ->
        File.Copy(src, Path.Combine(outDir, "Lyric.Stdlib.dll"), overwrite = true)
    | None ->
        printErr "warning: Lyric.Stdlib.dll not found alongside the CLI; runtime resolution may fail"
    for p in Lyric.Emitter.Emitter.stdlibAssemblyPaths () do
        if File.Exists p then
            let fname =
                match Option.ofObj (Path.GetFileName p) with
                | Some f -> f
                | None   -> "Lyric.Stdlib.<unknown>.dll"
            File.Copy(p, Path.Combine(outDir, fname), overwrite = true)

/// Compile `sourcePath` and write a `.dll` to `outPath` (plus the
/// runtimeconfig + stdlib DLLs alongside).  Returns 0 on success,
/// 1 if any error diagnostics were emitted.
let private build (sourcePath: string) (outPath: string) : int =
    let source = File.ReadAllText sourcePath
    let outDir =
        safeStr (Path.GetDirectoryName(Path.GetFullPath outPath)) "."
    Directory.CreateDirectory(outDir) |> ignore
    let assemblyName =
        safeStr (Path.GetFileNameWithoutExtension outPath) "out"
    let req : Emitter.EmitRequest =
        { Source       = source
          AssemblyName = assemblyName
          OutputPath   = outPath }
    let mutable hadError = false
    let result =
        try
            Emitter.emit req
        with e ->
            // Codegen still uses `failwithf` for unsupported
            // constructs (e.g. `s[i]` on a String).  Surface those
            // as a single error diagnostic so the CLI exits cleanly
            // with `1` instead of a stack trace.
            hadError <- true
            printErr (sprintf "internal error: %s" e.Message)
            { OutputPath  = None
              Diagnostics = [] }
    for d in result.Diagnostics do
        if d.Severity = DiagError then hadError <- true
        printDiag d
    match result.OutputPath with
    | Some _ when not hadError ->
        writeRuntimeConfig outPath
        copyStdlibArtifacts outDir
        printfn "built %s" outPath
        0
    | _ ->
        printErr (sprintf "%s: build failed" sourcePath)
        1

/// Build to a temp directory and `dotnet exec` the produced PE.
let private run (sourcePath: string) (args: string array) : int =
    let tmp =
        Path.Combine(Path.GetTempPath(),
                     "lyric-run-" + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory(tmp) |> ignore
    let outPath =
        Path.Combine(tmp,
                     safeStr (Path.GetFileNameWithoutExtension sourcePath) "out"
                     + ".dll")
    let buildExit = build sourcePath outPath
    if buildExit <> 0 then buildExit
    else
        let psi = Diagnostics.ProcessStartInfo()
        psi.FileName <- "dotnet"
        psi.ArgumentList.Add "exec"
        psi.ArgumentList.Add outPath
        for a in args do psi.ArgumentList.Add a
        psi.UseShellExecute <- false
        let proc =
            match Option.ofObj (Diagnostics.Process.Start psi) with
            | Some p -> p
            | None ->
                printErr "failed to start dotnet"
                exit 1
        use _ = proc
        proc.WaitForExit()
        proc.ExitCode

let private printUsage () : unit =
    printErr "Usage:"
    printErr "  lyric build <source.l> [-o <output.dll>]"
    printErr "  lyric run   <source.l> [-- <args>...]"
    printErr "  lyric --version"

[<EntryPoint>]
let main (argv: string array) : int =
    let args = List.ofArray argv
    match args with
    | [] ->
        printUsage ()
        1
    | "--version" :: _ | "-v" :: _ ->
        printfn "lyric %s" VERSION
        0
    | "build" :: rest ->
        match rest with
        | [] ->
            printErr "build: missing source file"
            printUsage ()
            1
        | sourcePath :: more ->
            let outPath =
                match more with
                | "-o" :: out :: _ -> out
                | _ ->
                    // Default: <source-dir>/<basename>.dll
                    let dir =
                        safeStr (Path.GetDirectoryName(Path.GetFullPath sourcePath)) "."
                    let name =
                        safeStr (Path.GetFileNameWithoutExtension sourcePath) "out"
                    Path.Combine(dir, name + ".dll")
            build sourcePath outPath
    | "run" :: rest ->
        match rest with
        | [] ->
            printErr "run: missing source file"
            printUsage ()
            1
        | sourcePath :: more ->
            let userArgs =
                match more with
                | "--" :: rest -> List.toArray rest
                | _            -> List.toArray more
            run sourcePath userArgs
    | unknown :: _ ->
        printErr (sprintf "unknown command: %s" unknown)
        printUsage ()
        1
