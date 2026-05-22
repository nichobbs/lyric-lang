/// `lyric` — bootstrap entry point used by the bootstrap pipeline only.
///
/// Track A A1.4 (#860) deletes the F# user-facing CLI: every user
/// command (`lyric build`, `lyric run`, `lyric fmt`, …) now flows
/// through the AOT entry-point project (`bootstrap/src/Lyric.Cli.Aot/`)
/// straight into the Lyric-emitted `Lyric.Cli.Program.main`.  What
/// remains here is the bootstrap-only surface that the F# `Lyric.Emitter`
/// package's stage-1 driver uses to compile Lyric source while the
/// self-hosted compiler is itself being precompiled:
///
///   * `--internal-build`         — single-file compile through the
///                                  F# emitter; called from
///                                  `Lyric.Emitter.emit` when the in-
///                                  process MSIL bridge isn't usable
///                                  yet (e.g. during stage 1 bundle
///                                  precompile).
///   * `--internal-project-build` — multi-package project compile.
///   * `--internal-contract-meta` — read / diff embedded contract JSON.
///
/// Anything else returns a one-line error pointing at the AOT binary,
/// because the F# dispatcher no longer exists.
module Lyric.Cli.Program

open System
open System.IO
open Lyric.Lexer
open Lyric.Emitter

let private printErr (s: string) : unit =
    Console.Error.WriteLine s

let private safeStr (s: string | null) (fallback: string) : string =
    match Option.ofObj s with
    | Some v -> v
    | None   -> fallback

/// Write a minimal `runtimeconfig.json` next to the produced PE so
/// `dotnet exec` knows which runtime to load.
let private writeRuntimeConfig (dllPath: string) : unit =
    let configPath =
        safeStr (Path.ChangeExtension(dllPath, ".runtimeconfig.json"))
                (dllPath + ".runtimeconfig.json")
    let runtimeVersion = Environment.Version
    let json =
        let sb = System.Text.StringBuilder()
        sb.AppendLine "{" |> ignore
        sb.AppendLine "  \"runtimeOptions\": {" |> ignore
        sb.AppendLine (sprintf "    \"tfm\": \"net%d.%d\","
                        runtimeVersion.Major runtimeVersion.Minor) |> ignore
        sb.AppendLine "    \"framework\": {" |> ignore
        sb.AppendLine "      \"name\": \"Microsoft.NETCore.App\"," |> ignore
        sb.AppendLine (sprintf "      \"version\": \"%s\""
                        (runtimeVersion.ToString())) |> ignore
        sb.AppendLine "    }" |> ignore
        sb.AppendLine "  }" |> ignore
        sb.AppendLine "}" |> ignore
        sb.ToString()
    File.WriteAllText(configPath, json)

