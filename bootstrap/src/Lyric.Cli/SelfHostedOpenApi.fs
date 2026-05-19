/// Bridge from the F# `lyric openapi` subcommand to the self-hosted
/// `Lyric.OpenApiBridge` package.
///
/// Strategy: compile a tiny driver that `import Lyric.OpenApiBridge`.
/// The emitter precompiles the bridge DLL into the per-process stdlib cache
/// as a side-effect.  We then reflect out the static entry point
/// `generateFromJson(string, string, string): string` from
/// `Lyric.OpenApiBridge.Program` and parse the two-line text protocol:
///   First line "ok"  → remaining lines are the generated .l source.
///   First line "err" → second line is the error message.
module Lyric.Cli.SelfHostedOpenApi

open System
open System.IO
open System.Reflection
open Lyric.Lexer
open Lyric.Emitter

let private driverSource = """package Lyric.OpenApiBridgeDriver
import Lyric.OpenApiBridge

func main(): Unit { }
"""

let private bridgeLock = obj ()
let mutable private resolved : (string -> string -> string -> string) option = None

let private ensureBridgeAssembly () : string =
    let scratch =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-openapi-bridge-%d"
                         (System.Diagnostics.Process.GetCurrentProcess().Id))
    Directory.CreateDirectory scratch |> ignore
    AppDomain.CurrentDomain.ProcessExit.Add(fun _ ->
        try Directory.Delete(scratch, recursive = true) with _ -> ())
    let dllPath = Path.Combine(scratch, "Lyric.OpenApiBridgeDriver.dll")
    let req : Emitter.EmitRequest =
        { Source             = driverSource
          AssemblyName       = "Lyric.OpenApiBridgeDriver"
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
        failwithf "self-hosted openapi bridge: emitter errors:\n%s" msg

    Lyric.Cli.SelfHostedBridge.preloadStdlibAssemblies ()

    match Emitter.stdlibAssemblyPaths ()
          |> List.tryFind (fun p -> Path.GetFileNameWithoutExtension p = "Lyric.Lyric.OpenApiBridge") with
    | Some p -> p
    | None ->
        let cached =
            Emitter.stdlibAssemblyPaths ()
            |> List.map (fun p -> Option.ofObj (Path.GetFileName p) |> Option.defaultValue "<unknown>")
            |> String.concat ", "
        failwithf "self-hosted openapi bridge: 'Lyric.Lyric.OpenApiBridge.dll' not found (cached: %s)" cached

let private resolveDelegate () : string -> string -> string -> string =
    let dll = ensureBridgeAssembly ()
    let asm = Lyric.Cli.SelfHostedBridge.loadFromCache dll
    let progType =
        match Option.ofObj (asm.GetType "Lyric.OpenApiBridge.Program") with
        | Some t -> t
        | None   -> failwithf "self-hosted openapi bridge: 'Lyric.OpenApiBridge.Program' missing from %s" dll
    let m =
        match Option.ofObj (progType.GetMethod("generateFromJson", [| typeof<string>; typeof<string>; typeof<string> |])) with
        | Some m when m.IsStatic -> m
        | _ -> failwithf "self-hosted openapi bridge: 'generateFromJson' not found"
    fun (json: string) (clientName: string) (packageName: string) ->
        match Option.ofObj (m.Invoke(null, [| box json; box clientName; box packageName |])) with
        | Some o -> string o
        | None   -> "err\nunknown error"

let private getDelegate () : string -> string -> string -> string =
    lock bridgeLock (fun () ->
        match resolved with
        | None   -> let fn = resolveDelegate () in resolved <- Some fn; fn
        | Some r -> r)

// ─── Public API ──────────────────────────────────────────────────────────────

/// Generate Lyric source from an OpenAPI 3.x JSON string.
/// Returns `Ok source` on success, `Error message` on failure.
let generateFromJson
        (json: string)
        (clientName: string)
        (packageName: string) : Result<string, string> =
    try
        let fn       = getDelegate ()
        let protocol = fn json clientName packageName
        let nl       = protocol.IndexOf '\n'
        if nl < 0 then Error (sprintf "unexpected bridge response: %s" protocol)
        else
            let tag    = protocol.Substring(0, nl)
            let body   = protocol.Substring(nl + 1)
            match tag with
            | "ok"  -> Ok body
            | "err" -> Error body
            | other -> Error (sprintf "unexpected bridge tag '%s'" other)
    with ex ->
        Error (sprintf "openapi bridge error: %s" ex.Message)

/// Generate Lyric source from an OpenAPI spec JSON file and write to `outPath`.
/// Returns `Ok outPath` on success, `Error message` on failure.
let generateToFile
        (specPath: string)
        (clientName: string)
        (packageName: string)
        (outPath: string) : Result<string, string> =
    try
        let json = File.ReadAllText specPath
        match generateFromJson json clientName packageName with
        | Error msg -> Error msg
        | Ok source ->
            let dir =
                match Path.GetDirectoryName(Path.GetFullPath outPath) with
                | null -> "."
                | d    -> d
            Directory.CreateDirectory dir |> ignore
            File.WriteAllText(outPath, source)
            Ok outPath
    with ex ->
        Error (sprintf "could not process '%s': %s" specPath ex.Message)
