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
/// source if `-o` is omitted, copies the precompiled
/// `Lyric.Stdlib.<X>.dll` package DLLs into the output directory, and
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

/// CLI feature-flag selection per `docs/24-build-features.md` (D045).
type private FeatureSelection =
    { /// Names from `--features X,Y` (additive over manifest defaults).
      Cli:                string list
      /// `--no-default-features` flag — suppresses manifest's `default`.
      SuppressDefault:    bool
      /// `--all-features` flag — activates every declared feature.
      AllFeatures:        bool }

let private emptyFeatureSelection : FeatureSelection =
    { Cli = []; SuppressDefault = false; AllFeatures = false }

/// Compute the active feature set from CLI flags + manifest.  Errors
/// printed to stderr; returns `(active, declared, errorCount)` so the
/// caller can fail the build when a CLI-specified feature isn't
/// declared in the manifest.
let private resolveFeatures
        (sel: FeatureSelection)
        (manifest: Lyric.Cli.Manifest.Manifest option)
        : Set<string> * Set<string> * int =
    let declaredList, defaultList =
        match manifest |> Option.bind (fun m -> m.Features) with
        | Some f -> f.Declared, f.Default
        | None   -> [], []
    let declared = Set.ofList declaredList
    if sel.AllFeatures then
        declared, declared, 0
    else
        let cliSet = Set.ofList sel.Cli
        let mutable errors = 0
        // F0003: every CLI feature must be declared in the manifest
        // (only enforced when the manifest declares ANY features).
        if not (Set.isEmpty declared) then
            for f in cliSet do
                if not (Set.contains f declared) then
                    printErr
                        (sprintf
                            "F0003: feature '%s' is not declared in the manifest's [features] section"
                            f)
                    errors <- errors + 1
        let baseSet =
            if sel.SuppressDefault then Set.empty
            else Set.ofList defaultList
        let active = Set.union baseSet cliSet
        active, declared, errors

let private printDiag (d: Diagnostic) : unit =
    let sev =
        match d.Severity with
        | DiagError   -> "error"
        | DiagWarning -> "warning"
    let span = d.Span
    printErr (sprintf "%s %s [%d:%d]: %s"
                d.Code sev span.Start.Line span.Start.Column d.Message)

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

/// Copy the precompiled Lyric stdlib package DLLs (`Lyric.Stdlib.<X>.dll`)
/// into `outDir` so `dotnet exec` resolves cross-assembly references.
/// `Lyric.Jvm.Hosts.dll` ships alongside the stdlib (D-progress-107 /
/// Bucket D split): the JVM emitter's `_kernel/kernel.l`
/// `@externTarget`s `Lyric.Jvm.Hosts.JvmByteHost.…` etc., so any user
/// program emitting JVM bytecode resolves the host helpers at runtime.
/// The F# `Lyric.Stdlib.dll` shim retired in D-progress-137; we no
/// longer copy it because it doesn't exist.
let private copyStdlibArtifacts (outDir: string) : unit =
    let jvmHosts =
        Path.Combine(AppContext.BaseDirectory, "Lyric.Jvm.Hosts.dll")
    if File.Exists jvmHosts then
        File.Copy(jvmHosts, Path.Combine(outDir, "Lyric.Jvm.Hosts.dll"), overwrite = true)
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

/// Phase 5 §M5.1 stage 2d.v: copy each NuGet DLL the build referenced
/// into the output directory so `dotnet exec`'s default probing path
/// finds them at runtime.  Also copies every compiled `_extern/`
/// shim DLL out of the build cache so the user's main DLL can load
/// the shim package at runtime.  This is the simplest correct
/// shape; a generated `.deps.json` (cache-based resolution) is a
/// follow-up for `dotnet publish` / AOT flows that want lighter
/// deploys.
let private copyNugetArtifacts
        (outDir: string)
        (nugetPaths: string list)
        (externShimRoot: string option) : unit =
    let copyOne (p: string) =
        if File.Exists p then
            match Option.ofObj (Path.GetFileName p) with
            | Some fname ->
                let dest = Path.Combine(outDir, fname)
                try File.Copy(p, dest, overwrite = true)
                with ex ->
                    printErr
                        (sprintf "warning: failed to copy NuGet DLL '%s' -> '%s': %s"
                                  p dest ex.Message)
            | None -> ()
    for p in nugetPaths do copyOne p
    match externShimRoot with
    | None -> ()
    | Some root ->
        let parent =
            try Path.GetDirectoryName(Path.GetFullPath root)
            with _ -> null
        match Option.ofObj parent with
        | Some p ->
            let cache = Path.Combine(p, ".lyric", "extern-cache")
            if Directory.Exists cache then
                for dll in Directory.GetFiles(cache, "*.dll") do
                    copyOne dll
        | None -> ()

/// Build cache: when a `.lyric-cache` sidecar next to `outPath`
/// records the same SHA-256 fingerprint as the current source +
/// every stdlib `.l` file the resolver might pull in, and the
/// output PE itself still exists, the rebuild is skipped.
///
/// The fingerprint covers:
///   * the source bytes
///   * every file under `lyric-stdlib/std/*.l` reachable from the source's
///     directory (or any ancestor that contains a `lyric-stdlib/std/` dir)
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

    /// Locate the `lyric-stdlib/std/` directory for cache fingerprinting.
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
                        let candidate = Path.Combine(d.FullName, "lyric-stdlib", "std")
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
        (restoredPackageRefs: Lyric.Emitter.RestoredPackages.RestoredPackageRef list)
        (nugetAssemblyPaths: string list)
        (externShimRoot: string option)
        (target: Emitter.CompileTarget)
        (activeFeatures: Set<string>)
        (declaredFeatures: Set<string>) : int =
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
        { Source             = source
          AssemblyName       = assemblyName
          OutputPath         = outPath
          RestoredPackages   = restoredPackageRefs
          NugetAssemblyPaths = nugetAssemblyPaths
          ExternShimRoot     = externShimRoot
          Target             = target
          ActiveFeatures     = activeFeatures
          DeclaredFeatures   = declaredFeatures }
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
        copyNugetArtifacts outDir nugetAssemblyPaths externShimRoot
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

