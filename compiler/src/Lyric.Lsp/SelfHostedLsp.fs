/// Bridge from the F# LSP entry point and test suite to the self-hosted
/// `Lyric.Lsp` package.
///
/// Strategy: compile a tiny driver that `import Lyric.Lsp`.  The emitter
/// precompiles `Lyric.Lsp.dll` into the per-process stdlib cache as a
/// side-effect.  We then `Assembly.LoadFrom` every cached DLL into the
/// AppDomain (so transitive references resolve), reflect out the static
/// entry points on `Lyric.Lsp.Program`, and cache the resulting delegates
/// for subsequent calls in the same process.
///
/// Public API
/// ──────────
/// `runLoop()` — called by Program.fs; reads JSON-RPC frames from stdin and
///     writes responses to stdout via the Lyric run loop.
///
/// `runWithMessages(inputs)` — called by ProtocolTests.fs; feeds each JSON
///     string through `lspInit` + `lspHandle` and collects all outbound
///     JSON strings without touching real stdin/stdout.
///
/// `buildWorkspaceIndex(dir)` — called by ProtocolTests.fs; builds and
///     returns the pkgName→absPath workspace index for a directory.
module Lyric.Lsp.SelfHostedLsp

open System
open System.Collections
open System.IO
open System.Reflection
open Lyric.Lexer
open Lyric.Emitter

/// Throwaway driver — importing Lyric.Lsp triggers the emitter to produce
/// and cache every transitive DLL (Lyric.Lexer, Lyric.Parser, …, Lyric.Lsp).
let private driverSource = """package Lyric.LspBridgeDriver
import Lyric.Lsp

func main(): Unit { }
"""

let private bridgeLock = obj ()

type private Delegates = {
    Init     : unit -> obj
    Handle   : obj -> string -> obj  // returns BCL List<string>
    RunLoop  : unit -> unit
    BuildIdx : string -> obj          // returns BCL Dictionary<string,string>
}

let mutable private resolved : Delegates option = None

let private preloadStdlibAssemblies () : unit =
    for p in Emitter.stdlibAssemblyPaths () do
        try Assembly.LoadFrom p |> ignore
        with _ -> ()

