/// Bridge from the F# `lyric prove` subcommand to the self-hosted
/// `Lyric.VerifierBridge` package.
///
/// The self-hosted verifier (`Lyric.Verifier`) handles the full proof path:
/// parse → mode-check → stability-check → VC-gen → discharge, including
/// cross-package imports, SMT-file writing, and VC IR pretty-printing for
/// `--explain`.  The F# `Lyric.Verifier` project has been deleted; this bridge
/// is the sole entry point for `lyric prove`.
///
/// Protocol (see `verifier_bridge.l`):
///   ok
///   level=<display-string>
///   diag|<code>|<error|warning>|<line>|<col>|<message-escaped>
///   result|discharged|<label>|<line>|<col>
///   result|counterexample|<label>|<line>|<col>|<model-escaped>
///   result|unknown|<label>|<line>|<col>|<reason-escaped>
module Lyric.Cli.SelfHostedVerifier

open System
open System.IO
open System.Reflection
open Lyric.Lexer
open Lyric.Emitter

let private driverSource = """package Lyric.VerifierBridgeDriver
import Lyric.VerifierBridge

func main(): Unit { }
"""

let private bridgeLock = obj ()
let mutable private resolved : (string -> bool -> string) option = None

let private preloadStdlibAssemblies () =
    for p in Emitter.stdlibAssemblyPaths () do
        try Assembly.LoadFrom p |> ignore
        with _ -> ()