/// Build a project-as-DLL bundle (M5.1 stage 2c.2.iv).  Walks
/// `[project.packages]`, reads each package's `.l` files in
/// deterministic order, and routes through `Emitter.emitProject` so
/// every package emits into one bundled assembly.  Per-package
/// contract resources (`Lyric.Contract.<Pkg>`) are embedded by the
/// emitter; on success the runtimeconfig + stdlib closure ship into
/// the output dir alongside the bundle, mirroring the legacy
/// single-package build.
let private buildProject
        (manifestPath: string)
        (project: Lyric.Cli.Manifest.ProjectSection)
        (force: bool)
        (explicitOut: string option)
        (restoredPackageRefs: Lyric.Emitter.RestoredPackages.RestoredPackageRef list)
        (nugetAssemblyPaths: string list)
        (externShimRoot: string option)
        (activeFeatures: Set<string>)
        (declaredFeatures: Set<string>) : int =
    // `output = "per-package"` falls through to the legacy
    // per-source `lyric build` flow — the bootstrap stdlib's exact
    // shape — so the project-build path here only handles `single`.
    match project.Output with
    | Lyric.Cli.Manifest.PerPackage ->
        printErr "build: [project] output = \"per-package\" not yet wired through `lyric build`; \
                  invoke `lyric build <pkg>.l` per package, or set output = \"single\""
        1
    | Lyric.Cli.Manifest.Single ->
    let manifestDir =
        safeStr (Path.GetDirectoryName(Path.GetFullPath manifestPath)) "."
    let outAssembly =
        match explicitOut with
        | Some o -> Path.GetFullPath o
        | None ->
            let stem =
                match project.OutputAssembly with
                | Some s -> s
                | None   -> project.Name + ".dll"
            if Path.IsPathRooted stem then stem
            else Path.Combine(manifestDir, "bin", stem)
    let outDir =
        safeStr (Path.GetDirectoryName(Path.GetFullPath outAssembly)) "."
    Directory.CreateDirectory(outDir) |> ignore
    if List.isEmpty project.Packages then
        printErr (sprintf
            "build: %s [project.packages] is empty — single-DLL projects require explicit per-package source dirs (auto-discovery not yet wired)"
            manifestPath)
        1
    else
    // Gather per-package sources.  Each `.l` file under the named
    // dir contributes one element; deterministic order by relative
    // path so emit reproducibility doesn't depend on the
    // filesystem.
    let mutable hadFatal = false
    let pkgInputs = ResizeArray<Lyric.Emitter.Emitter.ProjectPackageInput>()
    for (pkgName, srcEntry) in project.Packages do
        let abs =
            if Path.IsPathRooted srcEntry then srcEntry
            else Path.Combine(manifestDir, srcEntry)
        // The manifest entry can be either a directory (whose `.l`
        // files all merge into one package via the multi-file path)
        // or a single `.l` file (one package per file — the layout
        // used by the bootstrap stdlib, where every `Std.X` lives in
        // a sibling `.l` under one shared `std/` dir).
        let lFiles =
            if File.Exists abs && abs.EndsWith ".l" then
                [abs]
            elif Directory.Exists abs then
                Directory.EnumerateFiles(abs, "*.l", SearchOption.AllDirectories)
                |> Seq.sortBy id
                |> Seq.toList
            else
                []
        if List.isEmpty lFiles then
            printErr (sprintf "build: project package '%s' source path '%s' is missing or contains no .l files"
                              pkgName abs)
            hadFatal <- true
        else
            let sources = lFiles |> List.map File.ReadAllText
            pkgInputs.Add
                { Lyric.Emitter.Emitter.ProjectPackageInput.PackageName = pkgName
                  Lyric.Emitter.Emitter.ProjectPackageInput.Sources     = sources }
    if hadFatal then 1
    else
    let asmName =
        safeStr (Path.GetFileNameWithoutExtension outAssembly) "out"
    let req : Lyric.Emitter.Emitter.ProjectEmitRequest =
        { Packages           = List.ofSeq pkgInputs
          AssemblyName       = asmName
          OutputPath         = outAssembly
          RestoredPackages   = restoredPackageRefs
          NugetAssemblyPaths = nugetAssemblyPaths
          ExternShimRoot     = externShimRoot
          Single             = true
          Target             = Lyric.Emitter.Emitter.Dotnet
          ActiveFeatures     = activeFeatures
          DeclaredFeatures   = declaredFeatures }
    let mutable hadError = false
    let result =
        try
            Emitter.emitProject req
        with e ->
            hadError <- true
            printErr (sprintf "internal error: %s" e.Message)
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
        writeRuntimeConfig outAssembly
        copyStdlibArtifacts outDir
        copyNugetArtifacts outDir nugetAssemblyPaths externShimRoot
        // BuildCache currently fingerprints a single source path;
        // skip caching for project builds rather than half-stamp it.
        ignore force
        printfn "built %s" outAssembly
        0
    | _ ->
        printErr (sprintf "%s: project build failed" manifestPath)
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
    copyIfExists (Path.Combine(cliDir, "Lyric.Jvm.Hosts.dll"))
    copyIfExists (Path.Combine(cliDir, "FSharp.Core.dll"))
    for p in Lyric.Emitter.Emitter.stdlibAssemblyPaths () do
        copyIfExists p

    // Rewrite the `System.Private.CoreLib` reference name in every
    // Lyric-emitted DLL we copied — the user's main PE plus each
    // `Lyric.Stdlib.<X>.dll` from the stdlib precompile cache.
    // `FSharp.Core.dll` already references `System.Runtime`, so the
    // no-match path is a fast scan; the patcher is idempotent.
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
    let buildExit =
        build sourcePath outPath true [] [] None Emitter.Dotnet
            Set.empty Set.empty
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
    printErr "  lyric build <source.l> [-o <output>] [--force] [--aot] [--rid <RID>] [--manifest <lyric.toml>] [--target dotnet|dotnet-legacy|jvm]"
    printErr "  lyric build --manifest <lyric.toml>  (project mode: bundles every [project.packages] entry into one DLL)"
    printErr "  lyric run   <source.l> [-- <args>...]"
    printErr "  lyric test  <source.l> [--filter <substring>] [--list] [--jvm]"
    printErr "  lyric bench <source.l> [--runs <N>] [--warmup <N>] [--filter <substring>]"
    printErr "  lyric fmt   <source.l> [--check] [--write] [--legacy]"
    printErr "  lyric lint  <source.l> [--error-on-warning]"
    printErr "  lyric prove <source.l> [--proof-dir <dir>] [--verbose] [--allow-unverified] [--json] [--explain --goal <n>]"
    printErr "  lyric doc   <source.l> [-o out.md]"
    printErr "  lyric openapi <spec.json> [-o <out.l>] [--client-name <Name>] [--package <Pkg.Name>]"
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
    printErr "  bench: measure runtime performance of @bench_module functions."
    printErr "    --runs <N>     number of timed iterations per benchmark (default: 10)."
    printErr "    --warmup <N>   un-timed warmup iterations before timing (default: 3)."
    printErr "    --filter <s>   only run benchmarks whose name contains <s>."
    printErr "    Each benchmarked function must be annotated @bench and have"
    printErr "    signature `func name(): Unit`.  The module must carry @bench_module"
    printErr "    at the file level and `import Std.Time` (auto-injected if absent)."
    printErr ""
    printErr "  fmt: reformat source to canonical Lyric style."
    printErr "    (default) print formatted output to stdout."
    printErr "    --write    overwrite the file in place."
    printErr "    --check    exit 1 if the file would change; print nothing."
    printErr "    --legacy   route through the F# AST formatter (drops `//` comments)."
    printErr "    The default backend is the self-hosted `Lyric.Fmt` (M5.3 stage 2),"
    printErr "    which preserves both `///` doc comments AND non-doc `//` and `/* */`."
    printErr ""
    printErr "  lint: report style and quality diagnostics."
    printErr "    --error-on-warning  treat warnings as errors (exit 1)."
    printErr "    Codes: L001 (PascalCase types), L002 (camelCase funcs),"
    printErr "           L003 (missing pub doc), L004 (TODO in doc comment),"
    printErr "           L005 (pub func without contracts)."
    printErr ""
    printErr "  openapi: generate a typed Lyric REST client from an OpenAPI 3.x JSON spec."
    printErr "    -o <out.l>               write generated source to this path."
    printErr "                             default: <spec-stem>_client.l next to the spec."
    printErr "    --client-name <Name>     base name for the generated client type (default: spec title)."
    printErr "    --package <Pkg.Name>     Lyric package declaration (default: Gen.<ClientName>)."
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
    printErr "  --sdk-info  print the resolved SDK root, stdlib DLL path, and"
    printErr "              embedded version info; useful for diagnosing install"
    printErr "              layout issues (B0040-B0042)."