/// `lyric --internal-build <srcFile> -o <outFile> [--target dotnet|jvm]`
/// Single-file compile with the F# emitter.  Minimal flag set; no manifest,
/// no NuGet, no AOT.  Errors are printed to stderr and the process exits
/// non-zero.  Used by the Lyric `Lyric.Emitter` package.
let private internalBuild (rest: string list) : int =
    let mutable srcPath = ""
    let mutable outPath = ""
    let mutable target  = Emitter.Dotnet
    let mutable cursor  = rest
    while not (List.isEmpty cursor) do
        match cursor with
        | "-o" :: out :: tail ->
            outPath <- out
            cursor  <- tail
        | "--target" :: "jvm" :: tail ->
            target <- Emitter.Jvm
            cursor <- tail
        | "--target" :: _ :: tail ->
            target <- Emitter.Dotnet
            cursor <- tail
        | arg :: tail ->
            if not (arg.StartsWith("-", StringComparison.Ordinal)) then
                srcPath <- arg
            cursor <- tail
        | [] -> cursor <- []

    if String.IsNullOrEmpty srcPath || not (File.Exists srcPath) then
        printErr (sprintf "internal-build: source file not found: %s" srcPath)
        1
    elif String.IsNullOrEmpty outPath then
        printErr "internal-build: missing -o <outputPath>"
        1
    else
        let source = File.ReadAllText srcPath
        match Option.ofObj (Path.GetDirectoryName outPath) with
        | Some dir when not (String.IsNullOrEmpty dir) ->
            Directory.CreateDirectory dir |> ignore
        | _ -> ()
        let asmName =
            match Option.ofObj (Path.GetFileNameWithoutExtension outPath) with
            | Some n -> n
            | None   -> "lyric_build_out"
        let req : Emitter.EmitRequest =
            { Source             = source
              AssemblyName       = asmName
              OutputPath         = outPath
              RestoredPackages   = []
              NugetAssemblyPaths = []
              ExternShimRoot     = None
              Target             = target
              ActiveFeatures     = Set.empty
              DeclaredFeatures   = Set.empty }
        let result = Emitter.emit req
        let errs   = result.Diagnostics |> List.filter (fun d -> d.Severity = DiagError)
        for d in result.Diagnostics do
            printErr (sprintf "%s %s [%d:%d]: %s"
                d.Code
                (if d.Severity = DiagError then "error" else "warning")
                d.Span.Start.Line d.Span.Start.Column d.Message)
        if not (List.isEmpty errs) then
            printErr (sprintf "%s: build failed" srcPath)
            1
        else
            writeRuntimeConfig outPath
            0

/// `lyric --internal-contract-meta read <dll>`
/// Outputs the embedded Lyric.Contract JSON to stdout, or nothing if absent.
///
/// `lyric --internal-contract-meta diff`
/// Reads old and new JSON from stdin (separated by `\n---\n`), diffs them,
/// and prints each rendered entry followed by a blank line.
/// Used by the Lyric `Lyric.ContractMeta` package.
let private internalContractMeta (rest: string list) : int =
    match rest with
    | "read" :: dllPath :: _ ->
        if not (File.Exists dllPath) then
            printErr (sprintf "internal-contract-meta read: file not found: %s" dllPath)
            1
        else
            match Lyric.Emitter.ContractMeta.readFromAssembly dllPath with
            | None      -> ()   // empty stdout = no contract
            | Some json -> printfn "%s" json
            0
    | "diff" :: _ ->
        let stdin  = Console.In.ReadToEnd()
        let parts  = stdin.Split([| "\n---\n" |], StringSplitOptions.None)
        if parts.Length < 2 then
            printErr "internal-contract-meta diff: expected old and new JSON in stdin, separated by \\n---\\n"
            1
        else
            let oldJson = parts.[0]
            let newJson = parts.[1]
            match Lyric.Emitter.ContractMeta.parseFromJson oldJson,
                  Lyric.Emitter.ContractMeta.parseFromJson newJson with
            | Some oldC, Some newC ->
                let entries = Lyric.Emitter.ContractMeta.diffContracts oldC newC
                for entry in entries do
                    printfn "%s\n" (Lyric.Emitter.ContractMeta.renderDiffEntry entry)
                0
            | None, _ ->
                printErr "internal-contract-meta diff: could not parse old contract JSON"
                1
            | _, None ->
                printErr "internal-contract-meta diff: could not parse new contract JSON"
                1
    | _ ->
        printErr "internal-contract-meta: unknown subcommand (expected 'read' or 'diff')"
        1

