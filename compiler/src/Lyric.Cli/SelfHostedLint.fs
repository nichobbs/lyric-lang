/// Bridge from the F# `lyric lint` subcommand to the self-hosted
/// `Lyric.LintBridge` package (Phase 5 §M5.3 shim elimination).
///
/// Strategy: compile a tiny driver that `import Lyric.LintBridge`.
/// The emitter precompiles the bridge DLL into the per-process stdlib
/// cache as a side-effect.  We then reflect out the static
/// `lintToProtocol(string): string` entry point from
/// `Lyric.LintBridge.Program` and parse the line-oriented protocol
/// back into the F# `Lint.LintResult` type.
///
/// Protocol format (from lint_bridge.l):
///   One diagnostic per line: "<code>|<sev>|<line>|<col>|<message>"
///   Newlines inside <message> are escaped as the literal two-character
///   sequence \n by the Lyric bridge; this module unescapes them.
///   Empty string → no diagnostics.
module Lyric.Cli.SelfHostedLint

open System
open System.IO
open System.Reflection
open Lyric.Lexer
open Lyric.Emitter

let private driverSource = """package Lyric.LintBridgeDriver
import Lyric.LintBridge

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
                     sprintf "lyric-lint-bridge-%d"
                         (System.Diagnostics.Process.GetCurrentProcess().Id))
    Directory.CreateDirectory scratch |> ignore
    AppDomain.CurrentDomain.ProcessExit.Add(fun _ ->
        try Directory.Delete(scratch, recursive = true) with _ -> ())
    let dllPath = Path.Combine(scratch, "Lyric.LintBridgeDriver.dll")
    let req : Emitter.EmitRequest =
        { Source             = driverSource
          AssemblyName       = "Lyric.LintBridgeDriver"
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
        failwithf "self-hosted lint bridge: emitter errors:\n%s" msg

    preloadStdlibAssemblies ()

    match Emitter.stdlibAssemblyPaths ()
          |> List.tryFind (fun p -> Path.GetFileNameWithoutExtension p = "Lyric.Lyric.LintBridge") with
    | Some p -> p
    | None ->
        let cached =
            Emitter.stdlibAssemblyPaths ()
            |> List.map (fun p -> Option.ofObj (Path.GetFileName p) |> Option.defaultValue "<unknown>")
            |> String.concat ", "
        failwithf "self-hosted lint bridge: 'Lyric.Lyric.LintBridge.dll' not found (cached: %s)" cached

let private resolveDelegates () : string -> string =
    let dll = ensureBridgeAssembly ()
    let asm = Assembly.LoadFrom dll
    let progType =
        match Option.ofObj (asm.GetType "Lyric.LintBridge.Program") with
        | Some t -> t
        | None   -> failwithf "self-hosted lint bridge: 'Lyric.LintBridge.Program' missing from %s" dll
    let m =
        match Option.ofObj (progType.GetMethod("lintToProtocol", [| typeof<string> |])) with
        | Some m when m.IsStatic -> m
        | _ -> failwithf "self-hosted lint bridge: 'lintToProtocol' not found"
    fun (source: string) ->
        match Option.ofObj (m.Invoke(null, [| box source |])) with
        | Some o -> string o
        | None   -> ""

let private getDelegate () : string -> string =
    lock bridgeLock (fun () ->
        match resolved with
        | None   -> let fn = resolveDelegates () in resolved <- Some fn; fn
        | Some r -> r)

// ─── Protocol parsing ────────────────────────────────────────────────────────

let private makePos (line: int) (col: int) : Lyric.Lexer.Position =
    { Offset = 0; Line = line; Column = col }

let private makeSpan (line: int) (col: int) : Lyric.Lexer.Span =
    let p = makePos line col
    { Start = p; End = p }

let private parseLine (line: string) : Lint.LintDiagnostic option =
    let parts = line.Split([| '|' |], 5)
    if parts.Length < 5 then None
    else
        let code = parts.[0]
        let sev  =
            if parts.[1] = "warning" then Lint.LintWarning
            else Lint.LintError
        let ln  = try int parts.[2] with _ -> 0
        let col = try int parts.[3] with _ -> 0
        let msg = parts.[4].Replace("\\n", "\n")
        Some { Lint.Code = code; Lint.Severity = sev
               Lint.Message = msg; Lint.Span = makeSpan ln col }

// ─── Public API ──────────────────────────────────────────────────────────────

/// Run lint on `source` via the self-hosted bridge, returning a `LintResult`.
let lint (source: string) : Lint.LintResult =
    let fn       = getDelegate ()
    let protocol = fn source
    let lines    = protocol.Split([| '\n' |]) |> Array.filter (fun l -> l <> "")
    let diags    =
        lines
        |> Array.choose (fun l ->
            match parseLine l with
            | Some d -> Some d
            | None   ->
                if l <> "" then
                    eprintfn "lyric lint bridge: malformed protocol line: %s" l
                None)
        |> List.ofArray
    { Lint.Diagnostics = diags }