// Emitting the tiny driver package is the cheapest way to warm the emitter's
// stdlib-assembly cache: the emit call resolves all transitive Lyric.* imports
// (including Lyric.VerifierBridge) and stores the resulting DLL paths in
// Emitter.stdlibAssemblyPaths().  The produced driver DLL itself is discarded;
// we use stdlibAssemblyPaths() afterward to locate Lyric.Lyric.VerifierBridge.
let private ensureBridgeAssembly () : string =
    let scratch =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-verifier-bridge-%d"
                         (Diagnostics.Process.GetCurrentProcess().Id))
    Directory.CreateDirectory scratch |> ignore
    let dllPath = Path.Combine(scratch, "Lyric.VerifierBridgeDriver.dll")
    let req : Emitter.EmitRequest =
        { Source             = driverSource
          AssemblyName       = "Lyric.VerifierBridgeDriver"
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
        failwithf "self-hosted verifier bridge: emitter errors:\n%s" msg

    preloadStdlibAssemblies ()

    match Emitter.stdlibAssemblyPaths ()
          |> List.tryFind (fun p ->
              Path.GetFileNameWithoutExtension p = "Lyric.Lyric.VerifierBridge") with
    | Some p -> p
    | None ->
        let cached =
            Emitter.stdlibAssemblyPaths ()
            |> List.map (fun p ->
                Option.ofObj (Path.GetFileName p) |> Option.defaultValue "<unknown>")
            |> String.concat ", "
        failwithf
            "self-hosted verifier bridge: 'Lyric.Lyric.VerifierBridge.dll' not found \
             (cached: %s)" cached

let private resolveFn () : string -> bool -> string =
    let dll  = ensureBridgeAssembly ()
    let asm  = Assembly.LoadFrom dll
    let prog =
        match Option.ofObj (asm.GetType "Lyric.VerifierBridge.Program") with
        | Some t -> t
        | None   ->
            failwithf
                "self-hosted verifier bridge: 'Lyric.VerifierBridge.Program' missing from %s"
                dll
    let m =
        match Option.ofObj (prog.GetMethod("proveToProtocol",
                                           [| typeof<string>; typeof<bool> |])) with
        | Some m when m.IsStatic -> m
        | _ ->
            failwith
                "self-hosted verifier bridge: 'proveToProtocol' not found on \
                 Lyric.VerifierBridge.Program"
    fun (source: string) (allowUnverified: bool) ->
        match Option.ofObj (m.Invoke(null, [| box source; box allowUnverified |])) with
        | Some o -> string o
        | None   -> "err\nunknown error from self-hosted verifier"

let private getDelegate () : string -> bool -> string =
    lock bridgeLock (fun () ->
        match resolved with
        | Some f -> f
        | None   ->
            let f = resolveFn ()
            resolved <- Some f
            f)

// ─────────────────────────────────────────────────────────────────────────────
// Protocol parser
// ─────────────────────────────────────────────────────────────────────────────

/// Undo the escaping applied by `verifier_bridge.l:escapeNl`.
let private unescape (s: string) =
    s.Replace("\\n", "\n").Replace("\\|", "|")

/// A parsed summary from the bridge protocol.
type VerifierResult = {
    Level        : string
    Diagnostics  : Diagnostic list
    Discharged   : int
    Total        : int
    Unknowns     : int
    HasFailure   : bool
    HasCex       : bool
    HasErrDiag   : bool
}

let private makePos line col : Position = { Offset = 0; Line = line; Column = col }
let private makeSpan line col : Span =
    let p = makePos line col in { Start = p; End = p }

let private parseDiag (parts: string[]) : Diagnostic =
    let code = if parts.Length > 1 then parts.[1] else "?"
    let sev  = if parts.Length > 2 && parts.[2] = "warning" then DiagWarning else DiagError
    let ln   = if parts.Length > 3 then (try int parts.[3] with _ -> 0) else 0
    let col  = if parts.Length > 4 then (try int parts.[4] with _ -> 0) else 0
    let msg  = if parts.Length > 5 then unescape parts.[5] else ""
    { Code = code; Severity = sev; Span = makeSpan ln col; Message = msg
      Help = None; Related = []; Fix = None }

let private parseProtocol (protocol: string) : Result<VerifierResult, string> =
    let lines = protocol.Split('\n')
    if lines.Length = 0 || lines.[0] <> "ok" then
        let msg = if lines.Length > 1 then lines.[1] else protocol
        Error msg
    else
        let mutable level       = "runtime_checked"
        let mutable diags       : Diagnostic list = []
        let mutable discharged  = 0
        let mutable total       = 0
        let mutable unknowns    = 0
        let mutable hasCex      = false
        let mutable hasFailure  = false
        // StringComparison.Ordinal: the protocol is ASCII; the default
        // CurrentCulture comparison would fold characters on non-en-US
        // locales (Turkish i/I, Azerbaijani) and silently misparse the
        // header. See #345.
        let inline starts (s: string) (prefix: string) =
            s.StartsWith(prefix, StringComparison.Ordinal)
        for line in lines.[1..] do
            if starts line "level=" then
                level <- line.Substring 6
            elif starts line "diag|" then
                let parts = line.Split([| '|' |], 6)
                diags <- parseDiag parts :: diags
            elif starts line "result|" then
                let parts = line.Split([| '|' |], 6)
                total <- total + 1
                if parts.Length > 1 then
                    match parts.[1] with
                    | "discharged"     -> discharged <- discharged + 1
                    | "counterexample" -> hasCex <- true; hasFailure <- true
                    | "unknown"        -> unknowns <- unknowns + 1; hasFailure <- true
                    | _ -> ()
        let hasErrDiag = diags |> List.exists (fun d -> d.Severity = DiagError)
        Ok { Level        = level
             Diagnostics  = List.rev diags
             Discharged   = discharged
             Total        = total
             Unknowns     = unknowns
             HasFailure   = hasFailure
             HasCex       = hasCex
             HasErrDiag   = hasErrDiag }

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

/// Run the self-hosted verifier on `source` and return a `VerifierResult`.
/// Raises on emitter / bridge failure; inner parse/verify failures are
/// represented as `Error`.
let prove (source: string) (allowUnverified: bool) : Result<VerifierResult, string> =
    let fn       = getDelegate ()
    let protocol = fn source allowUnverified
    parseProtocol protocol