/// `lyric --internal-project-build <specFile> -o <outFile> [--target dotnet|jvm]`
/// Multi-package project compile.  The spec file is a tab-delimited text file;
/// each line has the form: <packageName> TAB <srcPath1> TAB <srcPath2> ...
/// Errors are printed to stderr; the process exits non-zero on failure.
/// Used by the Lyric `Lyric.Emitter` package's `emitProject` function.
let private internalProjectBuild (rest: string list) : int =
    let mutable specPath = ""
    let mutable outPath  = ""
    let mutable target   = Emitter.Dotnet
    let mutable cursor   = rest
    while not (List.isEmpty cursor) do
        match cursor with
        | "-o" :: out :: tail ->
            outPath <- out
            cursor  <- tail
        | "--target" :: "jvm" :: tail ->
            target <- Emitter.Jvm
            cursor <- tail
        | "--target" :: _ :: tail ->
            target <- Emitter.Dotnet
            cursor <- tail
        | arg :: tail ->
            if not (arg.StartsWith("-", StringComparison.Ordinal)) then
                specPath <- arg
            cursor <- tail
        | [] -> cursor <- []

    if String.IsNullOrEmpty specPath || not (File.Exists specPath) then
        printErr (sprintf "internal-project-build: spec file not found: %s" specPath)
        1
    elif String.IsNullOrEmpty outPath then
        printErr "internal-project-build: missing -o <outputPath>"
        1
    else
        let lines = File.ReadAllLines specPath
        let pkgInputs      = ResizeArray<Lyric.Emitter.Emitter.ProjectPackageInput>()
        let depRefs        = ResizeArray<Lyric.Emitter.RestoredPackages.RestoredPackageRef>()
        let activeFeatures = ResizeArray<string>()
        let mutable hadFatal = false
        for line in lines do
            if not (String.IsNullOrEmpty line) then
                if line.StartsWith("DEP\t", StringComparison.Ordinal) then
                    // DEP line: DEP\t<depName>\t<dllPath>
                    let parts = line.Split('\t')
                    if parts.Length >= 3 then
                        let depName = parts.[1]
                        let depDll  = parts.[2]
                        if File.Exists depDll then
                            depRefs.Add
                                { Lyric.Emitter.RestoredPackages.RestoredPackageRef.Name    = depName
                                  Lyric.Emitter.RestoredPackages.RestoredPackageRef.Version = "0.0.0"
                                  Lyric.Emitter.RestoredPackages.RestoredPackageRef.DllPath = depDll }
                        else
                            printErr (sprintf "internal-project-build: dep DLL not found: %s" depDll)
                            hadFatal <- true
                elif line.StartsWith("FEATURE\t", StringComparison.Ordinal) then
                    // FEATURE line: FEATURE\t<featureName>
                    let parts = line.Split('\t')
                    if parts.Length >= 2 then
                        activeFeatures.Add parts.[1]
                else
                    // PKG line: <packageName>\t<srcPath1>\t<srcPath2>...
                    let parts = line.Split('\t')
                    if parts.Length < 2 then
                        printErr (sprintf "internal-project-build: malformed spec line: %s" line)
                        hadFatal <- true
                    else
                        let pkgName  = parts.[0]
                        let srcPaths = parts |> Array.skip 1
                        let sources  = ResizeArray<string>()
                        for sp in srcPaths do
                            if File.Exists sp then
                                sources.Add(File.ReadAllText sp)
                            else
                                printErr (sprintf "internal-project-build: source file not found: %s" sp)
                                hadFatal <- true
                        if not hadFatal then
                            pkgInputs.Add
                                { Lyric.Emitter.Emitter.ProjectPackageInput.PackageName = pkgName
                                  Lyric.Emitter.Emitter.ProjectPackageInput.Sources     = List.ofSeq sources }
        if hadFatal then 1
        else
        match Option.ofObj (Path.GetDirectoryName outPath) with
        | Some dir when not (String.IsNullOrEmpty dir) ->
            Directory.CreateDirectory dir |> ignore
        | _ -> ()
        let asmName =
            match Option.ofObj (Path.GetFileNameWithoutExtension outPath) with
            | Some n -> n
            | None   -> "lyric_build_out"
        let req : Lyric.Emitter.Emitter.ProjectEmitRequest =
            { Packages           = List.ofSeq pkgInputs
              AssemblyName       = asmName
              OutputPath         = outPath
              RestoredPackages   = List.ofSeq depRefs
              NugetAssemblyPaths = []
              ExternShimRoot     = None
              Single             = true
              Target             = target
              ActiveFeatures     = Set.ofSeq activeFeatures
              DeclaredFeatures   = Set.ofSeq activeFeatures }
        let result = Emitter.emitProject req
        let errs   = result.Diagnostics |> List.filter (fun d -> d.Severity = DiagError)
        for d in result.Diagnostics do
            printErr (sprintf "%s %s [%d:%d]: %s"
                d.Code
                (if d.Severity = DiagError then "error" else "warning")
                d.Span.Start.Line d.Span.Start.Column d.Message)
        if not (List.isEmpty errs) then
            printErr (sprintf "%s: project build failed" specPath)
            1
        else
            writeRuntimeConfig outPath
            0