let bootstrapDispatch (argv: string array) : int =
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
        let mutable compileTarget = Emitter.Dotnet
        let mutable selfHostedDotnet = true   // default: self-hosted MSIL pipeline
        let mutable featureSel = emptyFeatureSelection
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
            | "--features" :: list :: tail ->
                let parsed =
                    list.Split ','
                    |> Array.map (fun s -> s.Trim())
                    |> Array.filter (fun s -> s.Length > 0)
                    |> List.ofArray
                featureSel <- { featureSel with Cli = featureSel.Cli @ parsed }
                cursor <- tail
            | "--no-default-features" :: tail ->
                featureSel <- { featureSel with SuppressDefault = true }
                cursor <- tail
            | "--all-features" :: tail ->
                featureSel <- { featureSel with AllFeatures = true }
                cursor <- tail
            | "--target" :: "jvm" :: tail ->
                compileTarget <- Emitter.Jvm
                selfHostedDotnet <- false
                cursor <- tail
            | "--target" :: "dotnet" :: tail ->
                compileTarget <- Emitter.Dotnet
                selfHostedDotnet <- true    // self-hosted MSIL pipeline (default)
                cursor <- tail
            | "--target" :: "dotnet-legacy" :: tail ->
                compileTarget <- Emitter.Dotnet
                selfHostedDotnet <- false   // F# bootstrap emitter
                cursor <- tail
            | "-o" :: out :: tail ->
                explicitOut <- Some out
                cursor <- tail
            | s :: tail ->
                positional <- positional @ [s]
                cursor <- tail
            | [] -> ()
        // Pre-resolve the manifest once: the (optional) source-rooted
        // build path and the project-mode build path both want it,
        // and project-mode requires it (no positional source).
        let manifestPath =
            match manifestArg with
            | Some m -> Some (Path.GetFullPath m)
            | None ->
                match positional with
                | sourcePath :: _ ->
                    let dir =
                        safeStr
                            (Path.GetDirectoryName(Path.GetFullPath sourcePath))
                            "."
                    let candidate = Path.Combine(dir, "lyric.toml")
                    if File.Exists candidate then Some candidate else None
                | [] -> None
        let parsedManifest =
            match manifestPath with
            | None -> None
            | Some p ->
                match SelfHostedManifest.parseFile p with
                | Error e ->
                    printErr (Lyric.Cli.Manifest.renderError p e)
                    None
                | Ok m -> Some (p, m)
        let restoredPackageRefs =
            match parsedManifest with
            | None -> []
            | Some (_, manifest) ->
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
        // Phase 5 §M5.1 stage 2d.v: resolve [nuget] entries through
        // `project.assets.json` (written by `lyric restore`).  The
        // result feeds two parallel channels into the emit request:
        //   * `nugetAssemblyPaths` — every transitive runtime DLL,
        //     pre-loaded into the AppDomain so `findClrType` finds
        //     extern types declared by the auto-generated shims.
        //   * `externShimRoot` — `<manifestDir>/_extern/` where the
        //     `_extern/<lyric-pkg>.l` files live.  The emitter's
        //     resolver falls back here for non-builtin imports.
        let nugetAssemblyPaths, externShimRoot =
            match parsedManifest with
            | None -> [], None
            | Some (mPath, manifest) ->
                let manifestDir =
                    safeStr (Path.GetDirectoryName(Path.GetFullPath mPath)) "."
                let nugetPresent =
                    match manifest.Nuget with
                    | Some n -> not (List.isEmpty n.Packages)
                    | None   -> false
                if not nugetPresent then [], None
                else
                    match Lyric.Cli.NugetAssets.readForManifest manifestDir manifest with
                    | Error e ->
                        printErr (Lyric.Cli.NugetAssets.renderError e)
                        [], None
                    | Ok r ->
                        let paths =
                            r.Packages |> List.map (fun p -> p.RuntimeDll)
                        let externDir =
                            Path.Combine(manifestDir, "_extern")
                        paths, Some externDir
        // Project-mode dispatch: `lyric build --manifest lyric.toml`
        // (no positional source) where the manifest declares a
        // single-DLL `[project]`.  The bundle drops in
        // `<manifestDir>/bin/<output_assembly or project.Name>.dll`
        // unless `-o` overrides.  AOT for project builds is not yet
        // wired (the AOT publish wrapper assumes a single DLL with
        // one `Main`).
        // D045: resolve active feature set from manifest + CLI flags
        // before either build path runs.  Diagnostics already streamed
        // to stderr by `resolveFeatures`.
        let activeFeatures, declaredFeatures, featureErrCount =
            resolveFeatures featureSel
                (parsedManifest |> Option.map snd)
        if featureErrCount > 0 then 1
        else
        let projectModeRequested =
            List.isEmpty positional
            && (match parsedManifest with
                | Some (_, m) -> Option.isSome m.Project
                | None -> false)
        if projectModeRequested then
            if aot then
                printErr "build: --aot with [project] output = \"single\" is not yet supported"
                1
            else
                match parsedManifest with
                | Some (mPath, m) ->
                    match m.Project with
                    | Some proj ->
                        buildProject mPath proj force explicitOut
                            restoredPackageRefs nugetAssemblyPaths
                            externShimRoot
                            activeFeatures declaredFeatures
                    | None ->
                        printErr "build: missing source file"
                        printUsage ()
                        1
                | None ->
                    printErr "build: missing source file"
                    printUsage ()
                    1
        else
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
            if selfHostedDotnet && compileTarget = Emitter.Dotnet then
                // Self-hosted MSIL pipeline: bypass the F# emitter entirely.
                // `--target dotnet` (the default) routes here; `--target
                // dotnet-legacy` routes through the F# emitter below.
                let source = File.ReadAllText sourcePath
                try
                    let ok = SelfHostedMsil.compileToDll source dllOutPath
                    if ok then
                        printfn "built %s" dllOutPath
                        0
                    else
                        printErr (sprintf "%s: self-hosted MSIL compilation failed" sourcePath)
                        1
                with e ->
                    let inner = match Option.ofObj e.InnerException with
                                | Some ie -> sprintf "%s → %s" e.Message ie.Message
                                | None    -> e.Message
                    printErr (sprintf "%s: MSIL bridge error: %s" sourcePath inner)
                    1
            else
            let buildExit =
                build sourcePath dllOutPath force restoredPackageRefs
                    nugetAssemblyPaths externShimRoot compileTarget
                    activeFeatures declaredFeatures
            if buildExit <> 0 then buildExit
            elif compileTarget = Emitter.Jvm then
                // After the F# MSIL DLL succeeds, also emit a JAR via the
                // self-hosted JVM pipeline (Phase R4 /
                // docs/33-platform-parity-remediation.md §5.3–5.5).
                let source = File.ReadAllText sourcePath
                let packageName =
                    safeStr (Path.GetFileNameWithoutExtension sourcePath) "out"
                let jarPath =
                    match explicitOut with
                    | Some o -> safeStr (Path.ChangeExtension(o, ".jar")) (o + ".jar")
                    | None ->
                        let dir =
                            safeStr (Path.GetDirectoryName(Path.GetFullPath sourcePath)) "."
                        let name =
                            safeStr (Path.GetFileNameWithoutExtension sourcePath) "out"
                        Path.Combine(dir, name + ".jar")
                try
                    let ok = SelfHostedJvm.compileToJar source jarPath packageName
                    if ok then
                        printfn "built %s" jarPath
                        0
                    else
                        printErr (sprintf "%s: JVM self-hosted compilation failed" sourcePath)
                        1
                with e ->
                    printErr (sprintf "%s: JVM bridge error: %s" sourcePath e.Message)
                    1
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
    | "test" :: rest ->
        // `lyric test <source.l> [--filter <substring>] [--list] [--jvm]`
        // — bootstrap-grade test runner.  See
        // `docs/24-test-runner-plan.md` for the design.
        //
        // Strategy: parse the source, validate `@test_module` is
        // present, rewrite each `test "title" { body }` into a
        // synthesised `func __lyric_test_<i>(): Unit { body }`, and
        // append a synthesised `func main(): Int` that runs each in
        // a try/catch and prints a TAP-shaped report.  The rewritten
        // source is written to a temp file and handed to the regular
        // `build` + `dotnet exec` pipeline.
        //
        // `--jvm`: bootstrap-grade JVM path (B126).  The synthesised
        // source is compiled with `Emitter.Jvm` so JVM-specific stdlib
        // is selected, but the runner still uses `dotnet exec` because
        // the full Lyric→JVM compilation pipeline lands in B127+.  The
        // `@LyricTest`-annotated class shape is produced by
        // `lowerTestModuleClass` via `LPTestModule`; `lyric test --jvm`
        // integration with the JUnit 5 ConsoleLauncher is tracked in
        // `docs/32-junit-runner-sketch.md` §6 and deferred to B127.
        let mutable filter : string option = None
        let mutable listOnly = false
        let mutable jvmMode = false
        let mutable positional : string list = []
        let mutable cursor = rest
        let mutable usageError = false
        while not (List.isEmpty cursor) && not usageError do
            match cursor with
            | "--filter" :: v :: tail ->
                filter <- Some v
                cursor <- tail
            | "--filter" :: [] ->
                printErr "test: --filter requires an argument"
                usageError <- true
                cursor <- []
            | "--list" :: tail ->
                listOnly <- true
                cursor <- tail
            | "--jvm" :: tail ->
                jvmMode <- true
                cursor <- tail
            | "-v" :: tail | "--verbose" :: tail ->
                cursor <- tail   // currently unused; reserved for v2
            | x :: tail when x.StartsWith "-" ->
                printErr (sprintf "test: unknown flag '%s'" x)
                usageError <- true
                cursor <- []
            | x :: tail ->
                positional <- positional @ [x]
                cursor <- tail
            | [] -> ()
        if usageError then 64
        else
            match positional with
            | [] ->
                printErr "test: missing source file"
                printUsage ()
                64
            | sourcePath :: _ ->
                if not (File.Exists sourcePath) then
                    printErr (sprintf "test: source file not found: %s"
                                sourcePath)
                    64
                else
                let source = File.ReadAllText sourcePath
                if listOnly then
                    match SelfHostedTestSynth.listEntries source with
                    | Error diags ->
                        for d in diags do printDiag d
                        2
                    | Ok entries ->
                        for e in entries do
                            match e with
                            | TestSynth.TestEntry t -> printfn "%s" t
                            | TestSynth.PropertyEntry (t, _) ->
                                printfn "%s (skipped: property)" t
                            | TestSynth.FixtureEntry n ->
                                printfn "%s (fixture; not runnable)" n
                        0
                else
                match SelfHostedTestSynth.synthesize source filter with
                | TestSynth.NoTestModule _ ->
                    printErr (sprintf
                        "T0900 %s: lyric test requires '@test_module' at the file head"
                        sourcePath)
                    64
                | TestSynth.UserMainExists sp ->
                    printErr (sprintf
                        "T0902 %s [%d:%d]: @test_module package may not declare 'func main()'"
                        sourcePath sp.Start.Line sp.Start.Column)
                    2
                | TestSynth.FixtureUnsupported sp ->
                    printErr (sprintf
                        "T0901 %s [%d:%d]: 'fixture' declarations are not yet supported by lyric test"
                        sourcePath sp.Start.Line sp.Start.Column)
                    2
                | TestSynth.ParseFailures diags ->
                    for d in diags do printDiag d
                    2
                | TestSynth.Synthesised (rewritten, _testCount, _skipCount) ->
                    // Write the rewritten source to a temp file so
                    // diagnostics path-prefixes don't conflict with
                    // the user's working tree.
                    let tmp =
                        Path.Combine(Path.GetTempPath(),
                                     "lyric-test-"
                                     + Guid.NewGuid().ToString("N"))
                    Directory.CreateDirectory(tmp) |> ignore
                    let stem =
                        safeStr (Path.GetFileNameWithoutExtension sourcePath)
                                "tests"
                    let synthPath = Path.Combine(tmp, stem + ".l")
                    File.WriteAllText(synthPath, rewritten)
                    let outPath = Path.Combine(tmp, stem + ".dll")
                    // B126: --jvm selects the JVM-target stdlib kernel.
                    // Full Lyric→JVM compilation (ConsoleLauncher integration)
                    // lands in B127+; for now the TAP runner still executes
                    // via `dotnet exec` using the JVM-compatible stdlib.
                    let compileTarget =
                        if jvmMode then Emitter.Jvm else Emitter.Dotnet
                    if jvmMode then
                        eprintfn "note: lyric test --jvm uses TAP runner (JUnit 5 integration deferred to B127+)"
                    let buildExit =
                        build synthPath outPath true [] [] None compileTarget
                            Set.empty Set.empty
                    if buildExit <> 0 then
                        // Strip the temp-path prefix from any diagnostic
                        // line so users see "their" path.  build()
                        // already printed diagnostics; we only re-map
                        // the exit code from "build failed" (1) to
                        // "compilation failed" (2) per the design's
                        // exit-code table.
                        2
                    else
                        let psi = Diagnostics.ProcessStartInfo()
                        psi.FileName <- "dotnet"
                        psi.ArgumentList.Add "exec"
                        psi.ArgumentList.Add outPath
                        psi.UseShellExecute <- false
                        let proc =
                            match Option.ofObj
                                    (Diagnostics.Process.Start psi) with
                            | Some p -> p
                            | None ->
                                printErr "failed to start dotnet"
                                exit 1
                        use _ = proc
                        proc.WaitForExit()
                        proc.ExitCode
    | "bench" :: rest ->
        // `lyric bench <source.l> [--runs <N>] [--warmup <N>] [--filter <s>]`
        // — benchmark runner.  Synthesises a timing harness around each
        // function annotated `@bench` in a `@bench_module` file, compiles it,
        // and runs it once via `dotnet exec`.  The synthesised program owns all
        // timing and output; the CLI just passes stdout through.
        let mutable runsArg   = 10
        let mutable warmupArg = 3
        let mutable filterArg : string option = None
        let mutable positional : string list = []
        let mutable cursor = rest
        let mutable usageError = false
        while not (List.isEmpty cursor) && not usageError do
            match cursor with
            | "--runs" :: n :: tail ->
                match System.Int32.TryParse n with
                | true, v when v > 0 -> runsArg <- v; cursor <- tail
                | _ ->
                    printErr (sprintf "bench: --runs expects a positive integer, got '%s'" n)
                    usageError <- true
                    cursor <- []
            | "--runs" :: [] ->
                printErr "bench: --runs requires an argument"
                usageError <- true
                cursor <- []
            | "--warmup" :: n :: tail ->
                match System.Int32.TryParse n with
                | true, v when v >= 0 -> warmupArg <- v; cursor <- tail
                | _ ->
                    printErr (sprintf "bench: --warmup expects a non-negative integer, got '%s'" n)
                    usageError <- true
                    cursor <- []
            | "--warmup" :: [] ->
                printErr "bench: --warmup requires an argument"
                usageError <- true
                cursor <- []
            | "--filter" :: f :: tail ->
                filterArg <- Some f
                cursor <- tail
            | "--filter" :: [] ->
                printErr "bench: --filter requires an argument"
                usageError <- true
                cursor <- []
            | x :: tail when x.StartsWith "-" ->
                printErr (sprintf "bench: unknown flag '%s'" x)
                usageError <- true
                cursor <- []
            | x :: tail ->
                positional <- positional @ [x]
                cursor <- tail
            | [] -> ()
        if usageError then 64
        else
        match positional with
        | [] ->
            printErr "bench: missing source file"
            printUsage ()
            64
        | sourcePath :: _ ->
            if not (File.Exists sourcePath) then
                printErr (sprintf "bench: source file not found: %s" sourcePath)
                64
            else
            let source = File.ReadAllText sourcePath
            match SelfHostedBench.synthesize source runsArg warmupArg (Option.defaultValue "" filterArg) with
            | SelfHostedBench.NoBenchModule _ ->
                printErr (sprintf
                    "B0900 %s: lyric bench requires '@bench_module' at the file head"
                    sourcePath)
                64
            | SelfHostedBench.UserMainExists sp ->
                printErr (sprintf
                    "B0901 %s [%d:%d]: @bench_module package may not declare 'func main()'"
                    sourcePath sp.Start.Line sp.Start.Column)
                2
            | SelfHostedBench.ParseFailures diags ->
                for d in diags do printDiag d
                2
            | SelfHostedBench.Synthesised (rewritten, benchCount) ->
                if benchCount = 0 then
                    let msg =
                        match filterArg with
                        | None ->
                            sprintf "B0902 %s: no @bench functions found; annotate functions with @bench"
                                sourcePath
                        | Some f ->
                            sprintf "B0902 %s: no @bench functions match filter '%s'" sourcePath f
                    printErr msg
                    64
                else
                let rewrittenFinal = rewritten
                let tmp =
                    Path.Combine(Path.GetTempPath(),
                                 "lyric-bench-"
                                 + Guid.NewGuid().ToString("N"))
                Directory.CreateDirectory(tmp) |> ignore
                let stem      = safeStr (Path.GetFileNameWithoutExtension sourcePath) "bench"
                let synthPath = Path.Combine(tmp, stem + ".l")
                let outPath   = Path.Combine(tmp, stem + ".dll")
                File.WriteAllText(synthPath, rewrittenFinal)
                let buildExit =
                    build synthPath outPath true [] [] None Emitter.Dotnet
                        Set.empty Set.empty
                if buildExit <> 0 then 2
                else
                    let psi = Diagnostics.ProcessStartInfo()
                    psi.FileName <- "dotnet"
                    psi.ArgumentList.Add "exec"
                    psi.ArgumentList.Add outPath
                    psi.UseShellExecute <- false
                    let proc =
                        match Option.ofObj (Diagnostics.Process.Start psi) with
                        | Some p -> p
                        | None ->
                            printErr "bench: failed to start dotnet"
                            exit 1
                    use _ = proc
                    proc.WaitForExit()
                    proc.ExitCode
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
            // All prove flags are handled by the self-hosted CLI (cli.l).
            // This path only runs when the SelfHostedCli bridge fails.
            let source = File.ReadAllText sourcePath
            match SelfHostedVerifier.prove source allowUnverified with
            | Error msg ->
                printErr (sprintf "prove: %s" msg)
                1
            | Ok r ->
                for d in r.Diagnostics do
                    printDiag d
                if r.Total > 0 then
                    let suffix =
                        if allowUnverified && r.Unknowns > 0 then
                            sprintf " [%d unverified, allowed]" r.Unknowns
                        else ""
                    printfn "%d/%d obligations discharged (%s)%s"
                        r.Discharged r.Total r.Level suffix
                else
                    printfn "no proof obligations: package is %s" r.Level
                if r.HasErrDiag || r.HasCex then 1 else 0
    | "fmt" :: rest ->
        // `lyric fmt <source.l> [--check] [--write]`
        // Default: print formatted output to stdout.
        // --write: overwrite the file in place.
        // --check: exit 1 if formatting would change the file; print nothing.
        // Routes through the self-hosted `Lyric.Fmt` (M5.3) which preserves
        // `//` comments via the red/green CST.
        let mutable checkMode = false
        let mutable writeMode = false
        let mutable positional : string list = []
        let mutable cursor = rest
        while not (List.isEmpty cursor) do
            match cursor with
            | "--check" :: tail ->
                checkMode <- true
                cursor <- tail
            | "--write" :: tail ->
                writeMode <- true
                cursor <- tail
            | s :: tail ->
                positional <- positional @ [s]
                cursor <- tail
            | [] -> ()
        match positional with
        | [] ->
            printErr "fmt: missing source file"
            printUsage ()
            1
        | sourcePath :: _ ->
            if not (File.Exists sourcePath) then
                printErr (sprintf "fmt: source file not found: %s" sourcePath)
                1
            else
            let source = File.ReadAllText sourcePath
            let formatted = SelfHostedFmt.format source
            let isFmt ()  = SelfHostedFmt.isFormatted source
            if checkMode then
                if isFmt () then
                    0
                else
                    printErr (sprintf "%s: not formatted — run `lyric fmt --write`" sourcePath)
                    1
            elif writeMode then
                File.WriteAllText(sourcePath, formatted)
                printfn "formatted %s" sourcePath
                0
            else
                Console.Out.Write(formatted)
                0
    | "lint" :: rest ->
        // `lyric lint <source.l> [--error-on-warning]`
        // Prints style/quality diagnostics.  Exit codes:
        //   0 — no diagnostics (or only warnings when --error-on-warning
        //       is not set)
        //   1 — at least one error diagnostic
        //   2 — usage/IO error
        let mutable errorOnWarning = false
        let mutable positional : string list = []
        let mutable cursor = rest
        while not (List.isEmpty cursor) do
            match cursor with
            | "--error-on-warning" :: tail ->
                errorOnWarning <- true
                cursor <- tail
            | s :: tail ->
                positional <- positional @ [s]
                cursor <- tail
            | [] -> ()
        match positional with
        | [] ->
            printErr "lint: missing source file"
            printUsage ()
            2
        | sourcePath :: _ ->
            if not (File.Exists sourcePath) then
                printErr (sprintf "lint: source file not found: %s" sourcePath)
                2
            else
            let source = File.ReadAllText sourcePath
            let parsed = Lyric.Parser.Parser.parse source
            // Surface parse errors before lint — broken files may produce
            // spurious lint hits.
            for d in parsed.Diagnostics do
                if d.Severity = DiagError then printDiag d
            let result = SelfHostedLint.lint source
            for d in result.Diagnostics do
                printErr (Lyric.Cli.Lint.renderDiagnostic d)
            let hasError   = result.Diagnostics |> List.exists (fun d -> d.Severity = Lyric.Cli.Lint.LintError)
            let hasWarning = result.Diagnostics |> List.exists (fun d -> d.Severity = Lyric.Cli.Lint.LintWarning)
            if hasError || (errorOnWarning && hasWarning) then 1 else 0
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
            let md = SelfHostedDoc.generate source
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
                let lyricCount = List.length manifest.Dependencies
                let nugetEntries =
                    match manifest.Nuget with
                    | None -> []
                    | Some n -> n.Packages
                let nugetCount = List.length nugetEntries
                if nugetCount = 0 then
                    printfn "restore: %d Lyric package%s declared in %s"
                        lyricCount (if lyricCount = 1 then "" else "s") mfPath
                else
                    printfn "restore: %d Lyric + %d NuGet package%s declared in %s"
                        lyricCount nugetCount
                        (if lyricCount + nugetCount = 1 then "" else "s") mfPath
                // Phase 5 §M5.1 stage 2d.iv: after `dotnet restore`
                // populates the NuGet cache, write each NuGet
                // package's auto-generated `_extern/<lyric-pkg>.l`
                // shim (and an optional `.skip.md` report) to the
                // manifest directory so reviewers see the surface
                // that will be in scope.  Failures here are
                // reported as warnings — the cache is still good
                // and the user can re-run after fixing the issue.
                if nugetCount > 0 then
                    let externDir = Path.Combine(manifestDir, "_extern")
                    Directory.CreateDirectory externDir |> ignore
                    let target =
                        match manifest.Nuget with
                        | Some { Options = { Target = Some t } } -> t
                        | _ -> "net10.0"
                    let mutable shimsOk = 0
                    for entry in nugetEntries do
                        match
                            Lyric.Cli.NugetShim.tryLocateNugetDll
                                entry.Id entry.Version target with
                        | None ->
                            printErr
                                (sprintf
                                    "restore: B0030 could not locate '%s' v%s for shim generation; skipping"
                                    entry.Id entry.Version)
                        | Some dll ->
                            match
                                Lyric.Cli.NugetShim.generate
                                    dll entry.Id entry.Version [] with
                            | Error e ->
                                printErr
                                    (Lyric.Cli.NugetShim.renderShimError e)
                            | Ok shim ->
                                let shimPath =
                                    Path.Combine(
                                        externDir,
                                        shim.LyricPackage + ".l")
                                File.WriteAllText(shimPath, shim.LyricSource)
                                match shim.SkipReport with
                                | Some report ->
                                    let skipPath =
                                        Path.Combine(
                                            externDir,
                                            shim.LyricPackage + ".skip.md")
                                    File.WriteAllText(skipPath, report)
                                | None -> ()
                                shimsOk <- shimsOk + 1
                                printfn
                                    "restore:   %s -> _extern/%s.l (%d types, %d methods, %d skipped)"
                                    entry.Id shim.LyricPackage
                                    shim.ExternTypes shim.ExternMethods
                                    shim.SkippedMembers
                    if shimsOk < nugetCount then
                        printErr
                            (sprintf
                                "restore: %d of %d NuGet shim%s did not generate cleanly — see B0030 above"
                                (nugetCount - shimsOk) nugetCount
                                (if nugetCount = 1 then "" else "s"))
                // Maven Central resolution (docs/31-maven-linking.md,
                // D053).  Runs only when `[maven]` is present.
                let mavenEntries =
                    match manifest.Maven with
                    | None -> []
                    | Some m -> m.Packages
                let mavenCount = List.length mavenEntries
                if mavenCount > 0 then
                    printfn "restore: resolving %d Maven package%s..."
                        mavenCount (if mavenCount = 1 then "" else "s")
                match Lyric.Cli.Pack.runMavenRestore manifest manifestDir false with
                | Error msg ->
                    printErr (sprintf "restore: %s" msg)
                    // Non-fatal for the overall restore if NuGet already
                    // succeeded; report but carry on (exit 0).
                | Ok jars ->
                    let topLevelJars =
                        jars |> List.filter (fun (j: Lyric.Cli.Maven.ResolvedMavenJar) ->
                            j.IsTopLevel)
                    let mutable mavenShimsOk = 0
                    for jar in topLevelJars do
                        let shim = Lyric.Cli.MavenShim.generate jar
                        // B0053 drift check: skip regeneration when the
                        // existing shim already matches the JAR's SHA-256.
                        if not (Lyric.Cli.MavenShim.shimIsCurrentFor
                                    manifestDir shim.RelativePath jar.Sha256) then
                            Lyric.Cli.MavenShim.writeShim manifestDir shim
                        mavenShimsOk <- mavenShimsOk + 1
                        printfn
                            "restore:   %s:%s -> %s (%d types, %d methods, %d skipped)"
                            jar.Group jar.Artifact shim.RelativePath
                            shim.ExternTypes shim.ExternMethods
                            shim.SkippedMembers
                    if mavenCount > 0 && mavenShimsOk < mavenCount then
                        printErr
                            (sprintf
                                "restore: %d of %d Maven shim%s did not generate cleanly"
                                (mavenCount - mavenShimsOk) mavenCount
                                (if mavenCount = 1 then "" else "s"))
                0
            | Error msg ->
                printErr msg
                1
    | "openapi" :: rest ->
        // `lyric openapi <spec.json> [-o <out.l>] [--client-name <Name>] [--package <Pkg.Name>]`
        // — generate a typed Lyric REST client from an OpenAPI 3.x JSON spec.
        //
        // Reads the spec, parses its paths and schemas, then emits a `.l` file
        // containing record types and async client methods that delegate to
        // `Std.Rest.RestClient`.
        let mutable explicitOut : string option = None
        let mutable clientName  : string option = None
        let mutable packageName : string option = None
        let mutable positional  : string list   = []
        let mutable cursor      = rest
        while not (List.isEmpty cursor) do
            match cursor with
            | "-o" :: out :: tail ->
                explicitOut <- Some out
                cursor <- tail
            | "--client-name" :: n :: tail ->
                clientName <- Some n
                cursor <- tail
            | "--package" :: p :: tail ->
                packageName <- Some p
                cursor <- tail
            | s :: tail ->
                positional <- positional @ [s]
                cursor <- tail
            | [] -> ()
        match positional with
        | [] ->
            printErr "openapi: missing spec file"
            printUsage ()
            1
        | specPath :: _ ->
            if not (File.Exists specPath) then
                printErr (sprintf "openapi: spec file not found: %s" specPath)
                1
            else
                let outPath =
                    match explicitOut with
                    | Some o -> o
                    | None ->
                        let dir =
                            safeStr (Path.GetDirectoryName(Path.GetFullPath specPath)) "."
                        let stem =
                            safeStr (Path.GetFileNameWithoutExtension specPath) "api"
                        Path.Combine(dir, stem + "_client.l")
                // Empty string means "derive from spec title" in the Lyric bridge.
                let cn = clientName  |> Option.defaultValue ""
                let pn = packageName |> Option.defaultValue ""
                match Lyric.Cli.SelfHostedOpenApi.generateToFile specPath cn pn outPath with
                | Error msg ->
                    printErr (sprintf "openapi: %s" msg)
                    1
                | Ok path ->
                    printfn "generated %s" path
                    0
    | "--sdk-info" :: _ ->
        // Print SDK root discovery results and version info.
        // Mirrors docs/22 §4 + §5; diagnostics B0040-B0042 surface here.
        let info = Lyric.Emitter.Emitter.getSdkInfo ()
        (match info.Source with
         | Lyric.Emitter.SdkRoot.SdkSource.EnvVar ->
             printfn "sdk-root:    %s (from LYRIC_SDK_ROOT)"
                     (Option.defaultValue "(unset)" info.Root)
         | Lyric.Emitter.SdkRoot.SdkSource.BinaryRelative ->
             printfn "sdk-root:    %s (binary-relative)"
                     (Option.defaultValue "(none)" info.Root)
         | Lyric.Emitter.SdkRoot.SdkSource.NotFound ->
             let envSet =
                 Option.isSome (Option.ofObj (System.Environment.GetEnvironmentVariable "LYRIC_SDK_ROOT"))
             if envSet then
                 printErr "B0040 error [0:0]: LYRIC_SDK_ROOT is set but lib/Lyric.Stdlib.dll was not found there"
             printfn "sdk-root:    (not found — source-tree fallback active)")
        (match info.StdlibDll with
         | Some dll -> printfn "stdlib-dll:  %s" dll
         | None     -> printfn "stdlib-dll:  (not found)")
        (match info.Version with
         | Some (lv, sv, cv, bd) ->
             printfn "language:    %s" lv
             printfn "stdlib:      %s" sv
             printfn "compiler:    %s" cv
             printfn "build-date:  %s" bd
         | None ->
             match info.StdlibDll with
             | Some dll ->
                 printErr (sprintf "B0042 warning [0:0]: '%s' is missing the Lyric.SdkVersion resource" dll)
                 printfn "version:     (no Lyric.SdkVersion resource in stdlib DLL)"
             | None ->
                 printfn "version:     (n/a)")
        if info.Source = Lyric.Emitter.SdkRoot.SdkSource.NotFound then 1 else 0
    | unknown :: _ ->
        printErr (sprintf "unknown command: %s" unknown)
        printUsage ()
        1

