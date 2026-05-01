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
/// `FSharp.Core.dll` (next to the CLI binary) is also copied: any F#
/// member on `Lyric.Stdlib` whose IL references FSharp.Core helpers
/// (e.g. `Array.zeroCreate`) needs the assembly resolvable at runtime.
let private copyStdlibArtifacts (outDir: string) : unit =
    match locateStdlibDll () with
    | Some src ->
        File.Copy(src, Path.Combine(outDir, "Lyric.Stdlib.dll"), overwrite = true)
    | None ->
        printErr "warning: Lyric.Stdlib.dll not found alongside the CLI; runtime resolution may fail"
    let fsharpCore =
        Path.Combine(AppContext.BaseDirectory, "FSharp.Core.dll")
    if File.Exists fsharpCore then
        File.Copy(fsharpCore, Path.Combine(outDir, "FSharp.Core.dll"), overwrite = true)
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

/// Detect the host RID (e.g. `linux-x64`) by inspecting
/// `System.Runtime.InteropServices.RuntimeInformation`.  Used to
/// drive `dotnet publish -r <RID>` for native-AOT builds when the
/// user doesn't pass an explicit `--rid`.
let private hostRid () : string =
    let arch =
        match System.Runtime.InteropServices.RuntimeInformation.OSArchitecture with
        | System.Runtime.InteropServices.Architecture.X64   -> "x64"
        | System.Runtime.InteropServices.Architecture.Arm64 -> "arm64"
        | System.Runtime.InteropServices.Architecture.X86   -> "x86"
        | other -> other.ToString().ToLowerInvariant()
    let os =
        if System.Runtime.InteropServices.RuntimeInformation.IsOSPlatform
              System.Runtime.InteropServices.OSPlatform.Linux then "linux"
        elif System.Runtime.InteropServices.RuntimeInformation.IsOSPlatform
                System.Runtime.InteropServices.OSPlatform.OSX then "osx"
        elif System.Runtime.InteropServices.RuntimeInformation.IsOSPlatform
                System.Runtime.InteropServices.OSPlatform.Windows then "win"
        else "linux"
    sprintf "%s-%s" os arch

