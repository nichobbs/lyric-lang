/// `lyric publish` / `lyric restore` commands (C8 part 2 /
/// D-progress-077).  Both commands lower the user's `lyric.toml`
/// into a generated, throw-away `.csproj` and shell out to `dotnet
/// pack` / `dotnet restore` respectively.  The .csproj is the only
/// surface the bootstrap relies on — Lyric never reads it back; it
/// exists purely so the NuGet tooling sees a valid project shape.
///
/// `publish` also embeds the user's pre-built `<package>.dll` into
/// the .nupkg under `lib/net10.0/` via a `<None>` packaging item,
/// so consumers see exactly the assembly the bootstrap emitted
/// (with the embedded `Lyric.Contract` resource intact, per
/// D-progress-031).  Building the DLL is the user's responsibility:
/// run `lyric build src/main.l` (or whatever) before `lyric publish`.
module Lyric.Cli.Pack

open System
open System.Diagnostics
open System.IO
open Lyric.Cli.Manifest

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
// Generated `.csproj` shape.  Both publish and restore emit a tiny
// project from a template — publish bundles the pre-built DLL via
// `<None Include=... Pack="true" PackagePath=... />`, restore just
// declares `<PackageReference>` items so transitive resolution runs.
// ---------------------------------------------------------------------------

/// XML-escape a string for use inside an attribute or element value.
let private xmlEscape (s: string) : string =
    s.Replace("&", "&amp;")
     .Replace("<", "&lt;")
     .Replace(">", "&gt;")
     .Replace("\"", "&quot;")
     .Replace("'", "&apos;")

let private sanitisedPackageName (raw: string) : string =
    // `dotnet pack` happily accepts arbitrary `<PackageId>` values,
    // but the underlying build tooling refuses identifiers containing
    // characters NuGet's own validator rejects (whitespace, control
    // chars, slashes).  Trim to a sensible subset rather than letting
    // a bad manifest blow up deep in MSBuild.
    let allowed (ch: char) =
        Char.IsLetterOrDigit ch || ch = '.' || ch = '_' || ch = '-'
    raw
    |> Seq.filter allowed
    |> Seq.toArray
    |> System.String

/// Build the `.csproj` text used by `lyric publish`.  Embeds the
/// pre-built Lyric DLL under `lib/net10.0/` and forwards every
/// dependency from `lyric.toml` as a `<PackageReference>`.
let publishCsproj (manifest: Manifest) (dllPath: string) : string =
    let pkg = manifest.Package
    let sanitisedId = sanitisedPackageName pkg.Name
    let assemblyFile =
        match Option.ofObj (Path.GetFileName dllPath) with
        | Some f -> f
        | None -> sanitisedId + ".dll"
    let authorsXml =
        if List.isEmpty pkg.Authors then ""
        else "    <Authors>"
             + xmlEscape (String.concat ";" pkg.Authors)
             + "</Authors>\n"
    let descriptionXml =
        match pkg.Description with
        | Some d -> "    <Description>" + xmlEscape d + "</Description>\n"
        | None   -> ""
    let licenseXml =
        match pkg.License with
        | Some l -> "    <PackageLicenseExpression>" + xmlEscape l + "</PackageLicenseExpression>\n"
        | None   -> ""
    let repoXml =
        match pkg.Repository with
        | Some r -> "    <RepositoryUrl>" + xmlEscape r + "</RepositoryUrl>\n"
        | None   -> ""
    let depsXml =
        manifest.Dependencies
        |> List.map (fun d ->
            sprintf "    <PackageReference Include=\"%s\" Version=\"%s\" />\n"
                    (xmlEscape d.Name) (xmlEscape d.Version))
        |> String.concat ""
    // Mark every dependency as a `lib`-folder reference so downstream
    // consumers transitively pick them up.  `IncludeAssets="all"` is
    // the default for `<PackageReference>`; we don't need to set it.
    let dllAbsolute = Path.GetFullPath dllPath
    let lines = ResizeArray<string>()
    lines.Add "<Project Sdk=\"Microsoft.NET.Sdk\">"
    lines.Add "  <PropertyGroup>"
    lines.Add "    <TargetFramework>net10.0</TargetFramework>"
    lines.Add "    <IncludeBuildOutput>false</IncludeBuildOutput>"
    lines.Add "    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>"
    lines.Add "    <NoWarn>$(NoWarn);NU5128</NoWarn>"
    lines.Add (sprintf "    <PackageId>%s</PackageId>" (xmlEscape sanitisedId))
    lines.Add (sprintf "    <Version>%s</Version>" (xmlEscape pkg.Version))
    let inlineNonEmpty (s: string) =
        if not (String.IsNullOrEmpty s) then lines.Add (s.TrimEnd '\n')
    inlineNonEmpty authorsXml
    inlineNonEmpty descriptionXml
    inlineNonEmpty licenseXml
    inlineNonEmpty repoXml
    lines.Add "  </PropertyGroup>"
    lines.Add "  <ItemGroup>"
    lines.Add (sprintf "    <None Include=\"%s\" Pack=\"true\" PackagePath=\"lib/net10.0/%s\" />"
                       (xmlEscape dllAbsolute) (xmlEscape assemblyFile))
    lines.Add "  </ItemGroup>"
    if not (String.IsNullOrEmpty depsXml) then
        lines.Add "  <ItemGroup>"
        lines.Add (depsXml.TrimEnd '\n')
        lines.Add "  </ItemGroup>"
    lines.Add "</Project>"
    String.concat "\n" lines + "\n"