// ─────────────────────────────────────────────────────────────────────────────
// Hidden commands used by the self-hosted Lyric.Emitter / Lyric.ContractMeta
// packages to shell back to the F# bootstrap compiler.
// These are handled BEFORE the self-hosted CLI is consulted to avoid
// circularity (the self-hosted CLI calls Lyric.Emitter which calls back here).
// ─────────────────────────────────────────────────────────────────────────────

/// `lyric --internal-build <srcFile> -o <outFile> [--target dotnet|jvm]`
/// Single-file compile with the F# emitter.  Minimal flag set; no manifest,
/// no NuGet, no AOT.  Errors are printed to stderr and the process exits
/// non-zero.  Used by the Lyric `Lyric.Emitter` package.
let private internalBuild (rest: string list) : int =
    let mutable srcPath = ""
    let mutable outPath = ""
    let mutable target  = Emitter.Dotnet
    let mutable cursor  = rest
    while not (List.isEmpty cursor) do
        match cursor with
        | "-o" :: out :: tail ->
            outPath <- out
            cursor  <- tail
        | "--target" :: "jvm" :: tail ->
            target <- Emitter.Jvm
            cursor <- tail
        | "--target" :: _ :: tail ->
            target <- Emitter.Dotnet
            cursor <- tail
        | arg :: tail ->
            if not (arg.StartsWith("-", StringComparison.Ordinal)) then
                srcPath <- arg
            cursor <- tail
        | [] -> cursor <- []

    if String.IsNullOrEmpty srcPath || not (File.Exists srcPath) then
        printErr (sprintf "internal-build: source file not found: %s" srcPath)
        1
    elif String.IsNullOrEmpty outPath then
        printErr "internal-build: missing -o <outputPath>"
        1
    else
        let source = File.ReadAllText srcPath
        match Option.ofObj (Path.GetDirectoryName outPath) with
        | Some dir when not (String.IsNullOrEmpty dir) ->
            Directory.CreateDirectory dir |> ignore
        | _ -> ()
        let asmName =
            match Option.ofObj (Path.GetFileNameWithoutExtension outPath) with
            | Some n -> n
            | None   -> "lyric_build_out"
        let req : Emitter.EmitRequest =
            { Source             = source
              AssemblyName       = asmName
              OutputPath         = outPath
              RestoredPackages   = []
              NugetAssemblyPaths = []
              ExternShimRoot     = None
              Target             = target
              ActiveFeatures     = Set.empty
              DeclaredFeatures   = Set.empty }
        let result = Emitter.emit req
        let errs   = result.Diagnostics |> List.filter (fun d -> d.Severity = DiagError)
        for d in result.Diagnostics do
            printErr (sprintf "%s %s [%d:%d]: %s"
                d.Code
                (if d.Severity = DiagError then "error" else "warning")
                d.Span.Start.Line d.Span.Start.Column d.Message)
        if not (List.isEmpty errs) then
            printErr (sprintf "%s: build failed" srcPath)
            1
        else
            writeRuntimeConfig outPath
            0

