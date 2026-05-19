/// Bridge from the F# `lyric bench` subcommand to the self-hosted
/// `Lyric.BenchSynthBridge` package.
///
/// Strategy: compile a tiny driver that imports `Lyric.BenchSynthBridge`.
/// The emitter precompiles the bridge DLL into the per-process stdlib
/// cache as a side-effect.  We then reflect out the static entry point
/// `synthesizeBenchToProtocol(string, int64, int64): string` from
/// `Lyric.BenchSynthBridge.Program`, and parse the line-oriented text
/// protocol back into the F# `Outcome` type.
module Lyric.Cli.SelfHostedBench

open System
open System.IO
open System.Reflection
open Lyric.Lexer
open Lyric.Emitter

let private driverSource = """package Lyric.BenchSynthBridgeDriver
import Lyric.BenchSynthBridge

func main(): Unit { }
"""

let private bridgeLock = obj ()
let mutable private resolved : (string -> int -> int -> string -> string) option = None

let private ensureBridgeAssembly () : string =
    let scratch =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-bench-bridge-%d"
                         (System.Diagnostics.Process.GetCurrentProcess().Id))
    Directory.CreateDirectory scratch |> ignore
    AppDomain.CurrentDomain.ProcessExit.Add(fun _ ->
        try Directory.Delete(scratch, recursive = true) with _ -> ())
    let dllPath = Path.Combine(scratch, "Lyric.BenchSynthBridgeDriver.dll")
    let req : Emitter.EmitRequest =
        { Source             = driverSource
          AssemblyName       = "Lyric.BenchSynthBridgeDriver"
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
        failwithf "self-hosted bench bridge: emitter errors:\n%s" msg

    Lyric.Cli.SelfHostedBridge.preloadStdlibAssemblies ()

    match Emitter.stdlibAssemblyPaths ()
          |> List.tryFind (fun p -> Path.GetFileNameWithoutExtension p = "Lyric.Lyric.BenchSynthBridge") with
    | Some p -> p
    | None ->
        let cached =
            Emitter.stdlibAssemblyPaths ()
            |> List.map (fun p -> Option.ofObj (Path.GetFileName p) |> Option.defaultValue "<unknown>")
            |> String.concat ", "
        failwithf "self-hosted bench bridge: 'Lyric.Lyric.BenchSynthBridge.dll' not found (cached: %s)" cached

let private resolveDelegate () : string -> int -> int -> string -> string =
    let dll = ensureBridgeAssembly ()
    let asm = Lyric.Cli.SelfHostedBridge.loadFromCache dll
    let progType =
        match Option.ofObj (asm.GetType "Lyric.BenchSynthBridge.Program") with
        | Some t -> t
        | None   -> failwithf "self-hosted bench bridge: 'Lyric.BenchSynthBridge.Program' missing from %s" dll

    let synthM =
        match Option.ofObj (progType.GetMethod("synthesizeBenchToProtocol",
                                               [| typeof<string>; typeof<int>; typeof<int>; typeof<string> |])) with
        | Some m when m.IsStatic -> m
        | _ -> failwith "self-hosted bench bridge: static method 'synthesizeBenchToProtocol' not found"

    fun (source: string) (runs: int) (warmup: int) (filter: string) ->
        match Option.ofObj (synthM.Invoke(null, [| box source; box runs; box warmup; box filter |])) with
        | Some o -> string o
        | None   -> "parsefail\nB0000|error|0|0|bridge returned null"

let private getDelegate () : string -> int -> int -> string -> string =
    lock bridgeLock (fun () ->
        match resolved with
        | None   -> let fn = resolveDelegate () in resolved <- Some fn; fn
        | Some f -> f)

// ─── Protocol helpers ────────────────────────────────────────────────────────

let private makePos (line: int) (col: int) : Lyric.Lexer.Position =
    { Offset = 0; Line = line; Column = col }

let private makeSpan (line: int) (col: int) : Lyric.Lexer.Span =
    let p = makePos line col
    { Start = p; End = p }

let private parseDiag (line: string) : Lyric.Lexer.Diagnostic =
    let parts = line.Split([| '|' |], 5)
    let code = if parts.Length > 0 then parts.[0] else "?"
    let sev  =
        if parts.Length > 1 && parts.[1] = "warning" then DiagWarning
        else DiagError
    let ln   = if parts.Length > 2 then (try int parts.[2] with _ -> 0) else 0
    let col  = if parts.Length > 3 then (try int parts.[3] with _ -> 0) else 0
    let msg  = if parts.Length > 4 then parts.[4] else ""
    { Code = code; Severity = sev; Span = makeSpan ln col; Message = msg
      Help = None; Related = []; Fix = None }

// ─── Public outcome type ─────────────────────────────────────────────────────

type Outcome =
    | Synthesised of source: string * benchCount: int
    | NoBenchModule of span: Lyric.Lexer.Span
    | UserMainExists of span: Lyric.Lexer.Span
    | ParseFailures of diags: Lyric.Lexer.Diagnostic list

// ─── Public API ──────────────────────────────────────────────────────────────

let synthesize (source: string) (runs: int) (warmup: int) (filter: string) : Outcome =
    let fn = getDelegate ()
    let protocol = fn source runs warmup filter
    let lines = protocol.Split('\n')
    if lines.Length = 0 then
        ParseFailures []
    else
        match lines.[0] with
        | "nobench" ->
            let ln  = if lines.Length > 1 then (try int lines.[1] with _ -> 0) else 0
            let col = if lines.Length > 2 then (try int lines.[2] with _ -> 0) else 0
            NoBenchModule (makeSpan ln col)
        | "usermain" ->
            let ln  = if lines.Length > 1 then (try int lines.[1] with _ -> 0) else 0
            let col = if lines.Length > 2 then (try int lines.[2] with _ -> 0) else 0
            UserMainExists (makeSpan ln col)
        | "parsefail" ->
            let diags = lines.[1..] |> Array.filter (fun l -> l <> "") |> Array.map parseDiag |> List.ofArray
            ParseFailures diags
        | "ok" ->
            let benchCount = if lines.Length > 1 then (try int lines.[1] with _ -> 0) else 0
            let src =
                if lines.Length > 2 then
                    String.concat "\n" lines.[2..]
                else ""
            Synthesised (src, benchCount)
        | other ->
            ParseFailures
                [{ Code = "B0000"; Severity = DiagError
                   Span = makeSpan 0 0
                   Message = sprintf "self-hosted bench bridge: unexpected protocol tag '%s'" other
                   Help = None; Related = []; Fix = None }]
