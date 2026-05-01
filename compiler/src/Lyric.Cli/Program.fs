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

/// Build cache: when a `.lyric-cache` sidecar next to `outPath`
/// records the same SHA-256 fingerprint as the current source +
/// every stdlib `.l` file the resolver might pull in, and the
/// output PE itself still exists, the rebuild is skipped.
///
/// The fingerprint covers:
///   * the source bytes
///   * every file under `lyric/std/*.l` reachable from the source's
///     directory (or any ancestor that contains a `lyric/std/` dir)
///   * the running CLI assembly's mtime — bumped when the compiler
///     itself is rebuilt, invalidating the cache for free.
///
/// Stored as a single hex digest line in `<outPath>.lyric-cache`.
/// Pass `--force` to skip the cache and always rebuild.
module private BuildCache =

    open System.Security.Cryptography
    open System.Text

    let private appendBytes (sha: IncrementalHash) (bytes: byte array) =
        sha.AppendData bytes

    let private appendString (sha: IncrementalHash) (s: string) =
        appendBytes sha (Encoding.UTF8.GetBytes s)

    let private appendFile (sha: IncrementalHash) (path: string) =
        if File.Exists path then
            appendString sha path
            appendBytes sha (File.ReadAllBytes path)

    /// Locate the `lyric/std/` directory for cache fingerprinting.
    /// Checks `LYRIC_STD_PATH` first; falls back to walking up from `startDir`.
    let private locateStdlibFiles (startDir: string) : string list =
        let envDir =
            match Option.ofObj (Environment.GetEnvironmentVariable "LYRIC_STD_PATH") with
            | Some p when Directory.Exists p -> Some p
            | _ -> None
        let foundDir =
            match envDir with
            | Some d -> Some d
            | None ->
                let mutable dir = Some (DirectoryInfo(startDir))
                let mutable found : string option = None
                while found.IsNone && (Option.isSome dir) do
                    match dir with
                    | Some d ->
                        let candidate = Path.Combine(d.FullName, "lyric", "std")
                        if Directory.Exists candidate then found <- Some candidate
                        dir <- Option.ofObj d.Parent
                    | None -> ()
                found
        match foundDir with
        | Some stdDir ->
            Directory.GetFiles(stdDir, "*.l")
            |> Array.sort
            |> List.ofArray
        | None -> []

    let fingerprint (sourcePath: string) : string =
        use sha = IncrementalHash.CreateHash HashAlgorithmName.SHA256
        appendFile sha sourcePath
        let sourceDir =
            safeStr (Path.GetDirectoryName(Path.GetFullPath sourcePath)) "."
        for std in locateStdlibFiles sourceDir do
            appendFile sha std
        // Compiler-version bump: any rebuild of the CLI itself
        // invalidates user caches.
        let cliAsm =
            Path.Combine(AppContext.BaseDirectory, "lyric.dll")
        if File.Exists cliAsm then
            appendString sha (File.GetLastWriteTimeUtc(cliAsm).ToString "o")
        let bytes = sha.GetHashAndReset()
        let sb = StringBuilder(bytes.Length * 2)
        for b in bytes do sb.Append(b.ToString "x2") |> ignore
        sb.ToString()

    let sidecarPath (outPath: string) : string =
        outPath + ".lyric-cache"

    let isFresh (sourcePath: string) (outPath: string) : bool =
        let sidecar = sidecarPath outPath
        File.Exists outPath
        && File.Exists sidecar
        && (File.ReadAllText sidecar).Trim() = fingerprint sourcePath

    let stamp (sourcePath: string) (outPath: string) : unit =
        File.WriteAllText(sidecarPath outPath, fingerprint sourcePath)

/// Compile `sourcePath` and write a `.dll` to `outPath` (plus the
/// runtimeconfig + stdlib DLLs alongside).  Returns 0 on success,
/// 1 if any error diagnostics were emitted.  When `force = false`
/// and the build cache says the existing output is up to date, the
/// emit is skipped entirely and the CLI just confirms the cached
/// hit.
let private build (sourcePath: string) (outPath: string) (force: bool) : int =
    if (not force) && BuildCache.isFresh sourcePath outPath then
        printfn "up to date %s" outPath
        0
    else
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
        BuildCache.stamp sourcePath outPath
        printfn "built %s" outPath
        0
    | _ ->
        // Wipe a stale sidecar if the build failed, so the next
        // invocation isn't tricked into thinking the cache is fresh.
        let sidecar = BuildCache.sidecarPath outPath
        if File.Exists sidecar then File.Delete sidecar
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
    // Always force-build for `run` — the temp dir is fresh each
    // invocation so the cache check would always miss anyway, and
    // writing the sidecar there is wasted IO.
    let buildExit = build sourcePath outPath true
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
    printErr "  lyric build <source.l> [-o <output.dll>] [--force]"
    printErr "  lyric run   <source.l> [-- <args>...]"
    printErr "  lyric --version"
    printErr ""
    printErr "  build is incremental — re-running with the same source +"
    printErr "  stdlib closure skips the emit; pass --force to rebuild."

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
        let mutable force = false
        let mutable explicitOut : string option = None
        let mutable positional : string list = []
        let mutable cursor = rest
        while not (List.isEmpty cursor) do
            match cursor with
            | "--force" :: tail ->
                force <- true
                cursor <- tail
            | "-o" :: out :: tail ->
                explicitOut <- Some out
                cursor <- tail
            | s :: tail ->
                positional <- positional @ [s]
                cursor <- tail
            | [] -> ()
        match positional with
        | [] ->
            printErr "build: missing source file"
            printUsage ()
            1
        | sourcePath :: _ ->
            let outPath =
                match explicitOut with
                | Some o -> o
                | None ->
                    // Default: <source-dir>/<basename>.dll
                    let dir =
                        safeStr (Path.GetDirectoryName(Path.GetFullPath sourcePath)) "."
                    let name =
                        safeStr (Path.GetFileNameWithoutExtension sourcePath) "out"
                    Path.Combine(dir, name + ".dll")
            build sourcePath outPath force
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
