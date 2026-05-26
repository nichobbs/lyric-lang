/// Shared utilities for the `SelfHosted*` bridge modules
/// (`SelfHostedCli.fs`, `SelfHostedFmt.fs`, etc.).
///
/// Each bridge module follows the same pattern: compile a tiny
/// driver program so the emitter materialises a self-hosted DLL into
/// the per-process stdlib cache, `Assembly.LoadFrom` every cached
/// DLL, reflect out the static entry point on
/// `Lyric.<Name>.Program`, and cache the resulting delegate for
/// subsequent calls in the same process.
///
/// # Single-shot semantics (#344)
///
/// Every bridge calls `preloadStdlibAssemblies` on first use and
/// caches the resolved delegate forever afterwards.  This is safe
/// for one-shot CLI invocations (the common case): the working set
/// grows by exactly one set of stdlib assemblies, then stabilises.
///
/// In a long-running daemon (a future `lyric lsp` is the motivating
/// example) the same bridge is hit many times.  Today this is still
/// safe because the delegate cache prevents repeated
/// `Assembly.LoadFrom` calls.  It would become a real leak if either
///
///   * the bridge stops caching and resolves every call (don't do
///     that — the resolve is the slow part anyway), or
///   * a future LSP recompiles with different feature flags and
///     produces a new set of stdlib DLLs that need to be loaded
///     and later released.
///
/// The structural fix for that future is to load into a collectible
/// `AssemblyLoadContext` (`isCollectible = true`, .NET Core 3+) so
/// that a daemon can unload the per-session ALC before allocating a
/// fresh one.  Until the LSP lands and exercises that path, the
/// bridges stay on the default AppDomain via `Assembly.LoadFrom`
/// — see `loadFromCache` below for the single seam to swap.
module internal Lyric.Cli.SelfHostedBridge

open System
open System.IO
open System.Reflection
open Lyric.Lexer
open Lyric.Emitter

/// Load every Lyric-emitted stdlib DLL in the per-process cache into
/// the default AppDomain.  Idempotent: `Assembly.LoadFrom` returns
/// the cached `Assembly` on a duplicate path.  Best-effort —
/// missing/corrupt cache entries surface later when a consumer
/// reflects out a missing type.
///
/// See module docstring for the single-shot semantics and the
/// future-proofing path (collectible AssemblyLoadContext).
let preloadStdlibAssemblies () : unit =
    for p in Emitter.stdlibAssemblyPaths () do
        try Assembly.LoadFrom p |> ignore
        with _ -> ()

/// Load a single bridge DLL by path.  Lives here so the future
/// collectible-ALC migration only has to change one call site.
let loadFromCache (path: string) : Assembly =
    Assembly.LoadFrom path

/// Compile a tiny driver source so the emitter materialises
/// `Lyric.Msil.Bridge.dll` (and the rest of the self-hosted stdlib)
/// into the per-process cache, then locate the bridge DLL.  Shared by
/// the `SelfHostedMsil` (single-package) and `SelfHostedMsilProject`
/// (multi-package) shims to avoid drift between near-identical copies
/// of this preparation code (#1373).
///
/// `label` distinguishes the per-bridge scratch directory and assembly
/// name; `driverSource` is the trivial top-level Lyric program whose
/// imports pull `Msil.Bridge` into the emit graph.
let ensureMsilBridgeAssembly (label: string) (driverSource: string) : string =
    let scratch =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-%s-%d"
                         label
                         (System.Diagnostics.Process.GetCurrentProcess().Id))
    Directory.CreateDirectory scratch |> ignore
    AppDomain.CurrentDomain.ProcessExit.Add(fun _ ->
        try Directory.Delete(scratch, recursive = true) with _ -> ())
    let asmName = sprintf "Lyric.%s.Bridge" (label.Replace("-", "."))
    let dllPath = Path.Combine(scratch, asmName + ".dll")
    let req : Emitter.EmitRequest =
        { Source             = driverSource
          AssemblyName       = asmName
          OutputPath         = dllPath
          RestoredPackages   = []
          NugetAssemblyPaths = []
          ExternShimRoot     = None
          Target             = Emitter.Dotnet
          ActiveFeatures     = Set.empty
          DeclaredFeatures   = Set.empty }
    let result = Emitter.emit req
    let errs =
        result.Diagnostics
        |> List.filter (fun d -> d.Severity = DiagError)
    if not (List.isEmpty errs) then
        let msg =
            errs
            |> List.map (fun d -> sprintf "  %s @ %d:%d  %s"
                                       d.Code
                                       d.Span.Start.Line
                                       d.Span.Start.Column
                                       d.Message)
            |> String.concat "\n"
        failwithf "self-hosted %s: emitter produced errors:\n%s" label msg

    preloadStdlibAssemblies ()

    let lyricMsilBridgeDll =
        Emitter.stdlibAssemblyPaths ()
        |> List.tryFind (fun p ->
            let n = Path.GetFileNameWithoutExtension p
            n = "Lyric.Msil.Bridge")
    match lyricMsilBridgeDll with
    | Some p -> p
    | None ->
        let cached =
            Emitter.stdlibAssemblyPaths ()
            |> List.map (fun p ->
                match Option.ofObj (Path.GetFileName p) with
                | Some n -> n
                | None -> "<unknown>")
            |> String.concat ", "
        failwithf "self-hosted %s: 'Lyric.Msil.Bridge.dll' not found in stdlib cache after emit (cached: %s)" label cached

/// Band 6: locate the `lyric-stdlib/std/` directory by walking up from
/// `AppContext.BaseDirectory`, then read every top-level `*.l` source file
/// (excluding the `_kernel/` subdirectory, which contains extern declarations
/// that are not meaningful to the self-hosted parser when used as plain items).
///
/// Returns the file contents as a `System.Collections.Generic.List<string>`.
/// Returns an empty list when the stdlib directory cannot be found (graceful
/// degradation — callers fall back to advisory-only type checking).
let findStdlibSources () : System.Collections.Generic.List<string> =
    let result = System.Collections.Generic.List<string>()
    let mutable dir = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable stdlibDir : DirectoryInfo option = None
    while stdlibDir.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric-stdlib", "std")
        if Directory.Exists candidate then
            stdlibDir <- Some (DirectoryInfo candidate)
        dir <- dir.Value.Parent |> Option.ofObj
    match stdlibDir with
    | None -> ()
    | Some sd ->
        for f in sd.GetFiles("*.l") do
            try result.Add(File.ReadAllText f.FullName)
            with ex ->
                eprintfn "lyric: warning: could not read stdlib source '%s': %s" f.FullName ex.Message
    result
