/// Bridge from the F# pack/restore logic to the self-hosted
/// `Lyric.PackBridge` package (Phase 5 §M5.3 shim elimination).
///
/// Strategy: compile a tiny driver that `import Lyric.PackBridge`.
/// The emitter precompiles the bridge DLL into the per-process stdlib
/// cache as a side-effect.  We then reflect out:
///   `publishCsprojToProtocol(string, string): string`
///   `restoreCsprojToProtocol(string): string`
/// from `Lyric.PackBridge.Program` and parse the prefix protocol
/// ("ok\n<csproj>" or "parsefail\n<msg>") back into F# strings.
///
/// Process invocation (dotnet pack / dotnet restore) remains in Pack.fs;
/// only the csproj XML generation has been ported to Lyric.
module Lyric.Cli.SelfHostedPack

open System
open System.IO
open System.Reflection
open Lyric.Lexer
open Lyric.Emitter

let private driverSource = """package Lyric.PackBridgeDriver
import Lyric.PackBridge

func main(): Unit { }
"""

let private bridgeLock = obj ()
let mutable private resolved : ((string -> string -> string) * (string -> string)) option = None

let private preloadStdlibAssemblies () : unit =
    for p in Emitter.stdlibAssemblyPaths () do
        try Assembly.LoadFrom p |> ignore
        with _ -> ()

let private ensureBridgeAssembly () : string =
    let scratch =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-pack-bridge-%d"
                         (System.Diagnostics.Process.GetCurrentProcess().Id))
    Directory.CreateDirectory scratch |> ignore
    let dllPath = Path.Combine(scratch, "Lyric.PackBridgeDriver.dll")
    let req : Emitter.EmitRequest =
        { Source             = driverSource
          AssemblyName       = "Lyric.PackBridgeDriver"
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
        failwithf "self-hosted pack bridge: emitter errors:\n%s" msg

    preloadStdlibAssemblies ()

    match Emitter.stdlibAssemblyPaths ()
          |> List.tryFind (fun p -> Path.GetFileNameWithoutExtension p = "Lyric.Lyric.PackBridge") with
    | Some p -> p
    | None ->
        let cached =
            Emitter.stdlibAssemblyPaths ()
            |> List.map (fun p -> Option.ofObj (Path.GetFileName p) |> Option.defaultValue "<unknown>")
            |> String.concat ", "
        failwithf "self-hosted pack bridge: 'Lyric.Lyric.PackBridge.dll' not found (cached: %s)" cached

let private resolveDelegates () : (string -> string -> string) * (string -> string) =
    let dll = ensureBridgeAssembly ()
    let asm = Assembly.LoadFrom dll
    let progType =
        match Option.ofObj (asm.GetType "Lyric.PackBridge.Program") with
        | Some t -> t
        | None   -> failwithf "self-hosted pack bridge: 'Lyric.PackBridge.Program' missing from %s" dll

    let pickStatic (name: string) (sigTypes: Type[]) =
        match Option.ofObj (progType.GetMethod(name, sigTypes)) with
        | Some m when m.IsStatic -> m
        | _ -> failwithf "self-hosted pack bridge: static method '%s' not found on Lyric.PackBridge.Program" name

    let publishM = pickStatic "publishCsprojToProtocol" [| typeof<string>; typeof<string> |]
    let restoreM = pickStatic "restoreCsprojToProtocol" [| typeof<string> |]

    let publishFn (toml: string) (dllAbsPath: string) : string =
        match Option.ofObj (publishM.Invoke(null, [| box toml; box dllAbsPath |])) with
        | Some o -> string o
        | None   -> "parsefail\nunknown error"

    let restoreFn (toml: string) : string =
        match Option.ofObj (restoreM.Invoke(null, [| box toml |])) with
        | Some o -> string o
        | None   -> "parsefail\nunknown error"

    publishFn, restoreFn

let private getDelegates () : (string -> string -> string) * (string -> string) =
    lock bridgeLock (fun () ->
        match resolved with
        | None   -> let pair = resolveDelegates () in resolved <- Some pair; pair
        | Some r -> r)

// ─── Protocol helpers ────────────────────────────────────────────────────────

let private parseProtocol (protocol: string) : Result<string, string> =
    let idx = protocol.IndexOf('\n')
    if idx < 0 then Error protocol
    else
        let tag  = protocol.Substring(0, idx)
        let body = protocol.Substring(idx + 1)
        if tag = "ok" then Ok body
        else Error body

// ─── Public API ──────────────────────────────────────────────────────────────

/// Generate the `.csproj` XML for `lyric publish` via the self-hosted bridge.
/// `dllPath` will be resolved to an absolute path before being forwarded.
let publishCsproj (toml: string) (dllPath: string) : Result<string, string> =
    let publishFn, _ = getDelegates ()
    let dllAbsPath   = Path.GetFullPath dllPath
    let protocol     = publishFn toml dllAbsPath
    parseProtocol protocol

/// Generate the `.csproj` XML for `lyric restore` via the self-hosted bridge.
let restoreCsproj (toml: string) : Result<string, string> =
    let _, restoreFn = getDelegates ()
    let protocol     = restoreFn toml
    parseProtocol protocol