let private ensureLspAssembly () : string =
    let scratch =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-lsp-bridge-%d"
                         (Diagnostics.Process.GetCurrentProcess().Id))
    Directory.CreateDirectory scratch |> ignore
    let dllPath = Path.Combine(scratch, "Lyric.LspBridgeDriver.dll")
    let req : Emitter.EmitRequest =
        { Source             = driverSource
          AssemblyName       = "Lyric.LspBridgeDriver"
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
        failwithf "self-hosted LSP bridge: emitter errors:\n%s" msg

    preloadStdlibAssemblies ()

    match Emitter.stdlibAssemblyPaths ()
          |> List.tryFind (fun p ->
              Path.GetFileNameWithoutExtension p = "Lyric.Lyric.Lsp") with
    | Some p -> p
    | None ->
        let cached =
            Emitter.stdlibAssemblyPaths ()
            |> List.map (fun p ->
                Option.ofObj (Path.GetFileName p) |> Option.defaultValue "<unknown>")
            |> String.concat ", "
        failwithf
            "self-hosted LSP bridge: 'Lyric.Lyric.Lsp.dll' not found in stdlib cache \
             after emit (cached: %s)" cached

let private resolveDelegates () : Delegates =
    let dll  = ensureLspAssembly ()
    let asm  = Assembly.LoadFrom dll
    let prog =
        match Option.ofObj (asm.GetType "Lyric.Lsp.Program") with
        | Some t -> t
        | None   ->
            failwithf "self-hosted LSP bridge: 'Lyric.Lsp.Program' type missing from %s" dll

    // We search by name rather than using GetMethod(name, paramTypes) because
    // the loaded assembly's type objects are identity-distinct from the calling
    // assembly's types even when structurally identical.  A signature lookup
    // using typeof<string> from this assembly would never match the string type
    // from the freshly loaded one, causing GetMethod to return null.
    let pickStatic (name: string) =
        match prog.GetMethods()
              |> Array.tryFind (fun m -> m.Name = name && m.IsStatic) with
        | Some m -> m
        | None   ->
            failwithf "self-hosted LSP bridge: static method '%s' not found on Lyric.Lsp.Program"
                name

    let initM     = pickStatic "lspInit"
    let handleM   = pickStatic "lspHandle"
    let runLoopM  = pickStatic "lspRunLoop"
    let buildIdxM = pickStatic "lspBuildWorkspaceIndex"

    let initFn () : obj =
        match Option.ofObj (initM.Invoke(null, [||])) with
        | Some o -> o
        | None   -> failwith "self-hosted LSP bridge: lspInit returned null"

    let handleFn (state: obj) (json: string) : obj =
        match Option.ofObj (handleM.Invoke(null, [| state; box json |])) with
        | Some o -> o
        | None   -> failwith "self-hosted LSP bridge: lspHandle returned null"

    let runLoopFn () : unit =
        runLoopM.Invoke(null, [||]) |> ignore

    let buildIdxFn (dir: string) : obj =
        match Option.ofObj (buildIdxM.Invoke(null, [| box dir |])) with
        | Some o -> o
        | None   -> failwith "self-hosted LSP bridge: lspBuildWorkspaceIndex returned null"

    { Init = initFn; Handle = handleFn; RunLoop = runLoopFn; BuildIdx = buildIdxFn }

let private getDelegates () : Delegates =
    lock bridgeLock (fun () ->
        match resolved with
        | Some d -> d
        | None   ->
            let d = resolveDelegates ()
            resolved <- Some d
            d)

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

/// Drive the self-hosted LSP run loop.  Reads JSON-RPC frames from stdin and
/// writes responses to stdout; returns when the "exit" notification is received
/// or stdin is closed.
let runLoop () : unit =
    let d = getDelegates ()
    d.RunLoop ()

/// Process a list of JSON-RPC messages through the self-hosted `lspHandle`
/// entry point and return all outbound JSON strings.  Does not touch real
/// stdin/stdout — suitable for in-process tests.
let runWithMessages (inputs: string list) : string list =
    let d     = getDelegates ()
    let state = d.Init ()
    let out   = ResizeArray<string>()
    for json in inputs do
        let resultObj = d.Handle state json
        match resultObj with
        | :? IEnumerable as seq ->
            for item in seq do
                match Option.ofObj item with
                | Some o -> out.Add(string o)
                | None   -> ()
        | _ -> ()
    List.ofSeq out

/// Build the workspace index for `dir` and return it as a .NET
/// `Dictionary<string,string>` (pkgName → absPath).  Used by the test suite
/// to verify workspace indexing without running the full server loop.
let buildWorkspaceIndex (dir: string) : Collections.Generic.Dictionary<string, string> =
    let d      = getDelegates ()
    let result = d.BuildIdx dir
    match result with
    | :? Collections.Generic.Dictionary<string, string> as dict -> dict
    | :? IEnumerable as pairs ->
        // Fall back: iterate key-value pairs if the BCL type differs.
        let dict = Collections.Generic.Dictionary<string, string>()
        for item in pairs do
            match item with
            | null -> ()
            | _ ->
                let t = item.GetType()
                match Option.ofObj (t.GetProperty "Key"),
                      Option.ofObj (t.GetProperty "Value") with
                | Some kp, Some vp ->
                    match Option.ofObj (kp.GetValue item),
                          Option.ofObj (vp.GetValue item) with
                    | Some k, Some v -> dict.[string k] <- string v
                    | _ -> ()
                | _ -> ()
        dict
    | _ ->
        Collections.Generic.Dictionary<string, string>()