/// `lyric --internal-contract-meta read <dll>`
/// Outputs the embedded Lyric.Contract JSON to stdout, or nothing if absent.
///
/// `lyric --internal-contract-meta diff`
/// Reads old and new JSON from stdin (separated by `\n---\n`), diffs them,
/// and prints each rendered entry followed by a blank line.
/// Used by the Lyric `Lyric.ContractMeta` package.
let private internalContractMeta (rest: string list) : int =
    match rest with
    | "read" :: dllPath :: _ ->
        if not (File.Exists dllPath) then
            printErr (sprintf "internal-contract-meta read: file not found: %s" dllPath)
            1
        else
            match Lyric.Emitter.ContractMeta.readFromAssembly dllPath with
            | None      -> ()   // empty stdout = no contract
            | Some json -> printfn "%s" json
            0
    | "diff" :: _ ->
        let stdin  = Console.In.ReadToEnd()
        let parts  = stdin.Split([| "\n---\n" |], StringSplitOptions.None)
        if parts.Length < 2 then
            printErr "internal-contract-meta diff: expected old and new JSON in stdin, separated by \\n---\\n"
            1
        else
            let oldJson = parts.[0]
            let newJson = parts.[1]
            match Lyric.Emitter.ContractMeta.parseFromJson oldJson,
                  Lyric.Emitter.ContractMeta.parseFromJson newJson with
            | Some oldC, Some newC ->
                let entries = Lyric.Emitter.ContractMeta.diffContracts oldC newC
                for entry in entries do
                    printfn "%s\n" (Lyric.Emitter.ContractMeta.renderDiffEntry entry)
                0
            | None, _ ->
                printErr "internal-contract-meta diff: could not parse old contract JSON"
                1
            | _, None ->
                printErr "internal-contract-meta diff: could not parse new contract JSON"
                1
    | _ ->
        printErr "internal-contract-meta: unknown subcommand (expected 'read' or 'diff')"
        1

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

