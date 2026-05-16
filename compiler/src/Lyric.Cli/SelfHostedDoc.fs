/// Bridge from the F# `lyric doc` subcommand to the self-hosted
/// `Lyric.DocBridge` package (Phase 5 §M5.3 shim elimination).
///
/// Strategy: compile a tiny driver that `import Lyric.DocBridge`.
/// The emitter precompiles the bridge DLL into the per-process stdlib
/// cache as a side-effect.  We then reflect out the static
/// `generateToProtocol(string): string` entry point from
/// `Lyric.DocBridge.Program`, which returns "ok\n<markdown>" and
/// parse the result back into a plain markdown string.
module Lyric.Cli.SelfHostedDoc

open System
open System.IO
open System.Reflection
open Lyric.Lexer
open Lyric.Emitter

let private driverSource = """package Lyric.DocBridgeDriver
import Lyric.DocBridge

func main(): Unit { }
"""

let private bridgeLock = obj ()
let mutable private resolved : (string -> string) option = None

let private preloadStdlibAssemblies () : unit =
    for p in Emitter.stdlibAssemblyPaths () do
        try Assembly.LoadFrom p |> ignore
        with _ -> ()

let private ensureBridgeAssembly () : string =
    let scratch =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-doc-bridge-%d"
                         (System.Diagnostics.Process.GetCurrentProcess().Id))
    Directory.CreateDirectory scratch |> ignore
    let dllPath = Path.Combine(scratch, "Lyric.DocBridgeDriver.dll")
    let req : Emitter.EmitRequest =
        { Source             = driverSource
          AssemblyName       = "Lyric.DocBridgeDriver"
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
            |> List.map (fun d -> sprintf "  %s @ %d:%d  %s"
                                       d.Code d.Span.Start.Line d.Span.Start.Column d.Message)
            |> String.concat "\n"
        failwithf "self-hosted doc bridge: emitter errors:\n%s" msg

    preloadStdlibAssemblies ()

    match Emitter.stdlibAssemblyPaths ()
          |> List.tryFind (fun p -> Path.GetFileNameWithoutExtension p = "Lyric.Lyric.DocBridge") with
    | Some p -> p
    | None ->
        let cached =
            Emitter.stdlibAssemblyPaths ()
            |> List.map (fun p -> Option.ofObj (Path.GetFileName p) |> Option.defaultValue "<unknown>")
            |> String.concat ", "
        failwithf "self-hosted doc bridge: 'Lyric.Lyric.DocBridge.dll' not found (cached: %s)" cached

let private resolveDelegates () : string -> string =
    let dll = ensureBridgeAssembly ()
    let asm = Assembly.LoadFrom dll
    let progType =
        match Option.ofObj (asm.GetType "Lyric.DocBridge.Program") with
        | Some t -> t
        | None   -> failwithf "self-hosted doc bridge: 'Lyric.DocBridge.Program' missing from %s" dll
    let m =
        match Option.ofObj (progType.GetMethod("generateToProtocol", [| typeof<string> |])) with
        | Some m when m.IsStatic -> m
        | _ -> failwithf "self-hosted doc bridge: 'generateToProtocol' not found"
    fun (source: string) ->
        match Option.ofObj (m.Invoke(null, [| box source |])) with
        | Some o -> string o
        | None   -> "ok\n"

let private getDelegate () : string -> string =
    lock bridgeLock (fun () ->
        match resolved with
        | None   -> let fn = resolveDelegates () in resolved <- Some fn; fn
        | Some r -> r)

// ─── Public API ──────────────────────────────────────────────────────────────

/// Generate Markdown documentation for `source` via the self-hosted bridge.
/// Returns the raw Markdown string.
let generate (source: string) : string =
    let fn       = getDelegate ()
    let protocol = fn source
    // Protocol: "ok\n<markdown>" or "error\n<message>"
    let idx = protocol.IndexOf('\n')
    if idx < 0 then failwithf "self-hosted doc bridge: malformed protocol response"
    else
        let tag  = protocol.Substring(0, idx)
        let body = protocol.Substring(idx + 1)
        if tag <> "ok" then
            failwithf "self-hosted doc bridge error: %s" body
        body
