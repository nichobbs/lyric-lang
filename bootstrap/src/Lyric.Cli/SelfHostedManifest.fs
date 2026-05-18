/// Bridge from the F# manifest-parsing calls to the self-hosted
/// `Lyric.ManifestBridge` package (Phase 5 §M5.3 shim elimination).
///
/// Strategy: compile a tiny driver that `import Lyric.ManifestBridge`.
/// The emitter precompiles the bridge DLL into the per-process stdlib
/// cache as a side-effect.  We then reflect out the static
/// `serializeManifest(string, string): string` entry point, which
/// returns a line-oriented key=value protocol (see manifest_bridge.l
/// for the format), and parse it back into the F# `Manifest` type.
///
/// Fields not present in the self-hosted manifest (`Build`, `Maven`,
/// `Package.Repository`) are filled with safe defaults so the returned
/// `Manifest` is drop-in-compatible with the F# manifest parser for the
/// `build` subcommand.  `publish` and `restore` keep using the F#
/// parser (they need `Build.Sources` and `Package` metadata).
module Lyric.Cli.SelfHostedManifest

open System
open System.IO
open System.Reflection
open Lyric.Lexer
open Lyric.Emitter

let private driverSource = """package Lyric.ManifestBridgeDriver
import Lyric.ManifestBridge

func main(): Unit { }
"""

let private bridgeLock = obj ()
let mutable private resolved : (string -> string -> string) option = None

let private preloadStdlibAssemblies () : unit =
    for p in Emitter.stdlibAssemblyPaths () do
        try Assembly.LoadFrom p |> ignore
        with _ -> ()

