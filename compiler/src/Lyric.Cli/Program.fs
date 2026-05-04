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
            // Recursive: kernel-boundary files live under `_kernel/`
            // (see `docs/14-native-stdlib-plan.md` §6 P0/4).
            Directory.GetFiles(stdDir, "*.l", SearchOption.AllDirectories)
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
///
/// `restoredPackageRefs` lists the restored Lyric packages this
/// build can resolve non-`Std.*` imports against
/// (D-progress-077 follow-up).  The CLI fills it from
/// `lyric.toml`'s `[dependencies]` when `--manifest` is supplied
/// (or `lyric.toml` is auto-discovered next to the source); empty
/// list otherwise.
let private build
        (sourcePath: string)
        (outPath: string)
        (force: bool)
        (restoredPackageRefs: Lyric.Emitter.RestoredPackages.RestoredPackageRef list) : int =
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
        { Source           = source
          AssemblyName     = assemblyName
          OutputPath       = outPath
          RestoredPackages = restoredPackageRefs }
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
            // Stack trace surfaced when LYRIC_DEBUG is set — useful
            // when the bare message ("Specified method is not
            // supported") doesn't pinpoint the failing reflection
            // call.
            match Option.ofObj (System.Environment.GetEnvironmentVariable "LYRIC_DEBUG") with
            | None -> ()
            | Some _ ->
                match Option.ofObj e.StackTrace with
                | Some st -> printErr st
                | None    -> ()
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

    /// Use Mono.Cecil to rewrite the AssemblyRef table on a Lyric-
    /// emitted PE so it's consumable by `dotnet publish` /
    /// native-AOT.  Two changes per CoreLib reference:
    ///
    ///   * `System.Private.CoreLib` → `System.Runtime` (the
    ///     publishable contract assembly).
    ///   * version + PublicKeyToken set to the contract identity
    ///     `Version=10.0.0.0, PKT=b03f5f7f11d50a3a` (matches the
    ///     SDK 10 ref pack's `System.Runtime.dll`).
    ///
    /// Skipping `System.Private.CoreLib` rows or programs without
    /// CoreLib refs is a no-op.  Cecil rewrites blob heap entries
    /// (PKT) cleanly; the byte-rewriter we used to ship couldn't.
    /// Rewrite per-`TypeRef` AssemblyRef pointers in the user PE so
    /// each runtime type lands on its correct contract assembly:
    ///
    ///   * `System.Object`, `System.String`, primitives →
    ///     `System.Runtime`.
    ///   * `System.Collections.Generic.Dictionary<,>`,
    ///     `System.Collections.Generic.List<>` etc. →
    ///     `System.Collections`.
    ///   * `System.Net.HttpListener` → `System.Net.HttpListener`.
    ///   * `System.Text.Json.JsonDocument` → `System.Text.Json`.
    ///   * etc.
    ///
    /// The `typeContract` map is the source of truth.  Lyric's
    /// emitter writes every reference as `System.Private.CoreLib` (the
    /// runtime implementation assembly) because that's what
    /// `typeof<>` resolves to; AOT needs the contract identity each
    /// type was originally declared in.  We probe the .NET ref pack
    /// for each contract assembly's name+version+PKT.
    let rewriteCoreLibRefs (path: string) : unit =
        if not (File.Exists path) then () else
        try
            let dotnetRoot =
                let env = Environment.GetEnvironmentVariable "DOTNET_ROOT"
                match Option.ofObj env with
                | Some s -> s
                | None   -> "/root/.dotnet"
            let refPackBase =
                Path.Combine(dotnetRoot, "packs", "Microsoft.NETCore.App.Ref")
            let refPackDir : string option =
                if not (Directory.Exists refPackBase) then None
                else
                    let packVer = sprintf "%d.0" Environment.Version.Major
                    Directory.GetDirectories refPackBase
                    |> Array.tryPick (fun d ->
                        let folder = Path.GetFileName d
                        match Option.ofObj folder with
                        | Some f when f.StartsWith packVer ->
                            let tfm =
                                Path.Combine(d, "ref",
                                    sprintf "net%d.0" Environment.Version.Major)
                            if Directory.Exists tfm then Some tfm else None
                        | _ -> None)
            // Build a "type FullName → contract assembly identity" map
            // by indexing every public type in every ref-pack DLL
            // (excluding aliases / forwarders so we get the contract
            // that actually declares each type).
            let typeContract = System.Collections.Generic.Dictionary<string, Mono.Cecil.AssemblyNameReference>()
            match refPackDir with
            | None -> ()
            | Some dir ->
                let mlcResolver =
                    System.Reflection.PathAssemblyResolver(
                        Directory.GetFiles(dir, "*.dll"))
                use mlc =
                    new System.Reflection.MetadataLoadContext(mlcResolver)
                for dll in Directory.GetFiles(dir, "*.dll") do
                    try
                        let asm = mlc.LoadFromAssemblyPath dll
                        let asmName = asm.GetName()
                        let nameRef =
                            Mono.Cecil.AssemblyNameReference(
                                asmName.Name,
                                asmName.Version)
                        let pkt =
                            match Option.ofObj (asmName.GetPublicKeyToken()) with
                            | Some bs -> bs
                            | None    -> [||]
                        if pkt.Length > 0 then
                            nameRef.PublicKeyToken <- pkt
                        for t in asm.GetExportedTypes() do
                            // Record only the contract that DECLARES
                            // the type (not the type-forwarders that
                            // also surface in System.Runtime's
                            // exported types).
                            try
                                let typeAsmName =
                                    safeStr (t.Assembly.GetName().Name) ""
                                let typeName = safeStr t.FullName ""
                                let asmRefName = safeStr asmName.Name ""
                                if typeAsmName = asmRefName
                                   && typeName <> ""
                                   && not (typeContract.ContainsKey typeName)
                                then
                                    typeContract.[typeName] <- nameRef
                            with _ -> ()
                    with _ -> ()
            // Open the user PE with Cecil and rewrite each TypeRef's
            // Scope to point at the matching contract assembly.
            let parameters = Mono.Cecil.ReaderParameters()
            parameters.InMemory <- true
            (use modu =
                Mono.Cecil.ModuleDefinition.ReadModule(path, parameters)
             let assemblyByName =
                System.Collections.Generic.Dictionary<string, Mono.Cecil.AssemblyNameReference>()
             let getOrAddAssemblyRef (target: Mono.Cecil.AssemblyNameReference) =
                match assemblyByName.TryGetValue target.Name with
                | true, existing -> existing
                | _ ->
                    let r =
                        Mono.Cecil.AssemblyNameReference(
                            target.Name, target.Version)
                    if not (isNull target.PublicKeyToken) then
                        r.PublicKeyToken <- target.PublicKeyToken
                    modu.AssemblyReferences.Add r
                    assemblyByName.[target.Name] <- r
                    r
             // Pre-populate the dictionary with whatever's already
             // referenced so we don't add duplicates.
             for r in modu.AssemblyReferences do
                if not (assemblyByName.ContainsKey r.Name) then
                    assemblyByName.[r.Name] <- r
             let mutable patched = false
             // Walk all TypeRefs.  Cecil exposes them indirectly via
             // module.GetTypeReferences().
             for tref in modu.GetTypeReferences() do
                let scopeName =
                    match Option.ofObj tref.Scope with
                    | Some s -> s.Name
                    | None   -> ""
                if scopeName = "System.Private.CoreLib"
                   || scopeName = "System.Runtime" then
                    match typeContract.TryGetValue tref.FullName with
                    | true, contract ->
                        let asmRef = getOrAddAssemblyRef contract
                        tref.Scope <- asmRef
                        patched <- true
                    | _ ->
                        // Fall back to System.Runtime when we don't
                        // know the proper contract — better than
                        // leaving CoreLib in place.
                        match typeContract.TryGetValue "System.Object" with
                        | true, contract ->
                            let asmRef = getOrAddAssemblyRef contract
                            tref.Scope <- asmRef
                            patched <- true
                        | _ -> ()
             if patched then
                let tmp = path + ".aot-rewrite.tmp"
                modu.Write tmp
                File.Move(tmp, path, overwrite = true))
        with e ->
            eprintfn "AOT rewrite: %s on %s" e.Message path

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
    let buildExit = build sourcePath outPath true []
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
    printErr "  lyric build <source.l> [-o <output>] [--force] [--aot] [--rid <RID>] [--manifest <lyric.toml>]"
    printErr "  lyric run   <source.l> [-- <args>...]"
    printErr "  lyric prove <source.l> [--proof-dir <dir>] [--verbose] [--allow-unverified] [--json] [--explain --goal <n>]"
    printErr "  lyric doc   <source.l> [-o out.md]"
    printErr "  lyric public-api-diff <old.dll> <new.dll>"
    printErr "  lyric publish [--manifest <lyric.toml>] [--dll <path>] [-o <pkg-dir>]"
    printErr "  lyric restore [--manifest <lyric.toml>]"
    printErr "  lyric --version"
    printErr ""
    printErr "  build is incremental — re-running with the same source +"
    printErr "  stdlib closure skips the emit; pass --force to rebuild."
    printErr ""
    printErr "  --aot               compile to a native, self-contained binary"
    printErr "                      (passes through dotnet publish)."
    printErr "  --rid <RID>         target RID for AOT (default: host RID)."
    printErr ""
    printErr "  public-api-diff exits 0 (no changes), 0 (additive), or 2"
    printErr "                  (breaking — Removed/Changed); use 2 in CI to gate"
    printErr "                  major-version bumps."
    printErr ""
    printErr "  publish wraps `dotnet pack` against a generated .csproj that"
    printErr "          embeds your pre-built Lyric DLL into a .nupkg under"
    printErr "          lib/net10.0/.  Run `lyric build` first."
    printErr "  restore wraps `dotnet restore` over `[dependencies]` from"
    printErr "          lyric.toml so transitive .nupkg packages land in the"
    printErr "          NuGet cache."

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
        let mutable manifestArg : string option = None
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
            | "--manifest" :: m :: tail ->
                manifestArg <- Some m
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
            // Locate `lyric.toml`: explicit `--manifest` first; if
            // absent, look next to the source file.  When found,
            // resolve every `[dependencies]` entry to its restored
            // DLL via the standard NuGet cache convention so
            // `import <Pkg>` declarations resolve at build time
            // (D-progress-077 follow-up).
            let restoredPackageRefs =
                let manifestPath =
                    match manifestArg with
                    | Some m -> Some (Path.GetFullPath m)
                    | None ->
                        let dir =
                            safeStr
                                (Path.GetDirectoryName(Path.GetFullPath sourcePath))
                                "."
                        let candidate = Path.Combine(dir, "lyric.toml")
                        if File.Exists candidate then Some candidate else None
                match manifestPath with
                | None -> []
                | Some path ->
                    match Lyric.Cli.Manifest.parseFile path with
                    | Error e ->
                        printErr (Lyric.Cli.Manifest.renderError path e)
                        []
                    | Ok manifest ->
                        manifest.Dependencies
                        |> List.choose (fun dep ->
                            match Lyric.Emitter.RestoredPackages.tryLocateRestoredDll dep.Name dep.Version with
                            | Some dll ->
                                Some
                                    { Lyric.Emitter.RestoredPackages.RestoredPackageRef.Name    = dep.Name
                                      Lyric.Emitter.RestoredPackages.RestoredPackageRef.Version = dep.Version
                                      Lyric.Emitter.RestoredPackages.RestoredPackageRef.DllPath = dll }
                            | None ->
                                printErr (sprintf "build: '%s' %s not found in NuGet cache — run `lyric restore` first"
                                                  dep.Name dep.Version)
                                None)
            let buildExit = build sourcePath dllOutPath force restoredPackageRefs
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
    | "prove" :: rest ->
        // `lyric prove <source.l> [--proof-dir <dir>] [--verbose]
        //                         [--allow-unverified]
        //                         [--json]
        //                         [--explain --goal <n>]`
        // — Phase 4 verifier.  Runs the mode-dispatch check
        // (V0001/V0002/V0004), generates VCs for every proof-required
        // function, and discharges them via the trivial syntactic
        // checker or a `z3` binary on `$PATH`.  `--allow-unverified`
        // downgrades V0007 (`unknown`) from an error to a warning so
        // the command exits 0 — the user's escape hatch when the
        // solver budgets out (M4.2 close-out).  Counterexamples
        // (V0008) remain hard errors regardless.
        // `--json` emits a machine-readable JSON summary to stdout.
        // `--explain --goal <n>` prints the Lyric-VC IR for goal n and exits.
        let mutable proofDir : string option = None
        let mutable verbose = false
        let mutable allowUnverified = false
        let mutable jsonOutput = false
        let mutable explain = false
        let mutable explainGoal : int option = None
        let mutable positional : string list = []
        let mutable cursor = rest
        while not (List.isEmpty cursor) do
            match cursor with
            | "--proof-dir" :: dir :: tail ->
                proofDir <- Some dir
                cursor <- tail
            | "--verbose" :: tail | "-v" :: tail ->
                verbose <- true
                cursor <- tail
            | "--allow-unverified" :: tail ->
                allowUnverified <- true
                cursor <- tail
            | "--json" :: tail ->
                jsonOutput <- true
                cursor <- tail
            | "--explain" :: tail ->
                explain <- true
                cursor <- tail
            | "--goal" :: n :: tail ->
                match System.Int32.TryParse n with
                | true, idx -> explainGoal <- Some idx
                | _ ->
                    printErr (sprintf "prove: --goal expects an integer, got '%s'" n)
                cursor <- tail
            | s :: tail ->
                positional <- positional @ [s]
                cursor <- tail
            | [] -> ()
        match positional with
        | [] ->
            printErr "prove: missing source file"
            1
        | sourcePath :: _ ->
            if not (File.Exists sourcePath) then
                printErr (sprintf "prove: source file not found: %s" sourcePath)
                1
            else
            let resolvedProofDir =
                match proofDir with
                | Some d -> Some d
                | None ->
                    let dir =
                        safeStr (Path.GetDirectoryName(Path.GetFullPath sourcePath)) "."
                    Some (Path.Combine(dir, "target", "proofs"))
            let opts =
                { Lyric.Verifier.Driver.ProveOptions.AllowUnverified =
                    allowUnverified }
            let summary =
                Lyric.Verifier.Driver.proveFileWithOptions
                    sourcePath resolvedProofDir [] opts

            // --explain --goal <n>: print the Lyric-VC IR for that goal and exit.
            if explain then
                match explainGoal with
                | None ->
                    printErr "prove --explain: specify a goal index with --goal <n>"
                    printErr (sprintf "  (this file has %d goal(s))" (List.length summary.Results))
                    for i, r in summary.Results |> List.mapi (fun i r -> i, r) do
                        printfn "  %d: %s  [%s]" i r.Goal.Label
                            (Lyric.Verifier.Vcir.GoalKind.display r.Goal.Kind)
                    1
                | Some idx ->
                    if idx < 0 || idx >= List.length summary.Results then
                        printErr (sprintf "prove --explain: goal %d out of range (0..%d)"
                                    idx (List.length summary.Results - 1))
                        1
                    else
                        let r = List.item idx summary.Results
                        printf "%s" (Lyric.Verifier.Vcir.PrettyPrint.goal idx r.Goal)
                        0
            elif jsonOutput then
                // --json: emit machine-readable summary to stdout.
                let escape (s: string) =
                    let sb = System.Text.StringBuilder()
                    for c in s do
                        match c with
                        | '"'  -> sb.Append "\\\"" |> ignore
                        | '\\' -> sb.Append "\\\\" |> ignore
                        | '\n' -> sb.Append "\\n"  |> ignore
                        | '\r' -> sb.Append "\\r"  |> ignore
                        | '\t' -> sb.Append "\\t"  |> ignore
                        | c when int c < 0x20 ->
                            sb.Append(sprintf "\\u%04x" (int c)) |> ignore
                        | c -> sb.Append c |> ignore
                    sb.ToString()
                let jStr (s: string) = sprintf "\"%s\"" (escape s)
                let jOpt (s: string option) =
                    match s with Some v -> jStr v | None -> "null"
                let sb = System.Text.StringBuilder()
                sb.Append "{\n" |> ignore
                sb.Append (sprintf "  \"file\": %s,\n" (jStr sourcePath)) |> ignore
                sb.Append (sprintf "  \"level\": %s,\n"
                    (jStr (Lyric.Verifier.Mode.VerificationLevel.display summary.Level)))
                    |> ignore
                sb.Append "  \"goals\": [\n" |> ignore
                let results = summary.Results
                for i, r in results |> List.mapi (fun i r -> i, r) do
                    let outcomeStr, modelStr =
                        match r.Outcome with
                        | Lyric.Verifier.Solver.Discharged ->
                            "discharged", "null"
                        | Lyric.Verifier.Solver.Counterexample m ->
                            "counterexample", jStr m
                        | Lyric.Verifier.Solver.Unknown reason ->
                            "unknown", jStr reason
                    let comma = if i + 1 < List.length results then "," else ""
                    sb.Append "    {\n" |> ignore
                    sb.Append (sprintf "      \"index\": %d,\n" i) |> ignore
                    sb.Append (sprintf "      \"label\": %s,\n" (jStr r.Goal.Label)) |> ignore
                    sb.Append (sprintf "      \"kind\": %s,\n"
                        (jStr (Lyric.Verifier.Vcir.GoalKind.display r.Goal.Kind)))
                        |> ignore
                    sb.Append (sprintf "      \"line\": %d,\n" r.Goal.Origin.Start.Line) |> ignore
                    sb.Append (sprintf "      \"col\": %d,\n" r.Goal.Origin.Start.Column) |> ignore
                    sb.Append (sprintf "      \"outcome\": %s,\n" (jStr outcomeStr)) |> ignore
                    sb.Append (sprintf "      \"model\": %s,\n" modelStr) |> ignore
                    sb.Append (sprintf "      \"smtPath\": %s\n" (jOpt r.SmtPath)) |> ignore
                    sb.Append (sprintf "    }%s\n" comma) |> ignore
                sb.Append "  ],\n" |> ignore
                let total = List.length summary.Results
                let discharged = Lyric.Verifier.Driver.ProofSummary.dischargedCount summary
                let unknowns   = Lyric.Verifier.Driver.ProofSummary.unknownCount summary
                let cexs       = Lyric.Verifier.Driver.ProofSummary.counterexampleCount summary
                sb.Append "  \"diagnostics\": [\n" |> ignore
                for i, d in summary.Diagnostics |> List.mapi (fun i d -> i, d) do
                    let sevStr =
                        match d.Severity with DiagError -> "error" | DiagWarning -> "warning"
                    let comma = if i + 1 < List.length summary.Diagnostics then "," else ""
                    sb.Append (sprintf "    {\"code\":%s,\"severity\":%s,\"message\":%s,\"line\":%d,\"col\":%d}%s\n"
                        (jStr d.Code) (jStr sevStr) (jStr d.Message)
                        d.Span.Start.Line d.Span.Start.Column comma) |> ignore
                sb.Append "  ],\n" |> ignore
                sb.Append "  \"summary\": {\n" |> ignore
                sb.Append (sprintf "    \"total\": %d,\n" total) |> ignore
                sb.Append (sprintf "    \"discharged\": %d,\n" discharged) |> ignore
                sb.Append (sprintf "    \"unknown\": %d,\n" unknowns) |> ignore
                sb.Append (sprintf "    \"counterexamples\": %d\n" cexs) |> ignore
                sb.Append "  }\n" |> ignore
                sb.Append "}\n" |> ignore
                printf "%s" (sb.ToString())
                if Lyric.Verifier.Driver.ProofSummary.hasErrorDiag summary then 1
                elif Lyric.Verifier.Driver.ProofSummary.hasCounterexample summary then 1
                else 0
            else

            for d in summary.Diagnostics do
                printDiag d
            let total = Lyric.Verifier.Driver.ProofSummary.totalCount summary
            let discharged =
                Lyric.Verifier.Driver.ProofSummary.dischargedCount summary
            let unknowns =
                Lyric.Verifier.Driver.ProofSummary.unknownCount summary
            if Lyric.Verifier.Mode.VerificationLevel.isProofRequired summary.Level then
                let suffix =
                    if allowUnverified && unknowns > 0 then
                        sprintf " [%d unverified, allowed]" unknowns
                    else ""
                printfn "%d/%d obligations discharged (%s)%s"
                    discharged total
                    (Lyric.Verifier.Mode.VerificationLevel.display summary.Level)
                    suffix
            else
                printfn "no proof obligations: package is %s"
                    (Lyric.Verifier.Mode.VerificationLevel.display summary.Level)
            if verbose then
                for r in summary.Results do
                    printfn "  [%s] %s -> %s"
                        r.Goal.Label
                        (Lyric.Verifier.Vcir.GoalKind.display r.Goal.Kind)
                        (Lyric.Verifier.Solver.displayOutcome r.Outcome)
                    match r.SmtPath with
                    | Some p -> printfn "    smt: %s" p
                    | None -> ()
            // Exit code:
            //   - any error-severity diagnostic => 1 (parse / mode /
            //     V0008 counterexample, or V0007 when not allowed).
            //   - V0007 unknowns under --allow-unverified are warnings;
            //     they don't fail the run on their own.
            if Lyric.Verifier.Driver.ProofSummary.hasErrorDiag summary then 1
            elif Lyric.Verifier.Driver.ProofSummary.hasCounterexample summary then 1
            else 0
    | "doc" :: rest ->
        // `lyric doc <source.l> [-o out.md]` — emit Markdown describing
        // the file's `pub` surface.  See Doc.fs for the bootstrap-grade
        // scope; in particular we don't yet roll up across files.
        let mutable explicitOut : string option = None
        let mutable positional : string list = []
        let mutable cursor = rest
        while not (List.isEmpty cursor) do
            match cursor with
            | "-o" :: out :: tail ->
                explicitOut <- Some out
                cursor <- tail
            | s :: tail ->
                positional <- positional @ [s]
                cursor <- tail
            | [] -> ()
        match positional with
        | [] ->
            printErr "doc: missing source file"
            1
        | sourcePath :: _ ->
            let source = File.ReadAllText sourcePath
            let parsed = Lyric.Parser.Parser.parse source
            // Surface parse errors but keep going — the doc generator
            // only inspects the AST shape, which the parser produces
            // even on partial recovery.
            for d in parsed.Diagnostics do
                if d.Severity = DiagError then printDiag d
            let md = Lyric.Cli.Doc.generate parsed.File
            match explicitOut with
            | Some path ->
                let dir = safeStr (Path.GetDirectoryName(Path.GetFullPath path)) "."
                Directory.CreateDirectory dir |> ignore
                File.WriteAllText(path, md)
                printfn "wrote %s" path
            | None ->
                Console.Out.Write(md)
            0
    | "public-api-diff" :: rest ->
        // `lyric public-api-diff <old.dll> <new.dll>` — read the
        // embedded `Lyric.Contract` resource from each assembly,
        // diff the public surface, and report Added / Removed /
        // Changed declarations with SemVer hints.  Exits 0 on
        // backwards-compatible changes (Added-only) or 2 on
        // breaking changes (Removed / Changed).  Exit 1 reserved
        // for usage / IO errors.  D-progress-062.
        let mutable positional : string list = []
        let mutable cursor = rest
        while not (List.isEmpty cursor) do
            match cursor with
            | s :: tail ->
                positional <- positional @ [s]
                cursor <- tail
            | [] -> ()
        match positional with
        | [oldDll; newDll] ->
            if not (File.Exists oldDll) then
                printErr (sprintf "public-api-diff: '%s' not found" oldDll)
                1
            elif not (File.Exists newDll) then
                printErr (sprintf "public-api-diff: '%s' not found" newDll)
                1
            else
                let readContract (path: string) =
                    match Lyric.Emitter.ContractMeta.readFromAssembly path with
                    | None ->
                        printErr (sprintf "public-api-diff: '%s' has no Lyric.Contract resource" path)
                        None
                    | Some json ->
                        match Lyric.Emitter.ContractMeta.parseFromJson json with
                        | Some c -> Some c
                        | None ->
                            printErr (sprintf "public-api-diff: '%s' has malformed contract metadata" path)
                            None
                match readContract oldDll, readContract newDll with
                | Some oldC, Some newC ->
                    let entries =
                        Lyric.Emitter.ContractMeta.diffContracts oldC newC
                    if List.isEmpty entries then
                        printfn "No public-API changes between %s and %s"
                            oldC.Version newC.Version
                        0
                    else
                        printfn "Public-API diff: %s %s -> %s %s"
                            oldC.PackageName oldC.Version
                            newC.PackageName newC.Version
                        for entry in entries do
                            printfn "%s"
                                (Lyric.Emitter.ContractMeta.renderDiffEntry entry)
                        if Lyric.Emitter.ContractMeta.hasBreakingChanges entries then
                            printfn ""
                            printfn "SemVer: BREAKING — bump the major version."
                            2
                        else
                            printfn ""
                            printfn "SemVer: backwards-compatible — bump the minor version."
                            0
                | _ -> 1
        | _ ->
            printErr "public-api-diff: expected `lyric public-api-diff <old.dll> <new.dll>`"
            1
    | "publish" :: rest ->
        // `lyric publish [--manifest <lyric.toml>] [--dll <path>] [-o <out>]`
        // — wrap `dotnet pack` over a generated `.csproj` that
        // embeds the pre-built Lyric DLL into a .nupkg under
        // lib/net10.0/.  D-progress-077.
        let mutable manifestPath : string option = None
        let mutable dllOverride : string option = None
        let mutable outputDir : string option = None
        let mutable cursor = rest
        while not (List.isEmpty cursor) do
            match cursor with
            | "--manifest" :: m :: tail -> manifestPath <- Some m; cursor <- tail
            | "--dll" :: d :: tail -> dllOverride <- Some d; cursor <- tail
            | "-o" :: o :: tail -> outputDir <- Some o; cursor <- tail
            | unknown :: tail ->
                printErr (sprintf "publish: unrecognised flag '%s'" unknown)
                cursor <- tail
            | [] -> ()
        let mfPath = Option.defaultValue "lyric.toml" manifestPath
        let mfFull = Path.GetFullPath mfPath
        match Lyric.Cli.Manifest.parseFile mfFull with
        | Error e ->
            printErr (Lyric.Cli.Manifest.renderError mfPath e)
            1
        | Ok manifest ->
            let manifestDir = safeStr (Path.GetDirectoryName mfFull) "."
            let dllPath =
                match dllOverride with
                | Some d -> Path.GetFullPath d
                | None   -> Lyric.Cli.Pack.defaultDllPath manifest manifestDir
            let outDir =
                match outputDir with
                | Some o -> Path.GetFullPath o
                | None   -> Lyric.Cli.Pack.defaultPackOutputDir manifest manifestDir
            match Lyric.Cli.Pack.runPack manifest manifestDir dllPath outDir false with
            | Ok nupkg ->
                printfn "wrote %s" nupkg
                0
            | Error msg ->
                printErr msg
                1
    | "restore" :: rest ->
        // `lyric restore [--manifest <lyric.toml>]` — wrap `dotnet
        // restore` over a generated `.csproj` declaring the
        // `[dependencies]` from lyric.toml.  Transitive resolution
        // populates the NuGet cache; consumption from `lyric build`
        // is a separate follow-up.  D-progress-077.
        let mutable manifestPath : string option = None
        let mutable cursor = rest
        while not (List.isEmpty cursor) do
            match cursor with
            | "--manifest" :: m :: tail -> manifestPath <- Some m; cursor <- tail
            | unknown :: tail ->
                printErr (sprintf "restore: unrecognised flag '%s'" unknown)
                cursor <- tail
            | [] -> ()
        let mfPath = Option.defaultValue "lyric.toml" manifestPath
        let mfFull = Path.GetFullPath mfPath
        match Lyric.Cli.Manifest.parseFile mfFull with
        | Error e ->
            printErr (Lyric.Cli.Manifest.renderError mfPath e)
            1
        | Ok manifest ->
            let manifestDir = safeStr (Path.GetDirectoryName mfFull) "."
            match Lyric.Cli.Pack.runRestore manifest manifestDir false with
            | Ok () ->
                printfn "restore: %d packages declared in %s"
                    (List.length manifest.Dependencies) mfPath
                0
            | Error msg ->
                printErr msg
                1
    | unknown :: _ ->
        printErr (sprintf "unknown command: %s" unknown)
        printUsage ()
        1
