/// Bridge from the F# `lyric test` subcommand to the self-hosted
/// `Lyric.TestSynthBridge` package (Phase 5 §M5.3 shim elimination).
///
/// Strategy: compile a tiny driver that `import Lyric.TestSynthBridge`.
/// The emitter precompiles the bridge DLL into the per-process stdlib
/// cache as a side-effect.  We then reflect out the static entry points
/// `synthesizeToProtocol(string, string, bool): string` and
/// `listEntriesToProtocol(string): string` from `Lyric.TestSynthBridge.Program`,
/// and parse the line-oriented text protocol back into the F# `Outcome`
/// and `ListEntry` types (see `test_synth_bridge.l` for the format).
module Lyric.Cli.SelfHostedTestSynth

open System
open System.IO
open System.Reflection
open Lyric.Lexer
open Lyric.Emitter

let private driverSource = """package Lyric.TestSynthBridgeDriver
import Lyric.TestSynthBridge

func main(): Unit { }
"""

let private bridgeLock = obj ()
let mutable private resolved : ((string -> string -> bool -> string) * (string -> string)) option = None

let private preloadStdlibAssemblies () : unit =
    for p in Emitter.stdlibAssemblyPaths () do
        try Assembly.LoadFrom p |> ignore
        with _ -> ()

let private ensureBridgeAssembly () : string =
    let scratch =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-testsynth-bridge-%d"
                         (System.Diagnostics.Process.GetCurrentProcess().Id))
    Directory.CreateDirectory scratch |> ignore
    AppDomain.CurrentDomain.ProcessExit.Add(fun _ ->
        try Directory.Delete(scratch, recursive = true) with _ -> ())
    let dllPath = Path.Combine(scratch, "Lyric.TestSynthBridgeDriver.dll")
    let req : Emitter.EmitRequest =
        { Source             = driverSource
          AssemblyName       = "Lyric.TestSynthBridgeDriver"
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
        failwithf "self-hosted test-synth bridge: emitter errors:\n%s" msg

    preloadStdlibAssemblies ()

    match Emitter.stdlibAssemblyPaths ()
          |> List.tryFind (fun p -> Path.GetFileNameWithoutExtension p = "Lyric.Lyric.TestSynthBridge") with
    | Some p -> p
    | None ->
        let cached =
            Emitter.stdlibAssemblyPaths ()
            |> List.map (fun p -> Option.ofObj (Path.GetFileName p) |> Option.defaultValue "<unknown>")
            |> String.concat ", "
        failwithf "self-hosted test-synth bridge: 'Lyric.Lyric.TestSynthBridge.dll' not found (cached: %s)" cached

let private resolveDelegates () : (string -> string -> bool -> string) * (string -> string) =
    let dll = ensureBridgeAssembly ()
    let asm = Assembly.LoadFrom dll
    let progType =
        match Option.ofObj (asm.GetType "Lyric.TestSynthBridge.Program") with
        | Some t -> t
        | None   -> failwithf "self-hosted test-synth bridge: 'Lyric.TestSynthBridge.Program' missing from %s" dll

    let pickStatic (name: string) (sigTypes: Type[]) =
        match Option.ofObj (progType.GetMethod(name, sigTypes)) with
        | Some m when m.IsStatic -> m
        | _ -> failwithf "self-hosted test-synth bridge: static method '%s' not found on Lyric.TestSynthBridge.Program" name

    let synthM   = pickStatic "synthesizeToProtocol"  [| typeof<string>; typeof<string>; typeof<bool> |]
    let listM    = pickStatic "listEntriesToProtocol"  [| typeof<string> |]

    let synthFn (source: string) (filter: string) (hasFilter: bool) : string =
        match Option.ofObj (synthM.Invoke(null, [| box source; box filter; box hasFilter |])) with
        | Some o -> string o
        | None   -> "parsefail\nunknown error"

    let listFn (source: string) : string =
        match Option.ofObj (listM.Invoke(null, [| box source |])) with
        | Some o -> string o
        | None   -> ""

    synthFn, listFn

let private getDelegates () : (string -> string -> bool -> string) * (string -> string) =
    lock bridgeLock (fun () ->
        match resolved with
        | None   -> let pair = resolveDelegates () in resolved <- Some pair; pair
        | Some r -> r)

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
    { Code = code; Severity = sev; Span = makeSpan ln col; Message = msg }

// ─── Public API ──────────────────────────────────────────────────────────────

let synthesize (source: string) (filter: string option) : TestSynth.Outcome =
    let synthFn, _ = getDelegates ()
    let (filterStr, hasFilter) =
        match filter with
        | Some f -> f, true
        | None   -> "", false
    let protocol = synthFn source filterStr hasFilter
    let lines = protocol.Split('\n')
    if lines.Length = 0 then
        TestSynth.ParseFailures []
    else
        match lines.[0] with
        | "notest" ->
            let ln  = if lines.Length > 1 then (try int lines.[1] with _ -> 0) else 0
            let col = if lines.Length > 2 then (try int lines.[2] with _ -> 0) else 0
            TestSynth.NoTestModule (makeSpan ln col)
        | "usermain" ->
            let ln  = if lines.Length > 1 then (try int lines.[1] with _ -> 0) else 0
            let col = if lines.Length > 2 then (try int lines.[2] with _ -> 0) else 0
            TestSynth.UserMainExists (makeSpan ln col)
        | "fixture" ->
            let ln  = if lines.Length > 1 then (try int lines.[1] with _ -> 0) else 0
            let col = if lines.Length > 2 then (try int lines.[2] with _ -> 0) else 0
            TestSynth.FixtureUnsupported (makeSpan ln col)
        | "parsefail" ->
            let diags = lines.[1..] |> Array.filter (fun l -> l <> "") |> Array.map parseDiag |> List.ofArray
            TestSynth.ParseFailures diags
        | "ok" ->
            let testCount = if lines.Length > 1 then (try int lines.[1] with _ -> 0) else 0
            let skipCount = if lines.Length > 2 then (try int lines.[2] with _ -> 0) else 0
            let src =
                if lines.Length > 3 then
                    String.concat "\n" lines.[3..]
                else ""
            TestSynth.Synthesised(src, testCount, skipCount)
        | other ->
            TestSynth.ParseFailures
                [{ Code = "T0000"; Severity = DiagError
                   Span = makeSpan 0 0
                   Message = sprintf "self-hosted test-synth bridge: unexpected protocol tag '%s'" other }]

let listEntries (source: string) : Result<TestSynth.ListEntry list, Lyric.Lexer.Diagnostic list> =
    let _, listFn = getDelegates ()
    let protocol = listFn source
    let lines = protocol.Split('\n') |> Array.filter (fun l -> l <> "")
    if lines.Length > 0 && lines.[0] = "parsefail" then
        let diags = lines.[1..] |> Array.map parseDiag |> List.ofArray
        Error diags
    else
        let entries =
            lines
            |> Array.choose (fun line ->
                let parts = line.Split([| '|' |], 3)
                match parts.[0] with
                | "test"    -> Some (TestSynth.TestEntry parts.[1])
                | "prop"    ->
                    let reason = if parts.Length > 2 then parts.[2] else ""
                    Some (TestSynth.PropertyEntry(parts.[1], reason))
                | "fixture" -> Some (TestSynth.FixtureEntry parts.[1])
                | _         -> None)
            |> List.ofArray
        Ok entries