/// `lyric --internal-manifest-build <lyric.toml> -o <outFile> [--target dotnet|jvm]`
/// Bootstrap-only multi-package build: parses `lyric.toml`, walks
/// `[project.packages]`, and drives `Emitter.emitProject` against
/// the listed source files.  Used by `scripts/bootstrap.sh` stage 1
/// to compile the stdlib bundle; the user-facing `lyric build
/// --manifest` flow went away with Track A A1.4 (#860).
///
/// Only the subset of `lyric.toml` the stdlib bundle uses is
/// honoured: `[project] output = "single"`, `output_assembly`, and
/// `[project.packages]` entries whose values are `.l` file paths
/// relative to the manifest directory.  NuGet / Maven sections are
/// ignored (the stdlib bundle has none).
let private internalManifestBuild (rest: string list) : int =
    let mutable manifestPath = ""
    let mutable outPath      = ""
    let mutable target       = Emitter.Dotnet
    let mutable cursor       = rest
    while not (List.isEmpty cursor) do
        match cursor with
        | "-o" :: out :: tail ->
            outPath <- out
            cursor  <- tail
        | "--target" :: "jvm" :: tail ->
            target <- Emitter.Jvm
            cursor <- tail
        | "--target" :: _ :: tail ->
            target <- Emitter.Dotnet
            cursor <- tail
        | arg :: tail ->
            if not (arg.StartsWith("-", StringComparison.Ordinal)) then
                manifestPath <- arg
            cursor <- tail
        | [] -> cursor <- []

    if String.IsNullOrEmpty manifestPath || not (File.Exists manifestPath) then
        printErr (sprintf "internal-manifest-build: manifest not found: %s" manifestPath)
        1
    elif String.IsNullOrEmpty outPath then
        printErr "internal-manifest-build: missing -o <outputPath>"
        1
    else
    match Lyric.Cli.Manifest.parseFile manifestPath with
    | Error err ->
        let msg =
            match err with
            | Lyric.Cli.Manifest.MissingFile path ->
                sprintf "manifest file not found: %s" path
            | Lyric.Cli.Manifest.ParseError (line, col, m) ->
                sprintf "parse error at %d:%d: %s" line col m
            | Lyric.Cli.Manifest.MissingField (section, key) ->
                sprintf "missing required field [%s].%s" section key
            | Lyric.Cli.Manifest.InvalidFieldType (section, key, expected) ->
                sprintf "[%s].%s expected %s" section key expected
        printErr (sprintf "internal-manifest-build: %s: %s" manifestPath msg)
        1
    | Ok manifest ->
        match manifest.Project with
        | None ->
            printErr (sprintf "internal-manifest-build: %s has no [project] section" manifestPath)
            1
        | Some project ->
            let manifestDir =
                safeStr (Path.GetDirectoryName(Path.GetFullPath manifestPath)) "."
            let pkgInputs = ResizeArray<Lyric.Emitter.Emitter.ProjectPackageInput>()
            let mutable hadFatal = false
            for (pkgName, relPath) in project.Packages do
                let absPath =
                    if Path.IsPathRooted relPath then relPath
                    else Path.GetFullPath(Path.Combine(manifestDir, relPath))
                if File.Exists absPath then
                    pkgInputs.Add
                        { Lyric.Emitter.Emitter.ProjectPackageInput.PackageName = pkgName
                          Lyric.Emitter.Emitter.ProjectPackageInput.Sources     = [ File.ReadAllText absPath ] }
                else
                    printErr (sprintf "internal-manifest-build: package source '%s' not found at '%s'"
                                pkgName absPath)
                    hadFatal <- true
            if hadFatal then 1
            else
            match Option.ofObj (Path.GetDirectoryName outPath) with
            | Some dir when not (String.IsNullOrEmpty dir) ->
                Directory.CreateDirectory dir |> ignore
            | _ -> ()
            let asmName =
                match project.OutputAssembly with
                | Some n when not (String.IsNullOrEmpty n) ->
                    match Option.ofObj (Path.GetFileNameWithoutExtension n) with
                    | Some s -> s
                    | None   -> manifest.Package.Name
                | _ -> manifest.Package.Name
            let req : Lyric.Emitter.Emitter.ProjectEmitRequest =
                { Packages           = List.ofSeq pkgInputs
                  AssemblyName       = asmName
                  OutputPath         = outPath
                  RestoredPackages   = []
                  NugetAssemblyPaths = []
                  ExternShimRoot     = None
                  Single             = true
                  Target             = target
                  ActiveFeatures     = Set.empty
                  DeclaredFeatures   = Set.empty }
            let result = Emitter.emitProject req
            let errs   = result.Diagnostics |> List.filter (fun d -> d.Severity = DiagError)
            for d in result.Diagnostics do
                printErr (sprintf "%s %s [%d:%d]: %s"
                    d.Code
                    (if d.Severity = DiagError then "error" else "warning")
                    d.Span.Start.Line d.Span.Start.Column d.Message)
            if not (List.isEmpty errs) then
                printErr (sprintf "%s: manifest build failed" manifestPath)
                1
            else
                writeRuntimeConfig outPath
                0

