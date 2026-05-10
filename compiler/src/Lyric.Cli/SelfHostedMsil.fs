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
let mutable private resolved : (string -> string -> bool) option = None

/// Pre-load every cached stdlib DLL into the default AppDomain so
/// `Lyric.Msil.Bridge.dll`'s typeRef chain resolves when the bridge assembly
/// itself loads.  Idempotent: `Assembly.LoadFrom` returns the same `Assembly`
/// instance on a duplicate path.
let private preloadStdlibAssemblies () : unit =
    for p in Emitter.stdlibAssemblyPaths () do
        try Assembly.LoadFrom p |> ignore
        with _ -> ()  // best-effort; missing/corrupt cache entries surface later

/// Compile the driver source so the emitter produces and caches
/// `Lyric.Msil.Bridge.dll`.  Returns the absolute path to it.
let private ensureLyricMsilBridgeAssembly () : string =
    let scratch =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-msil-bridge-%d"
                         (System.Diagnostics.Process.GetCurrentProcess().Id))
    Directory.CreateDirectory scratch |> ignore
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

    preloadStdlibAssemblies ()

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
let private resolveDelegates () : string -> string -> bool =
    let dll = ensureLyricMsilBridgeAssembly ()
    let asm = Assembly.LoadFrom dll
    let progType =
        match Option.ofObj (asm.GetType "Msil.Bridge.Program") with
        | Some t -> t
        | None ->
            failwithf "self-hosted MSIL bridge: 'Msil.Bridge.Program' type missing from %s" dll

    let compileToMsilM =
        match Option.ofObj (progType.GetMethod("compileToMsil", [| typeof<string>; typeof<string> |])) with
        | Some m when m.IsStatic -> m
        | _ -> failwithf "self-hosted MSIL bridge: static method 'compileToMsil' not found on Msil.Bridge.Program"

    let compileToMsilFn (source: string) (outputPath: string) : bool =
        match Option.ofObj (compileToMsilM.Invoke(null, [| box source; box outputPath |])) with
        | Some o -> unbox<bool> o
        | None   -> false

    compileToMsilFn

let private getDelegate () : string -> string -> bool =
    lock bridgeLock (fun () ->
        match resolved with
        | None ->
            let fn = resolveDelegates ()
            resolved <- Some fn
            fn
        | Some r -> r)

/// Compile `source` to a .NET PE DLL at `outputPath` using the self-hosted
/// `Msil.Bridge` pipeline.  Returns true on success, false on parse errors
/// or write failure.
let compileToDll (source: string) (outputPath: string) : bool =
    let fn = getDelegate ()
    fn source outputPath