let private ensureBridgeAssembly () : string =
    let scratch =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-manifest-bridge-%d"
                         (System.Diagnostics.Process.GetCurrentProcess().Id))
    Directory.CreateDirectory scratch |> ignore
    AppDomain.CurrentDomain.ProcessExit.Add(fun _ ->
        try Directory.Delete(scratch, recursive = true) with _ -> ())
    let dllPath = Path.Combine(scratch, "Lyric.ManifestBridgeDriver.dll")
    let req : Emitter.EmitRequest =
        { Source             = driverSource
          AssemblyName       = "Lyric.ManifestBridgeDriver"
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
        failwithf "self-hosted manifest bridge: emitter errors:\n%s" msg

    preloadStdlibAssemblies ()

    match Emitter.stdlibAssemblyPaths ()
          |> List.tryFind (fun p -> Path.GetFileNameWithoutExtension p = "Lyric.Lyric.ManifestBridge") with
    | Some p -> p
    | None ->
        let cached =
            Emitter.stdlibAssemblyPaths ()
            |> List.map (fun p -> Option.ofObj (Path.GetFileName p) |> Option.defaultValue "<unknown>")
            |> String.concat ", "
        failwithf "self-hosted manifest bridge: 'Lyric.Lyric.ManifestBridge.dll' not found (cached: %s)" cached

let private resolveDelegates () : string -> string -> string =
    let dll = ensureBridgeAssembly ()
    let asm = Assembly.LoadFrom dll
    let progType =
        match Option.ofObj (asm.GetType "Lyric.ManifestBridge.Program") with
        | Some t -> t
        | None   -> failwithf "self-hosted manifest bridge: 'Lyric.ManifestBridge.Program' missing from %s" dll
    let m =
        match Option.ofObj (progType.GetMethod("serializeManifest", [| typeof<string>; typeof<string> |])) with
        | Some m when m.IsStatic -> m
        | _ -> failwithf "self-hosted manifest bridge: 'serializeManifest' not found"
    fun (text: string) (filePath: string) ->
        match Option.ofObj (m.Invoke(null, [| box text; box filePath |])) with
        | Some o -> string o
        | None   -> "err\nunknown error"

let private getDelegate () : string -> string -> string =
    lock bridgeLock (fun () ->
        match resolved with
        | None   -> let fn = resolveDelegates () in resolved <- Some fn; fn
        | Some r -> r)

// ─── Protocol parser ────────────────────────────────────────────────────────

let private splitOnFirst (sep: char) (s: string) : string * string =
    let idx = s.IndexOf sep
    if idx < 0 then s, "" else s.Substring(0, idx), s.Substring(idx + 1)

let private parseProtocol (filePath: string) (protocol: string) : Result<Manifest.Manifest, Manifest.ManifestError> =
    let lines = protocol.Split '\n'
    if lines.Length = 0 || lines.[0] <> "ok" then
        let msg = if lines.Length > 1 then lines.[1] else protocol
        Error (Manifest.ParseError(1, 0, msg))
    else
        let mutable pkgName        = ""
        let mutable pkgVersion     = ""
        let mutable pkgDescription = ""
        let mutable pkgLicense     = ""
        let mutable pkgAuthors : string list      = []
        let mutable deps    : Manifest.Dependency list  = []
        let mutable nugetEs : Manifest.NugetEntry list  = []
        let mutable nugetTarget    : string option = None
        let mutable nugetNative    = false
        let mutable projName       : string option = None
        let mutable projOutput     : string option = None
        let mutable projOutAsm     : string option = None
        let mutable projPkgs       : (string * string) list = []
        let mutable featDeclared   : string list = []
        let mutable featDefault    : string list = []

        // All key checks use StringComparison.Ordinal: the protocol is
        // an ASCII line-oriented format produced by the self-hosted side,
        // so a Turkish-locale CI runner (`StringComparison.CurrentCulture`,
        // the default for the curried-call form) must not be allowed to
        // fold `i`/`I` and parse the wrong field.  See #345.
        let inline starts (s: string) (prefix: string) =
            s.StartsWith(prefix, StringComparison.Ordinal)
        for line in lines.[1..] do
            if   starts line "pkg.name="              then pkgName        <- line.Substring 9
            elif starts line "pkg.version="           then pkgVersion     <- line.Substring 12
            elif starts line "pkg.description="       then pkgDescription <- line.Substring 16
            elif starts line "pkg.license="           then pkgLicense     <- line.Substring 12
            elif starts line "pkg.author="            then
                pkgAuthors <- pkgAuthors @ [line.Substring 11]
            elif starts line "dep=" then
                let name, ver = splitOnFirst '=' (line.Substring 4)
                deps <- deps @ [{ Manifest.Dependency.Name = name; Version = ver; LocalPath = None }]
            elif starts line "dep-path=" then
                let name, path = splitOnFirst '=' (line.Substring 9)
                deps <- deps @ [{ Manifest.Dependency.Name = name; Version = ""; LocalPath = Some path }]
            elif starts line "nuget=" then
                let id_, ver = splitOnFirst '=' (line.Substring 6)
                nugetEs <- nugetEs @ [{ Manifest.NugetEntry.Id = id_; Version = ver }]
            elif starts line "nuget.target="          then nugetTarget  <- Some (line.Substring 13)
            elif line = "nuget.allow_native=true"     then nugetNative  <- true  // intentional equality: F# `=` uses ordinal comparison; `starts` has a Turkish-locale hazard for single-char prefixes
            elif starts line "project.name="          then projName     <- Some (line.Substring 13)
            elif starts line "project.output_assembly=" then projOutAsm <- Some (line.Substring 24)
            elif starts line "project.output="        then projOutput   <- Some (line.Substring 15)
            elif starts line "project.pkg=" then
                let name, path = splitOnFirst '=' (line.Substring 12)
                projPkgs <- projPkgs @ [(name, path)]
            elif starts line "feature.default="       then
                featDefault <- featDefault @ [line.Substring 16]
            elif starts line "feature="               then
                featDeclared <- featDeclared @ [line.Substring 8]

        let pkg : Manifest.PackageMetadata =
            { Name        = pkgName
              Version     = pkgVersion
              Description = if pkgDescription = "" then None else Some pkgDescription
              Authors     = pkgAuthors
              License     = if pkgLicense = "" then None else Some pkgLicense
              Repository  = None }

        let nuget : Manifest.NugetSection option =
            if List.isEmpty nugetEs && nugetTarget.IsNone && not nugetNative then None
            else
                Some { Packages = nugetEs
                       Options  = { AllowNative = nugetNative; Target = nugetTarget } }

        let project : Manifest.ProjectSection option =
            match projName with
            | None -> None
            | Some name ->
                let mode =
                    match projOutput with
                    | Some "single" -> Manifest.Single
                    | _             -> Manifest.PerPackage
                Some { Name = name; Output = mode; OutputAssembly = projOutAsm; Packages = projPkgs }

        let features : Manifest.FeaturesSection option =
            if List.isEmpty featDeclared && List.isEmpty featDefault then None
            else Some { Declared = featDeclared; Default = featDefault }

        Ok { Package      = pkg
             Build        = { Sources = None; OutputDir = None }
             Dependencies = deps
             Project      = project
             Nuget        = nuget
             Maven        = None
             Features     = features }

/// Parse the manifest text via the self-hosted `Lyric.ManifestBridge`.
let parseText (text: string) (filePath: string) : Result<Manifest.Manifest, Manifest.ManifestError> =
    let fn       = getDelegate ()
    let protocol = fn text filePath
    parseProtocol filePath protocol

/// Locate and parse `lyric.toml` via the self-hosted manifest bridge.
let parseFile (path: string) : Result<Manifest.Manifest, Manifest.ManifestError> =
    if not (File.Exists path) then Error (Manifest.MissingFile path)
    else parseText (File.ReadAllText path) path