[<EntryPoint>]
let main (argv: string array) : int =
    // Bootstrap.sh and the F# `Lyric.Emitter` package shell back into
    // this process for `--internal-*` operations; expose the entry
    // path so the Lyric driver can find it without `lyric` on PATH.
    if isNull (Environment.GetEnvironmentVariable "LYRIC_BIN") then
        try
            match Option.ofObj (Diagnostics.Process.GetCurrentProcess().MainModule) with
            | Some m when not (String.IsNullOrEmpty m.FileName) ->
                Environment.SetEnvironmentVariable("LYRIC_BIN", m.FileName)
            | _ -> ()
        with _ -> ()
    if isNull (Environment.GetEnvironmentVariable "LYRIC_CLI_DLL") then
        try
            match Option.ofObj (Reflection.Assembly.GetEntryAssembly()) with
            | Some entry when not (String.IsNullOrEmpty entry.Location)
                           && File.Exists entry.Location ->
                Environment.SetEnvironmentVariable("LYRIC_CLI_DLL", entry.Location)
            | _ -> ()
        with _ -> ()
    let args = List.ofArray argv
    match args with
    | "--internal-build" :: rest ->
        internalBuild rest
    | "--internal-manifest-build" :: rest ->
        internalManifestBuild rest
    | "--internal-project-build" :: rest ->
        internalProjectBuild rest
    | "--internal-contract-meta" :: rest ->
        internalContractMeta rest
    | _ ->
        printErr "lyric (F# bootstrap): user-facing commands have moved to the AOT entry point."
        printErr "Run `dotnet build bootstrap/src/Lyric.Cli.Aot` and use the resulting `lyric` binary,"
        printErr "or invoke the self-hosted CLI directly via `bootstrap/src/Lyric.Cli.Aot/bin/.../lyric`."
        printErr "This bootstrap binary only handles `--internal-build`, `--internal-project-build`, `--internal-contract-meta`, and `--internal-manifest-build`."
        1