/// Build the `.csproj` text used by `lyric restore`.  Declares only
/// the `<PackageReference>` items so `dotnet restore` populates the
/// NuGet cache with each dependency's full transitive closure.
let restoreCsproj (manifest: Manifest) : string =
    let depsXml =
        manifest.Dependencies
        |> List.map (fun d ->
            sprintf "    <PackageReference Include=\"%s\" Version=\"%s\" />\n"
                    (xmlEscape d.Name) (xmlEscape d.Version))
        |> String.concat ""
    let lines = ResizeArray<string>()
    lines.Add "<Project Sdk=\"Microsoft.NET.Sdk\">"
    lines.Add "  <PropertyGroup>"
    lines.Add "    <TargetFramework>net10.0</TargetFramework>"
    lines.Add (sprintf "    <PackageId>%s</PackageId>"
                       (xmlEscape (sanitisedPackageName manifest.Package.Name)))
    lines.Add (sprintf "    <Version>%s</Version>"
                       (xmlEscape manifest.Package.Version))
    lines.Add "    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>"
    lines.Add "    <IncludeBuildOutput>false</IncludeBuildOutput>"
    lines.Add "  </PropertyGroup>"
    lines.Add "  <ItemGroup>"
    if not (String.IsNullOrEmpty depsXml) then
        lines.Add (depsXml.TrimEnd '\n')
    lines.Add "  </ItemGroup>"
    lines.Add "</Project>"
    String.concat "\n" lines + "\n"

// ---------------------------------------------------------------------------
// Path conventions.
// ---------------------------------------------------------------------------

/// Default location of the user's pre-built DLL when the manifest
/// doesn't override.  Mirrors `lyric build`'s default of writing
/// `<source>.dll` next to the source: a single-source package keeps
/// the dll under `bin/<package>.dll` so multiple builds don't
/// collide on naming.
let defaultDllPath (manifest: Manifest) (manifestDir: string) : string =
    let name = sanitisedPackageName manifest.Package.Name
    Path.Combine(manifestDir, "bin", name + ".dll")

/// Default `dotnet pack` output directory.  Matches Cargo's `target/
/// package` convention: under the project, easy to gitignore.
let defaultPackOutputDir (manifest: Manifest) (manifestDir: string) : string =
    match manifest.Build.OutputDir with
    | Some o -> Path.Combine(manifestDir, o)
    | None   -> Path.Combine(manifestDir, "pkg")

/// Throw-away scratch directory for the generated `.csproj` (and
/// the `obj/` artefacts the pack/restore tooling drops alongside).
/// Sits under the repo's `.lyric/` cache so a single-line
/// `.gitignore` entry hides every per-invocation artefact.
let scratchProjectDir (manifest: Manifest) (manifestDir: string) (subdir: string) : string =
    let sanitised = sanitisedPackageName manifest.Package.Name
    let suffix = sprintf "%s-%s" sanitised subdir
    Path.Combine(manifestDir, ".lyric", suffix)

// ---------------------------------------------------------------------------
// Top-level entry points used by `Program.fs`.
// ---------------------------------------------------------------------------

/// Run `dotnet pack` against a freshly-generated `.csproj`.
/// `manifestPath` points at `lyric.toml`; `dllPath` is the pre-built
/// Lyric DLL; `outputDir` is where the `.nupkg` lands.  Returns the
/// `.nupkg` path on success, or an error tuple on failure.
let runPack (manifest: Manifest)
            (manifestDir: string)
            (dllPath: string)
            (outputDir: string)
            (quiet: bool) : Result<string, string> =
    if not (File.Exists dllPath) then
        Error (sprintf "publish: pre-built DLL '%s' not found — run `lyric build` first"
                       dllPath)
    else
    let scratch = scratchProjectDir manifest manifestDir "pack"
    Directory.CreateDirectory scratch |> ignore
    let csprojName = sanitisedPackageName manifest.Package.Name + ".csproj"
    let csprojPath = Path.Combine(scratch, csprojName)
    let csprojText = publishCsproj manifest dllPath
    File.WriteAllText(csprojPath, csprojText)
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
            sprintf "%s.%s.nupkg"
                    (sanitisedPackageName manifest.Package.Name)
                    manifest.Package.Version
        let nupkgPath = Path.Combine(outputDir, nupkgName)
        if File.Exists nupkgPath then Ok nupkgPath
        else
            // Fall back to scanning the dir — `dotnet pack` may have
            // emitted a slightly different name (e.g. when the
            // version string contains pre-release suffixes).
            let candidates =
                Directory.GetFiles(outputDir, "*.nupkg")
            match Array.tryHead candidates with
            | Some p -> Ok p
            | None -> Error "publish: dotnet pack succeeded but produced no .nupkg"

/// Run `dotnet restore` against a freshly-generated `.csproj`.
/// `manifestPath` points at `lyric.toml`.  Returns the dotnet exit
/// code so callers can propagate it up to the shell.
let runRestore (manifest: Manifest)
               (manifestDir: string)
               (quiet: bool) : Result<unit, string> =
    let scratch = scratchProjectDir manifest manifestDir "restore"
    Directory.CreateDirectory scratch |> ignore
    let csprojName = sanitisedPackageName manifest.Package.Name + ".csproj"
    let csprojPath = Path.Combine(scratch, csprojName)
    File.WriteAllText(csprojPath, restoreCsproj manifest)
    let result = runDotnet [ "restore"; csprojPath ] scratch quiet
    if result.ExitCode = 0 then Ok ()
    else
        let detail =
            if quiet then result.Stderr.Trim()
            else "(see dotnet restore output above)"
        Error (sprintf "restore: dotnet restore exited %d %s"
                       result.ExitCode detail)
