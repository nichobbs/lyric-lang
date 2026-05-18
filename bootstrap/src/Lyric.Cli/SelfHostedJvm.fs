/// Bridge from the F# `lyric` CLI to the self-hosted JVM compilation pipeline
/// (`Jvm.Bridge` — Phase R4).  Chains the self-hosted lexer → parser → codegen
/// → lowering → JAR writer in a single in-process call via reflection, avoiding
/// any subprocess round-trip.
///
/// Strategy: compile a tiny "driver" Lyric program whose only job is to
/// `import Jvm.Bridge`.  The emitter precompiles `Jvm.Bridge.dll` into its
/// per-process stdlib cache as a side-effect.  We then `Assembly.LoadFrom`
/// every cached DLL into the AppDomain (so the transitive dependency chain
/// resolves), reflect out the static `compileToJar(string, string, string)`
/// entry point on `Jvm.Bridge.Program`, and cache the resulting delegate for
/// subsequent calls in the same process.
module Lyric.Cli.SelfHostedJvm

open System
open System.IO
open System.Reflection
open Lyric.Lexer
open Lyric.Emitter

/// Source of the throwaway driver program.  The empty `main` is the minimum
/// the emitter accepts; the `import Jvm.Bridge` triggers the stdlib precompile
/// path that drops `Lyric.Jvm.Bridge.dll` into the cache returned by
/// `Emitter.stdlibAssemblyPaths`.
let private driverSource = """package Jvm.JvmBridge
import Jvm.Bridge

func main(): Unit { }
"""

/// Process-wide cache of the resolved delegate.  The driver compile is the
/// slow part (~3-5 s on a cold cache); we only do it once per `lyric`
/// invocation that touches the JVM emitter.
let private bridgeLock = obj ()
let mutable private resolved : (string -> string -> string -> bool) option = None

/// Pre-load every cached stdlib DLL into the default AppDomain so
/// `Lyric.Jvm.Bridge.dll`'s typeRef chain resolves when the bridge assembly
/// itself loads.  Idempotent: `Assembly.LoadFrom` returns the same `Assembly`
/// instance on a duplicate path.
let private preloadStdlibAssemblies () : unit =
    for p in Emitter.stdlibAssemblyPaths () do
        try Assembly.LoadFrom p |> ignore
        with _ -> ()  // best-effort; missing/corrupt cache entries
                      // surface later when the consumer reflects

/// Compile the driver source so the emitter produces and caches
/// `Lyric.Jvm.Bridge.dll`.  Returns the absolute path to it.
let private ensureLyricJvmBridgeAssembly () : string =
    let scratch =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-jvm-bridge-%d"
                         (System.Diagnostics.Process.GetCurrentProcess().Id))
    Directory.CreateDirectory scratch |> ignore
    AppDomain.CurrentDomain.ProcessExit.Add(fun _ ->
        try Directory.Delete(scratch, recursive = true) with _ -> ())
    let dllPath = Path.Combine(scratch, "Lyric.Jvm.JvmBridge.dll")
    let req : Emitter.EmitRequest =
        { Source             = driverSource
          AssemblyName       = "Lyric.Jvm.JvmBridge"
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
        failwithf "self-hosted JVM bridge: emitter produced errors:\n%s" msg

    preloadStdlibAssemblies ()

    // Emitter mints stdlib assemblies as `Lyric.<head>.<rest>.dll` for
    // builtin heads, so `Jvm.Bridge` lands as `Lyric.Jvm.Bridge.dll` in
    // the cache (head = "Jvm", rest = ["Bridge"]).
    let lyricJvmBridgeDll =
        Emitter.stdlibAssemblyPaths ()
        |> List.tryFind (fun p ->
            let n = Path.GetFileNameWithoutExtension p
            n = "Lyric.Jvm.Bridge")
    match lyricJvmBridgeDll with
    | Some p -> p
    | None ->
        let cached =
            Emitter.stdlibAssemblyPaths ()
            |> List.map (fun p ->
                match Option.ofObj (Path.GetFileName p) with
                | Some n -> n
                | None -> "<unknown>")
            |> String.concat ", "
        failwithf "self-hosted JVM bridge: 'Lyric.Jvm.Bridge.dll' not found in stdlib cache after emit (cached: %s)" cached

/// Reflect out the `compileToJar` entry point and stash it in `resolved`.
let private resolveDelegates () : string -> string -> string -> bool =
    let dll = ensureLyricJvmBridgeAssembly ()
    let asm = Assembly.LoadFrom dll
    let progType =
        match Option.ofObj (asm.GetType "Jvm.Bridge.Program") with
        | Some t -> t
        | None ->
            failwithf "self-hosted JVM bridge: 'Jvm.Bridge.Program' type missing from %s" dll

    let compileToJarM =
        match Option.ofObj (progType.GetMethod("compileToJar", [| typeof<string>; typeof<string>; typeof<string> |])) with
        | Some m when m.IsStatic -> m
        | _ -> failwithf "self-hosted JVM bridge: static method 'compileToJar' not found on Jvm.Bridge.Program"

    let compileToJarFn (source: string) (outputPath: string) (packageName: string) : bool =
        match Option.ofObj (compileToJarM.Invoke(null, [| box source; box outputPath; box packageName |])) with
        | Some o -> unbox<bool> o
        | None   -> false

    compileToJarFn

let private getDelegate () : string -> string -> string -> bool =
    lock bridgeLock (fun () ->
        match resolved with
        | None ->
            let fn = resolveDelegates ()
            resolved <- Some fn
            fn
        | Some r -> r)

/// Compile `source` to a JAR at `outputPath` using the self-hosted
/// `Jvm.Bridge` pipeline.  Returns true on success, false on parse errors
/// or write failure.
let compileToJar (source: string) (outputPath: string) (packageName: string) : bool =
    let fn = getDelegate ()
    fn source outputPath packageName
