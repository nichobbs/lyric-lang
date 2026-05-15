/// `lyric publish` / `lyric restore` commands (C8 part 2 /
/// D-progress-077).  Both commands lower the user's `lyric.toml`
/// into a generated, throw-away `.csproj` and shell out to `dotnet
/// pack` / `dotnet restore` respectively.
///
/// The csproj XML generation has been ported to the self-hosted
/// `Lyric.Pack` package (`compiler/lyric/lyric/pack/pack.l`);
/// `SelfHostedPack.publishCsproj` / `SelfHostedPack.restoreCsproj`
/// are called to produce the XML text.  Process invocation and path
/// resolution remain here as infrastructure shims.
module Lyric.Cli.Pack

open System
open System.Diagnostics
open System.IO
open Lyric.Cli.Manifest
open Lyric.Cli.Maven

/// Result of a `dotnet` invocation: the captured stdout/stderr plus
/// the exit code.  The wrappers stream stdout/stderr directly to
/// the user's console; this record is what the test harness consumes.
type DotnetResult =
    { ExitCode: int
      Stdout:   string
      Stderr:   string }

/// Find a usable `dotnet` host.  Mirrors the test kit's resolver so
/// the same binary that built the compiler is the one we shell out
/// to here.
let private dotnetHost () : string =
    let envPath = Environment.GetEnvironmentVariable "DOTNET_HOST_PATH"
    match Option.ofObj envPath with
    | Some p when File.Exists p -> p
    | _ ->
        let candidates =
            [ "/root/.dotnet/dotnet"
              Path.Combine(
                  Environment.GetFolderPath Environment.SpecialFolder.UserProfile,
                  ".dotnet",
                  "dotnet") ]
        match candidates |> List.tryFind File.Exists with
        | Some p -> p
        | None -> "dotnet"

/// Run a dotnet sub-command, optionally suppressing console output
/// (for tests).  When `quiet = false` stdout/stderr stream straight
/// to the inheriting console so users see real-time progress.
let runDotnet (args: string list) (workDir: string) (quiet: bool) : DotnetResult =
    let psi = ProcessStartInfo()
    psi.FileName <- dotnetHost ()
    for a in args do psi.ArgumentList.Add a
    psi.WorkingDirectory <- workDir
    psi.UseShellExecute <- false
    psi.CreateNoWindow <- true
    if quiet then
        psi.RedirectStandardOutput <- true
        psi.RedirectStandardError <- true
    let proc =
        match Option.ofObj (Process.Start psi) with
        | Some p -> p
        | None -> failwith "lyric: failed to start dotnet"
    use _ = proc
    let stdout =
        if quiet then proc.StandardOutput.ReadToEnd() else ""
    let stderr =
        if quiet then proc.StandardError.ReadToEnd() else ""
    proc.WaitForExit()
    { ExitCode = proc.ExitCode; Stdout = stdout; Stderr = stderr }

// ---------------------------------------------------------------------------
// Path conventions — unchanged from original Pack.fs.
// ---------------------------------------------------------------------------

let private sanitisedPackageNameFallback (raw: string) : string =
    let allowed (ch: char) =
        Char.IsLetterOrDigit ch || ch = '.' || ch = '_' || ch = '-'
    raw |> Seq.filter allowed |> Seq.toArray |> System.String

/// Default location of the user's pre-built DLL when the manifest
/// doesn't override.
let defaultDllPath (manifest: Manifest) (manifestDir: string) : string =
    let name = sanitisedPackageNameFallback manifest.Package.Name
    Path.Combine(manifestDir, "bin", name + ".dll")

/// Default `dotnet pack` output directory.
let defaultPackOutputDir (manifest: Manifest) (manifestDir: string) : string =
    match manifest.Build.OutputDir with
    | Some o -> Path.Combine(manifestDir, o)
    | None   -> Path.Combine(manifestDir, "pkg")

/// Throw-away scratch directory for the generated `.csproj`.
let scratchProjectDir (manifest: Manifest) (manifestDir: string) (subdir: string) : string =
    let sanitised = sanitisedPackageNameFallback manifest.Package.Name
    let suffix = sprintf "%s-%s" sanitised subdir
    Path.Combine(manifestDir, ".lyric", suffix)

// ---------------------------------------------------------------------------
// Top-level entry points used by `Program.fs`.
// ---------------------------------------------------------------------------