[<EntryPoint>]
let main (argv: string array) : int =
    // Ensure LYRIC_BIN and LYRIC_CLI_DLL are available so that the
    // Lyric.Emitter bootstrap Lyric package (emitter.l) can shell back to
    // this process for --internal-build operations without needing `lyric`
    // on PATH.
    if isNull (Environment.GetEnvironmentVariable "LYRIC_BIN") then
        try
            match Option.ofObj (Diagnostics.Process.GetCurrentProcess().MainModule) with
            | Some m when not (String.IsNullOrEmpty m.FileName) ->
                Environment.SetEnvironmentVariable("LYRIC_BIN", m.FileName)
            | _ -> ()
        with _ -> ()
    if isNull (Environment.GetEnvironmentVariable "LYRIC_CLI_DLL") then
        try
            match Option.ofObj (Reflection.Assembly.GetEntryAssembly()) with
            | Some entry when not (String.IsNullOrEmpty entry.Location)
                           && File.Exists entry.Location ->
                Environment.SetEnvironmentVariable("LYRIC_CLI_DLL", entry.Location)
            | _ -> ()
        with _ -> ()

    let args = List.ofArray argv
    match args with
    | "--internal-build" :: rest ->
        internalBuild rest
    | "--internal-contract-meta" :: rest ->
        internalContractMeta rest
    | _ ->
        // Attempt to dispatch through the self-hosted Lyric.Cli.
        // Falls back to the F# bootstrap dispatcher when the self-hosted
        // package cannot be compiled or loaded.
        match SelfHostedCli.tryRun argv with
        | Some code -> code
        | None      -> bootstrapDispatch argv
