/// Bridge from the F# `lyric` CLI entry point to the self-hosted
/// `Lyric.Cli` dispatcher (Phase 5 §M5.3, cli.l).
///
/// Strategy: compile a tiny "driver" program that imports `Lyric.Cli`
/// so the emitter precompiles `Lyric.Cli.dll` (and its transitive
/// dependencies — Lyric.Emitter, Lyric.ContractMeta, Lyric.Repl, …)
/// into the per-process stdlib cache.  Then `Assembly.LoadFrom` every
/// cached DLL, reflect out the static `main(string[])` entry point on
/// `Lyric.Cli.Program`, and cache the resulting delegate.
///
/// tryRun returns Some(exitCode) when the self-hosted CLI handles the
/// command, and None when the bridge fails to compile or load (which
/// causes Program.fs to fall back to the F# bootstrap dispatcher).
module Lyric.Cli.SelfHostedCli

open System
open System.IO
open System.Reflection
open Lyric.Lexer
open Lyric.Emitter

let private driverSource = """package Lyric.CliBridge
import Lyric.Cli

func main(): Unit { }
"""

let private bridgeLock  = obj ()
let mutable private resolved : (string[] -> int) option = None

let private preloadStdlibAssemblies () : unit =
    for p in Emitter.stdlibAssemblyPaths () do
        try Assembly.LoadFrom p |> ignore
        with _ -> ()   // best-effort; missing entries surface later

let private ensureCliAssembly () : string =
    let scratch =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-cli-bridge-%d"
                         (Diagnostics.Process.GetCurrentProcess().Id))
    Directory.CreateDirectory scratch |> ignore
    // Register a best-effort cleanup so the per-process scratch directory
    // does not accumulate across CI runs.
    AppDomain.CurrentDomain.ProcessExit.Add(fun _ ->
        try Directory.Delete(scratch, recursive = true) with _ -> ())
    let dllPath = Path.Combine(scratch, "Lyric.CliBridge.dll")
    let req : Emitter.EmitRequest =
        { Source             = driverSource
          AssemblyName       = "Lyric.CliBridge"
          OutputPath         = dllPath
          RestoredPackages   = []
          NugetAssemblyPaths = []
          ExternShimRoot     = None
          Target             = Emitter.Dotnet
          ActiveFeatures     = Set.empty
          DeclaredFeatures   = Set.empty }
    let result = Emitter.emit req
    let errs = result.Diagnostics |> List.filter (fun d -> d.Severity = DiagError)
    if not (List.isEmpty errs) then
        let msg =
            errs
            |> List.map (fun d ->
                sprintf "  %s @ %d:%d  %s"
                    d.Code d.Span.Start.Line d.Span.Start.Column d.Message)
            |> String.concat "\n"
        failwithf "self-hosted CLI bridge: emitter errors:\n%s" msg

    preloadStdlibAssemblies ()

    // The emitter mints builtin-head assemblies as `Lyric.<head>.<rest>.dll`,
    // so `Lyric.Cli` lands as `Lyric.Lyric.Cli.dll` in the stdlib cache.
    match Emitter.stdlibAssemblyPaths ()
          |> List.tryFind (fun p ->
              Path.GetFileNameWithoutExtension p = "Lyric.Lyric.Cli") with
    | Some p -> p
    | None ->
        let cached =
            Emitter.stdlibAssemblyPaths ()
            |> List.map (fun p ->
                Option.ofObj (Path.GetFileName p) |> Option.defaultValue "<unknown>")
            |> String.concat ", "
        failwithf
            "self-hosted CLI bridge: 'Lyric.Lyric.Cli.dll' not found in cache \
             (cached: %s)" cached

let private resolveFn () : string[] -> int =
    let dll  = ensureCliAssembly ()
    let asm  = Assembly.LoadFrom dll
    let prog =
        match Option.ofObj (asm.GetType "Lyric.Cli.Program") with
        | Some t -> t
        | None   ->
            failwithf
                "self-hosted CLI bridge: 'Lyric.Cli.Program' type missing from %s" dll
    let m =
        match Option.ofObj (prog.GetMethod("main", [| typeof<string[]> |])) with
        | Some m when m.IsStatic -> m
        | _ ->
            failwith
                "self-hosted CLI bridge: static 'main(string[])' not found on \
                 Lyric.Cli.Program"
    fun (argv: string[]) ->
        match Option.ofObj (m.Invoke(null, [| box argv |])) with
        | Some o -> unbox<int> o
        | None   -> 0

let private getDelegate () : string[] -> int =
    lock bridgeLock (fun () ->
        match resolved with
        | Some f -> f
        | None   ->
            let f = resolveFn ()
            resolved <- Some f
            f)

/// Attempt to dispatch `argv` through the self-hosted `Lyric.Cli`.
/// Returns `Some exitCode` on success.
/// Returns `None` when the bridge cannot be compiled, loaded, or when the
/// self-hosted code itself fails to JIT-compile (invalid MSIL emitted by the
/// self-hosted pipeline).  In all these cases the caller falls back to the
/// F# bootstrap dispatcher.
///
/// Genuine runtime exceptions from the self-hosted CLI (application logic
/// crashes, out-of-memory, etc.) are NOT caught here — they propagate so the
/// user sees a real stack trace rather than a silent fallback.
let tryRun (argv: string[]) : int option =
    try
        let fn = getDelegate ()
        Some (fn argv)
    with
    | :? FileNotFoundException as ex ->
        eprintfn "self-hosted CLI unavailable (%s); falling back to bootstrap"
            ex.Message
        None
    | :? ReflectionTypeLoadException as ex ->
        eprintfn "self-hosted CLI unavailable (%s); falling back to bootstrap"
            ex.Message
        None
    | :? MissingMethodException as ex ->
        eprintfn "self-hosted CLI unavailable (%s); falling back to bootstrap"
            ex.Message
        None
    | :? BadImageFormatException as ex ->
        eprintfn "self-hosted CLI unavailable (%s); falling back to bootstrap"
            ex.Message
        None
    // InvalidProgramException means the CLR's JIT rejected the emitted MSIL —
    // a compiler/emit bug in the self-hosted pipeline, not an application error.
    // Treat it as a bridge infrastructure failure and fall back to bootstrap.
    // When invoked via reflection, the JIT failure is wrapped in a
    // TargetInvocationException; match both forms.
    | :? System.InvalidProgramException as ex ->
        eprintfn "self-hosted CLI unavailable (invalid emitted code: %s); falling back to bootstrap"
            ex.Message
        None
    | :? System.Reflection.TargetInvocationException as ex
        when (ex.InnerException :? System.InvalidProgramException) ->
        eprintfn "self-hosted CLI unavailable (invalid emitted code: %s); falling back to bootstrap"
            ex.Message
        None