/// Run `dotnet pack` against a freshly-generated `.csproj` produced by
/// the self-hosted `Lyric.Pack` bridge.
let runPack (manifest: Manifest)
            (manifestDir: string)
            (dllPath: string)
            (outputDir: string)
            (quiet: bool) : Result<string, string> =
    if not (File.Exists dllPath) then
        Error (sprintf "publish: pre-built DLL '%s' not found — run `lyric build` first"
                       dllPath)
    else
    let tomlPath = Path.Combine(manifestDir, "lyric.toml")
    let toml     = if File.Exists tomlPath then File.ReadAllText tomlPath else ""
    let csprojText =
        match SelfHostedPack.publishCsproj toml dllPath with
        | Ok xml  -> xml
        | Error e ->
            // Manifest parse failed — fall back to no XML so dotnet pack aborts cleanly.
            failwithf "publish: manifest parse error: %s" e
    let scratch   = scratchProjectDir manifest manifestDir "pack"
    Directory.CreateDirectory scratch |> ignore
    let name      = sanitisedPackageNameFallback manifest.Package.Name
    let csprojPath = Path.Combine(scratch, name + ".csproj")
    let xmlText : string = csprojText
    File.WriteAllText(csprojPath, xmlText)
    Directory.CreateDirectory outputDir |> ignore
    let result =
        runDotnet
            [ "pack"
              csprojPath
              "--configuration"; "Release"
              "--output"; Path.GetFullPath outputDir ]
            scratch
            quiet
    if result.ExitCode <> 0 then
        let detail =
            if quiet then result.Stderr.Trim()
            else "(see dotnet pack output above)"
        Error (sprintf "publish: dotnet pack exited %d %s" result.ExitCode detail)
    else
        let nupkgName =
            sprintf "%s.%s.nupkg" name manifest.Package.Version
        let nupkgPath = Path.Combine(outputDir, nupkgName)
        if File.Exists nupkgPath then Ok nupkgPath
        else
            let candidates = Directory.GetFiles(outputDir, "*.nupkg")
            match Array.tryHead candidates with
            | Some p -> Ok p
            | None -> Error "publish: dotnet pack succeeded but produced no .nupkg"

/// Run `dotnet restore` against a freshly-generated `.csproj` produced by
/// the self-hosted `Lyric.Pack` bridge.
let runRestore (manifest: Manifest)
               (manifestDir: string)
               (quiet: bool) : Result<unit, string> =
    let tomlPath = Path.Combine(manifestDir, "lyric.toml")
    let toml     = if File.Exists tomlPath then File.ReadAllText tomlPath else ""
    let csprojText =
        match SelfHostedPack.restoreCsproj toml with
        | Ok xml  -> xml
        | Error e -> failwithf "restore: manifest parse error: %s" e
    let scratch   = scratchProjectDir manifest manifestDir "restore"
    Directory.CreateDirectory scratch |> ignore
    let name      = sanitisedPackageNameFallback manifest.Package.Name
    let csprojPath = Path.Combine(scratch, name + ".csproj")
    let xmlText : string = csprojText
    File.WriteAllText(csprojPath, xmlText)
    let result = runDotnet [ "restore"; csprojPath ] scratch quiet
    if result.ExitCode = 0 then Ok ()
    else
        let detail =
            if quiet then result.Stderr.Trim()
            else "(see dotnet restore output above)"
        Error (sprintf "restore: dotnet restore exited %d %s"
                       result.ExitCode detail)

/// Run the Maven Central resolver for `[maven]` dependencies.
let runMavenRestore
        (manifest:    Manifest)
        (manifestDir: string)
        (quiet:       bool)
        : Result<ResolvedMavenJar list, string> =
    match manifest.Maven with
    | None -> Ok []
    | Some maven ->
        if List.isEmpty maven.Packages then Ok []
        else
        match findResolverJar () with
        | Error locErr -> Error (Maven.renderLocateError locErr)
        | Ok jarPath ->
        let cacheDir = Path.Combine(Maven.userCacheDir (), "maven")
        let outputDir = Path.Combine(manifestDir, "target", "restore", "jars")
        Directory.CreateDirectory cacheDir  |> ignore
        Directory.CreateDirectory outputDir |> ignore
        let repos =
            match maven.Options.Repositories with
            | [] -> [ "central" ]
            | rs -> rs
        let javaVersion =
            match maven.Options.JavaVersion with
            | Some v -> v
            | None   -> "21"
        let coordinates =
            maven.Packages
            |> List.map (fun e ->
                { Group    = e.Group
                  Artifact = e.Artifact
                  Version  = e.Version })
        let req : MavenResolveRequest =
            { Coordinates  = coordinates
              Repositories = repos
              JavaVersion  = javaVersion
              CacheDir     = cacheDir
              OutputDir    = outputDir }
        match runMavenResolve jarPath req quiet with
        | Error resolveErr -> Error (Maven.renderResolveError resolveErr)
        | Ok jars -> Ok jars