/// Run `dotnet publish` against a generated wrapper csproj that
/// references the user's emitted Lyric DLL + every cached
/// `Lyric.Stdlib.<X>.dll`, then copy the produced native binary to
/// `targetBinPath`.  Returns 0 on success.
///
/// AOT trims aggressively, so we set `IlcInvariantGlobalization` and
/// `JsonSerializerIsReflectionEnabledByDefault=true` to keep the
/// `System.Text.Json` paths Lyric's `Std.Json` uses operational.  If
/// a user program uses paths that the trimmer rejects, the publish
/// will surface warnings — for now we accept those as-is rather than
/// scaffolding a full descriptor file.
let private publishAot
        (lyricDll: string)
        (targetBinPath: string)
        (rid: string) : int =
    let lyricDir =
        safeStr (Path.GetDirectoryName(Path.GetFullPath lyricDll)) "."
    let lyricName =
        safeStr (Path.GetFileNameWithoutExtension lyricDll) "out"
    // Scratch directory for the generated csproj + Program.cs + the
    // copied DLLs.  Per-invocation; `dotnet publish` writes the
    // native binary into `<scratch>/bin/Release/<tfm>/<RID>/native/`.
    let scratch =
        Path.Combine(Path.GetTempPath(),
                     "lyric-aot-" + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory scratch |> ignore
    let aotName = "lyric_aot_wrapper"

    // Find FSharp.Core next to the CLI binary; required by Lyric.Stdlib.
    let cliDir = AppContext.BaseDirectory
    let copyIfExists (src: string) =
        if File.Exists src then
            let fname =
                safeStr (Path.GetFileName src) ""
            if fname <> "" then
                File.Copy(src, Path.Combine(scratch, fname), overwrite = true)

    /// Make the emitted Lyric PE consumable by .NET ref packs.  Two
    /// rewrites happen on the metadata in-place (preserving the
    /// file size + all offsets):
    ///
    /// 1. **AssemblyRef name**: `System.Private.CoreLib` →
    ///    `System.Runtime` (zero-padded to the same length so the
    ///    string-heap offsets following it stay valid).  The .NET
    ///    targeting pack ships `System.Runtime.dll` as a contract
    ///    facade; `System.Private.CoreLib` is the implementation
    ///    name and isn't shipped as a reference assembly.
    ///
    /// 2. **AssemblyRef version**: 9.0.0.0 → ref-pack version
    ///    (typically 10.0.0.0 in current SDKs).  Bumps the version
    ///    so the C# compiler doesn't trip `CS0012` on a missing
    ///    `System.Runtime, Version=9.0.0.0` reference.  Forward-
    ///    compatible since runtime types are unchanged.
    ///
    /// Both rewrites are idempotent: running the patcher on an
    /// already-patched file is a no-op.
    let rewriteCoreLibRefs (path: string) : unit =
        if not (File.Exists path) then () else
        let oldName = "System.Private.CoreLib"
        let newName = "System.Runtime"
        let oldBytes = System.Text.Encoding.UTF8.GetBytes oldName
        let newBytes = System.Text.Encoding.UTF8.GetBytes newName
        let bytes = File.ReadAllBytes path
        let mutable i = 0
        let mutable patchedName = false
        while i <= bytes.Length - oldBytes.Length do
            let mutable matches = true
            let mutable k = 0
            while matches && k < oldBytes.Length do
                if bytes.[i + k] <> oldBytes.[k] then matches <- false
                k <- k + 1
            if matches then
                for j in 0 .. newBytes.Length - 1 do
                    bytes.[i + j] <- newBytes.[j]
                for j in newBytes.Length .. oldBytes.Length - 1 do
                    bytes.[i + j] <- 0uy
                patchedName <- true
                i <- i + oldBytes.Length
            else
                i <- i + 1
        // Use System.Reflection.Metadata to walk the AssemblyRef
        // table and patch each row's `MajorVersion` field in place.
        // The PEReader closes its underlying stream when disposed; we
        // run this AFTER the name-rewrite so both edits are flushed
        // together at the end.
        let mutable patchedVersion = false
        try
            use ms = new System.IO.MemoryStream(bytes)
            use peReader =
                new System.Reflection.PortableExecutable.PEReader(ms)
            let mdStart = peReader.PEHeaders.MetadataStartOffset
            let mdSize  = peReader.PEHeaders.MetadataSize
            // Conservative byte-pattern scan limited to the metadata
            // block: replace `09 00 00 00 00 00 00 00` (version
            // 9.0.0.0 little-endian) with `0A 00 00 00 00 00 00 00`
            // (10.0.0.0).  Only the AssemblyRef table laid 4-USHORT
            // versions adjacent like this, so a stray match in some
            // other table row is extremely unlikely.
            let v9 = [| 9uy; 0uy; 0uy; 0uy; 0uy; 0uy; 0uy; 0uy |]
            let mutable j = mdStart
            let mdEnd = mdStart + mdSize - v9.Length
            while j <= mdEnd do
                let mutable matches = true
                let mutable k = 0
                while matches && k < v9.Length do
                    if bytes.[j + k] <> v9.[k] then matches <- false
                    k <- k + 1
                if matches then
                    bytes.[j] <- 10uy
                    patchedVersion <- true
                    j <- j + v9.Length
                else
                    j <- j + 1
        with _ -> ()
        if patchedName || patchedVersion then
            File.WriteAllBytes(path, bytes)

    copyIfExists lyricDll
    copyIfExists (Path.Combine(cliDir, "Lyric.Stdlib.dll"))
    copyIfExists (Path.Combine(cliDir, "FSharp.Core.dll"))
    for p in Lyric.Emitter.Emitter.stdlibAssemblyPaths () do
        copyIfExists p

    // Rewrite the `System.Private.CoreLib` reference name in every
    // Lyric-emitted DLL we copied — the user's main PE plus each
    // `Lyric.Stdlib.<X>.dll` from the stdlib precompile cache.
    // `Lyric.Stdlib.dll` (built by F#) and `FSharp.Core.dll` already
    // reference `System.Runtime`, so the no-match path is a fast
    // scan; the patcher is idempotent.
    for f in Directory.GetFiles(scratch, "*.dll") do
        rewriteCoreLibRefs f

    // Generate a tiny Program.cs that calls the user program's static
    // `Main(string[])` entrypoint via reflection.  Direct C# binding
    // (e.g. `Aot1.Program.Main(args)`) trips `CS0012` because the
    // user's Lyric-emitted PE references `System.Private.CoreLib`
    // directly while the C# compiler's targeting pack references
    // `System.Runtime`.  Reflection sidesteps the static-type
    // dependency entirely; AOT's trimmer keeps the type root via
    // `DynamicDependency`.
    //
    // We sniff the entry type from the Lyric DLL's metadata so the
    // wrapper can hard-code the type name into the `DynamicDependency`
    // attribute (saving the trimmer from rooting an arbitrary type).
    let asm = System.Reflection.Assembly.LoadFrom lyricDll
    let mainCandidate =
        asm.GetTypes()
        |> Array.tryPick (fun t ->
            if not (t.Name = "Program") then None
            else
                let m = t.GetMethod("Main", [| typeof<string[]> |])
                match Option.ofObj m with
                | Some _ -> Some t.FullName
                | None   -> None)
    let mainTypeFullName : string =
        match mainCandidate with
        | Some n ->
            match Option.ofObj n with
            | Some s -> s
            | None   -> failwithf "AOT: anonymous Program type in %s" lyricDll
        | None ->
            failwithf "AOT: no `Program.Main(string[])` found in %s" lyricDll
    let lyricAssemblyName =
        match Option.ofObj (asm.GetName().Name) with
        | Some s -> s
        | None   -> lyricName
    // Generate a Program.cs that statically calls into the Lyric
    // entrypoint.  We need a static reference so AOT can root the
    // method (Assembly.LoadFrom is unsupported under PublishAot).
    // The C# compiler's CS0012 on `System.Private.CoreLib` is
    // suppressed via `<NoWarn>` plus `<ResolveAssemblyReferenceUseUnresolvedAssemblies>`
    // — see the csproj.
    let programCsPath = Path.Combine(scratch, "Program.cs")
    let programCs =
        "// Generated AOT wrapper — calls into the Lyric-emitted entrypoint.\n"
        + "internal static class Program {\n"
        + "    public static int Main(string[] args) {\n"
        + "        " + mainTypeFullName + ".Main(args);\n"
        + "        return 0;\n"
        + "    }\n"
        + "}\n"
    File.WriteAllText(programCsPath, programCs)
    let _ = lyricAssemblyName  // currently unused; AOT static path

    // Generate the csproj.  References every DLL in the scratch dir.
    let dlls =
        Directory.GetFiles(scratch, "*.dll")
        |> Array.map Path.GetFileName
        |> Array.choose Option.ofObj
    // Reference each Lyric DLL statically so the C# compiler binds
    // against them and AOT can trace + root the entrypoint.  Direct
    // references trip `CS0012` because the Lyric-emitted PE references
    // `System.Private.CoreLib` directly while the C# compiler's
    // targeting pack exposes the BCL via `System.Runtime`.  Suppress
    // the warning + force unresolved-assembly tolerance.
    let refLine (f: string) : string =
        let stem =
            match Option.ofObj (Path.GetFileNameWithoutExtension f) with
            | Some s -> s
            | None   -> ""
        "    <Reference Include=\"" + stem + "\"><HintPath>" + f + "</HintPath></Reference>"
    let referenceLines =
        dlls
        |> Array.map refLine
        |> String.concat "\n"
    // The byte-rewriter above bumps every AssemblyRef version
    // pattern from `9.0.0.0` to `10.0.0.0` to match what the .NET 10
    // ref pack ships.  Target net10.0 here so the C# compiler binds
    // against the same version.
    let tfm = "net10.0"
    let csproj =
        "<Project Sdk=\"Microsoft.NET.Sdk\">\n"
        + "  <PropertyGroup>\n"
        + "    <OutputType>Exe</OutputType>\n"
        + "    <TargetFramework>" + tfm + "</TargetFramework>\n"
        + "    <PublishAot>true</PublishAot>\n"
        + "    <InvariantGlobalization>true</InvariantGlobalization>\n"
        + "    <RootNamespace>LyricAot</RootNamespace>\n"
        + "    <AssemblyName>" + aotName + "</AssemblyName>\n"
        + "    <RuntimeIdentifier>" + rid + "</RuntimeIdentifier>\n"
        + "    <SelfContained>true</SelfContained>\n"
        + "    <!-- The Lyric-emitted PE references `System.Private.CoreLib`\n"
        + "         directly; the C# compiler's targeting pack exposes the\n"
        + "         BCL via `System.Runtime`.  Suppress the resulting\n"
        + "         CS0012 + IL warnings; the runtime types resolve fine. -->\n"
        + "    <SuppressTrimAnalysisWarnings>true</SuppressTrimAnalysisWarnings>\n"
        + "    <NoWarn>$(NoWarn);CS0012;CS1701;CS1702;IL2026;IL3050;IL3000;IL2104</NoWarn>\n"
        + "    <ResolveAssemblyReferenceIgnoreOverrideWarning>true</ResolveAssemblyReferenceIgnoreOverrideWarning>\n"
        + "  </PropertyGroup>\n"
        + "  <PropertyGroup>\n"
        + "    <!-- Std.Json uses System.Text.Json reflection paths; keep them. -->\n"
        + "    <JsonSerializerIsReflectionEnabledByDefault>true</JsonSerializerIsReflectionEnabledByDefault>\n"
        + "  </PropertyGroup>\n"
        + "  <ItemGroup>\n"
        + referenceLines + "\n"
        + "  </ItemGroup>\n"
        + "</Project>\n"
    let csprojPath = Path.Combine(scratch, aotName + ".csproj")
    File.WriteAllText(csprojPath, csproj)

    // Run `dotnet publish`.  Stream stdout / stderr through so the
    // user sees AOT warnings live.
    printfn "AOT: publishing for %s ..." rid
    let psi = Diagnostics.ProcessStartInfo()
    psi.FileName <- "dotnet"
    psi.ArgumentList.Add "publish"
    psi.ArgumentList.Add csprojPath
    psi.ArgumentList.Add "-c"
    psi.ArgumentList.Add "Release"
    psi.ArgumentList.Add "-r"
    psi.ArgumentList.Add rid
    psi.ArgumentList.Add "--nologo"
    psi.UseShellExecute <- false
    let proc =
        match Option.ofObj (Diagnostics.Process.Start psi) with
        | Some p -> p
        | None   ->
            printErr "AOT: failed to start dotnet publish"
            exit 1
    use _ = proc
    proc.WaitForExit()
    if proc.ExitCode <> 0 then
        printErr (sprintf "AOT: dotnet publish exited %d" proc.ExitCode)
        printErr "AOT: bootstrap-grade — known to fail when the Lyric-emitted PE's"
        printErr "AOT: CoreLib reference doesn't survive the .NET ref-pack version bump."
        printErr "AOT: tracked as a follow-up; non-AOT builds continue to work."
        proc.ExitCode
    else
        // Find the produced native binary.  AOT puts it at
        // `<scratch>/bin/Release/<tfm>/<rid>/publish/<aotName>[.exe]`.
        let publishDir =
            Path.Combine(scratch, "bin", "Release", tfm, rid, "publish")
        let exeSuffix =
            if rid.StartsWith "win" then ".exe" else ""
        let producedBin =
            Path.Combine(publishDir, aotName + exeSuffix)
        if not (File.Exists producedBin) then
            printErr (sprintf "AOT: expected native binary not found at %s" producedBin)
            1
        else
            // Copy the binary to the user's requested output path.
            let finalDir =
                safeStr (Path.GetDirectoryName(Path.GetFullPath targetBinPath)) "."
            Directory.CreateDirectory finalDir |> ignore
            File.Copy(producedBin, targetBinPath, overwrite = true)
            // Make the binary executable on POSIX.
            if not (rid.StartsWith "win") then
                try
                    let psi = Diagnostics.ProcessStartInfo()
                    psi.FileName <- "chmod"
                    psi.ArgumentList.Add "+x"
                    psi.ArgumentList.Add targetBinPath
                    psi.UseShellExecute <- false
                    psi.RedirectStandardOutput <- true
                    psi.RedirectStandardError <- true
                    match Option.ofObj (Diagnostics.Process.Start psi) with
                    | Some p -> p.WaitForExit()
                    | None   -> ()
                with _ -> ()
            printfn "AOT: produced %s" targetBinPath
            0

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
    printErr "  lyric build <source.l> [-o <output>] [--force] [--aot] [--rid <RID>]"
    printErr "  lyric run   <source.l> [-- <args>...]"
    printErr "  lyric --version"
    printErr ""
    printErr "  build is incremental — re-running with the same source +"
    printErr "  stdlib closure skips the emit; pass --force to rebuild."
    printErr ""
    printErr "  --aot               compile to a native, self-contained binary"
    printErr "                      (passes through dotnet publish)."
    printErr "  --rid <RID>         target RID for AOT (default: host RID)."

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
        let mutable aot = false
        let mutable rid : string option = None
        let mutable positional : string list = []
        let mutable cursor = rest
        while not (List.isEmpty cursor) do
            match cursor with
            | "--force" :: tail ->
                force <- true
                cursor <- tail
            | "--aot" :: tail ->
                aot <- true
                cursor <- tail
            | "--rid" :: r :: tail ->
                rid <- Some r
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
            let dllOutPath =
                match explicitOut, aot with
                | Some o, false -> o
                | Some o, true ->
                    // For AOT, treat the explicit output as the
                    // *native binary*; the intermediate DLL goes to a
                    // sibling .dll.
                    let dir =
                        safeStr (Path.GetDirectoryName(Path.GetFullPath o)) "."
                    let stem =
                        safeStr (Path.GetFileNameWithoutExtension o) "out"
                    Path.Combine(dir, stem + ".dll")
                | None, _ ->
                    let dir =
                        safeStr (Path.GetDirectoryName(Path.GetFullPath sourcePath)) "."
                    let name =
                        safeStr (Path.GetFileNameWithoutExtension sourcePath) "out"
                    Path.Combine(dir, name + ".dll")
            let buildExit = build sourcePath dllOutPath force
            if buildExit <> 0 then buildExit
            elif not aot then 0
            else
                let nativePath =
                    match explicitOut with
                    | Some o -> o
                    | None ->
                        let dir =
                            safeStr (Path.GetDirectoryName(Path.GetFullPath sourcePath)) "."
                        let name =
                            safeStr (Path.GetFileNameWithoutExtension sourcePath) "out"
                        Path.Combine(dir, name)
                let chosenRid =
                    match rid with
                    | Some r -> r
                    | None   -> hostRid ()
                publishAot dllOutPath nativePath chosenRid
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
