/// Bridge from the F# `lyric` CLI to the self-hosted MSIL compilation pipeline
/// (`Msil.Bridge` — Phase R6).  Chains the self-hosted lexer → parser → codegen
/// → MSIL lowering → PE writer in a single in-process call via reflection,
/// avoiding any subprocess round-trip.
///
/// Strategy: compile a tiny "driver" Lyric program whose only job is to
/// `import Msil.Bridge`.  The emitter precompiles `Msil.Bridge.dll` into its
/// per-process stdlib cache as a side-effect.  We then `Assembly.LoadFrom`
/// every cached DLL into the AppDomain (so the transitive dependency chain
/// resolves), reflect out the static `compileToMsil(string, string)` entry
/// point on `Msil.Bridge.Program`, and cache the resulting delegate for
/// subsequent calls in the same process.
module Lyric.Cli.SelfHostedMsil

open System
open System.IO
open System.Reflection
open Lyric.Lexer
open Lyric.Emitter

/// Source of the throwaway driver program.  The empty `main` is the minimum
/// the emitter accepts; the `import Msil.Bridge` triggers the stdlib precompile
/// path that drops `Lyric.Msil.Bridge.dll` into the cache returned by
/// `Emitter.stdlibAssemblyPaths`.
let private driverSource = """package Msil.MsilBridge
import Msil.Bridge

func main(): Unit { }
"""

/// Process-wide cache of the resolved delegate.  The driver compile is the
/// slow part (~3-5 s on a cold cache); we only do it once per `lyric`
/// invocation that touches the self-hosted MSIL emitter.
let private bridgeLock = obj ()
let mutable private resolved : (string -> string -> System.Collections.Generic.List<string> -> bool) option = None

/// Compile the driver source so the emitter produces and caches
/// `Lyric.Msil.Bridge.dll`.  Returns the absolute path to it.
let private ensureLyricMsilBridgeAssembly () : string =
    let scratch =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-msil-bridge-%d"
                         (System.Diagnostics.Process.GetCurrentProcess().Id))
    Directory.CreateDirectory scratch |> ignore
    AppDomain.CurrentDomain.ProcessExit.Add(fun _ ->
        try Directory.Delete(scratch, recursive = true) with _ -> ())
    let dllPath = Path.Combine(scratch, "Lyric.Msil.MsilBridge.dll")
    let req : Emitter.EmitRequest =
        { Source             = driverSource
          AssemblyName       = "Lyric.Msil.MsilBridge"
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
        failwithf "self-hosted MSIL bridge: emitter produced errors:\n%s" msg

    Lyric.Cli.SelfHostedBridge.preloadStdlibAssemblies ()

    // Emitter mints stdlib assemblies as `Lyric.<head>.<rest>.dll` for
    // builtin heads, so `Msil.Bridge` lands as `Lyric.Msil.Bridge.dll` in
    // the cache (head = "Msil", rest = ["Bridge"]).
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
        failwithf "self-hosted MSIL bridge: 'Lyric.Msil.Bridge.dll' not found in stdlib cache after emit (cached: %s)" cached

/// Reflect out the `compileToMsil` entry point and stash it in `resolved`.
/// Band 6: the bridge now accepts a 3rd parameter (stdlibSources) for
/// cross-package type resolution.
let private resolveDelegates () : string -> string -> System.Collections.Generic.List<string> -> bool =
    let dll = ensureLyricMsilBridgeAssembly ()
    let asm = Lyric.Cli.SelfHostedBridge.loadFromCache dll
    let progType =
        match Option.ofObj (asm.GetType "Msil.Bridge.Program") with
        | Some t -> t
        | None ->
            failwithf "self-hosted MSIL bridge: 'Msil.Bridge.Program' type missing from %s" dll

    let listOfStringType = typeof<System.Collections.Generic.List<string>>
    let compileToMsilM =
        match Option.ofObj (progType.GetMethod("compileToMsil", [| typeof<string>; typeof<string>; listOfStringType |])) with
        | Some m when m.IsStatic -> m
        | _ -> failwithf "self-hosted MSIL bridge: static method 'compileToMsil(string,string,List<string>)' not found on Msil.Bridge.Program"

    let compileToMsilFn
        (source: string)
        (outputPath: string)
        (stdlibSources: System.Collections.Generic.List<string>) : bool =
        match Option.ofObj (compileToMsilM.Invoke(null, [| box source; box outputPath; box stdlibSources |])) with
        | Some o -> unbox<bool> o
        | None   -> false

    compileToMsilFn

let private getDelegate () : string -> string -> System.Collections.Generic.List<string> -> bool =
    lock bridgeLock (fun () ->
        match resolved with
        | None ->
            let fn = resolveDelegates ()
            resolved <- Some fn
            fn
        | Some r -> r)

/// Write a minimal `.runtimeconfig.json` alongside `dllPath` so that
/// `dotnet exec dllPath` can locate the correct runtime.
let private writeRuntimeConfig (dllPath: string) : unit =
    let configPath =
        let changed = Path.ChangeExtension(dllPath, ".runtimeconfig.json")
        match Option.ofObj changed with
        | Some p -> p
        | None   -> dllPath + ".runtimeconfig.json"
    let v = System.Environment.Version
    let json =
        "{\n" +
        "  \"runtimeOptions\": {\n" +
        (sprintf "    \"tfm\": \"net%d.%d\",\n" v.Major v.Minor) +
        "    \"framework\": {\n" +
        "      \"name\": \"Microsoft.NETCore.App\",\n" +
        (sprintf "      \"version\": \"%s\"\n" (v.ToString())) +
        "    }\n" +
        "  }\n" +
        "}\n"
    File.WriteAllText(configPath, json)

/// Compile `source` to a .NET PE DLL at `outputPath` using the self-hosted
/// `Msil.Bridge` pipeline.  Returns true on success, false on parse errors
/// or write failure.  Band 6: stdlib sources are pre-read from disk and
/// passed to the bridge for cross-package type resolution.
let compileToDll (source: string) (outputPath: string) : bool =
    let fn = getDelegate ()
    let stdlibSources = Lyric.Cli.SelfHostedBridge.findStdlibSources ()
    let ok = fn source outputPath stdlibSources
    if ok then writeRuntimeConfig outputPath
    ok
