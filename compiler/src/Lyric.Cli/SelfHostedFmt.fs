/// Bridge from the F# `lyric fmt` subcommand to the self-hosted
/// formatter (`Lyric.Fmt` — Phase 5 §M5.3 stage 2, PR #200).  Walks
/// the new red/green CST so non-doc comments survive `lyric fmt` —
/// the comment-loss the F# `Lyric.Cli.Fmt` formatter explicitly calls
/// out at the top of `Fmt.fs`.
///
/// Strategy: compile a tiny "driver" Lyric program whose only job is
/// to `import Lyric.Fmt`.  The emitter precompiles `Lyric.Fmt.dll`
/// into its per-process stdlib cache as a side-effect.  We then
/// `Assembly.LoadFrom` every cached DLL into the AppDomain (so the
/// transitive `Std.Core` / `Lyric.Parser` references resolve when
/// `Lyric.Fmt.dll` itself loads), reflect out the static
/// `formatSource(string)` and `isFormattedSource(string)` entry
/// points on `Lyric.Fmt.Program`, and cache the resulting delegates
/// for subsequent calls in the same process.
module Lyric.Cli.SelfHostedFmt

open System
open System.IO
open System.Reflection
open Lyric.Lexer
open Lyric.Emitter

/// Source of the throwaway driver program.  The empty `main` is the
/// minimum the emitter accepts; the `import Lyric.Fmt` triggers the
/// stdlib precompile path that drops `Lyric.Fmt.dll` into the cache
/// returned by `Emitter.stdlibAssemblyPaths`.
let private driverSource = """package Lyric.FmtBridge
import Lyric.Fmt

func main(): Unit { }
"""

/// Process-wide cache of the resolved entry points.  The driver
/// compile is the slow part (~3-5s on a cold cache); we only do it
/// once per `lyric` invocation that touches the formatter.
let private bridgeLock = obj ()
let mutable private resolved : ((string -> string) * (string -> bool)) option = None

/// Pre-load every cached stdlib DLL into the default AppDomain so
/// `Lyric.Fmt.dll`'s typeRef chain (Std.Core → Lyric.Lexer →
/// Lyric.Parser → Lyric.Fmt) resolves when the formatter assembly
/// itself loads.  Idempotent: `Assembly.LoadFrom` returns the same
/// `Assembly` instance on a duplicate path.
let private preloadStdlibAssemblies () : unit =
    for p in Emitter.stdlibAssemblyPaths () do
        try Assembly.LoadFrom p |> ignore
        with _ -> ()  // best-effort; missing/corrupt cache entries
                      // surface later when the consumer reflects

/// Compile the driver source so the emitter produces and caches
/// `Lyric.Fmt.dll`.  Returns the absolute path to it.
let private ensureLyricFmtAssembly () : string =
    let scratch =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-fmt-bridge-%d"
                         (System.Diagnostics.Process.GetCurrentProcess().Id))
    Directory.CreateDirectory scratch |> ignore
    let dllPath = Path.Combine(scratch, "Lyric.FmtBridge.dll")
    let req : Emitter.EmitRequest =
        { Source             = driverSource
          AssemblyName       = "Lyric.FmtBridge"
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
        failwithf "self-hosted formatter bridge: emitter produced errors:\n%s" msg

    preloadStdlibAssemblies ()

    // Emitter mints stdlib assemblies as `Lyric.<head>.<rest>.dll` for
    // builtin heads, so `Lyric.Fmt` lands as `Lyric.Lyric.Fmt.dll` in
    // the cache (the double `Lyric.` is head + per-package basename, by
    // design — see `Emitter.fs:assemblyName`).  Renaming it to drop
    // the prefix would collide with the F# bootstrap's same-named
    // assemblies (`Lyric.Lexer.dll` etc.) which export the same CLR
    // namespace but with PascalCase record fields, breaking type
    // resolution at codegen time.  The CLR type inside the DLL is
    // unaffected — it is named for the package path,
    // `Lyric.Fmt.Program`.
    let lyricFmtDll =
        Emitter.stdlibAssemblyPaths ()
        |> List.tryFind (fun p ->
            let n = Path.GetFileNameWithoutExtension p
            n = "Lyric.Lyric.Fmt")
    match lyricFmtDll with
    | Some p -> p
    | None ->
        let cached =
            Emitter.stdlibAssemblyPaths ()
            |> List.map (fun p ->
                match Option.ofObj (Path.GetFileName p) with
                | Some n -> n
                | None -> "<unknown>")
            |> String.concat ", "
        failwithf "self-hosted formatter bridge: 'Lyric.Lyric.Fmt.dll' not found in stdlib cache after emit (cached: %s)" cached

/// Reflect out the two entry points and stash them in `resolved`.
let private resolveDelegates () : (string -> string) * (string -> bool) =
    let dll = ensureLyricFmtAssembly ()
    let asm = Assembly.LoadFrom dll
    let progType =
        match Option.ofObj (asm.GetType "Lyric.Fmt.Program") with
        | Some t -> t
        | None ->
            failwithf "self-hosted formatter bridge: 'Lyric.Fmt.Program' type missing from %s" dll

    let pickStatic (name: string) (sigTypes: System.Type[]) =
        match Option.ofObj (progType.GetMethod(name, sigTypes)) with
        | Some m when m.IsStatic -> m
        | _ -> failwithf "self-hosted formatter bridge: static method '%s' not found on Lyric.Fmt.Program" name

    let formatM   = pickStatic "formatSource"      [| typeof<string> |]
    let isFmtM    = pickStatic "isFormattedSource" [| typeof<string> |]

    let formatFn (s: string) : string =
        match Option.ofObj (formatM.Invoke(null, [| box s |])) with
        | Some o -> string o
        | None   -> failwith "self-hosted formatter: formatSource returned null"
    let isFmtFn (s: string) : bool =
        match Option.ofObj (isFmtM.Invoke(null, [| box s |])) with
        | Some o -> unbox<bool> o
        | None   -> false

    formatFn, isFmtFn

let private getDelegates () : (string -> string) * (string -> bool) =
    lock bridgeLock (fun () ->
        match resolved with
        | None ->
            let pair = resolveDelegates ()
            resolved <- Some pair
            pair
        | Some r -> r)

/// Format `source` via the self-hosted `Lyric.Fmt`.  Comments are
/// preserved at item granularity (PR #200).
let format (source: string) : string =
    let fmt, _ = getDelegates ()
    fmt source

/// Whether `source` already matches its canonical form.
let isFormatted (source: string) : bool =
    let _, isFmt = getDelegates ()
    isFmt source
