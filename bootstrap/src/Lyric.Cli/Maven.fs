/// Maven Central dependency resolution helpers for `[maven]` table
/// support (docs/31-maven-linking.md, D053).
///
/// This module provides:
///   - `lyricPackageName`: convert a Maven coordinate to a Lyric
///     package name (e.g. `com.fasterxml.jackson.core:jackson-databind`
///     → `ComFasterxmlJacksonCore.JacksonDatabind`).
///   - `userCacheDir`: cross-platform `$LYRIC_USER_CACHE` resolver.
///   - `findResolverJar`: locate `lyric-resolver.jar` in the SDK.
///   - `runMavenResolve`: invoke `lyric-resolver.jar` with a JSON
///     resolution request and parse its JSON response.
module Lyric.Cli.Maven

open System
open System.Diagnostics
open System.IO
open System.Text.Json

// ---------------------------------------------------------------------------
// Lyric package naming convention (docs/31-maven-linking.md §6)
// ---------------------------------------------------------------------------

/// Split a string on word-separator characters (`-`, `.`, `_`) and
/// PascalCase each resulting segment.  Empty segments (from adjacent
/// separators) are silently skipped.
let private pascalSegments (s: string) : string =
    let seps = [| '-'; '.'; '_' |]
    s.Split(seps, StringSplitOptions.RemoveEmptyEntries)
    |> Array.map (fun seg ->
        if seg.Length = 0 then ""
        else string (Char.ToUpperInvariant seg.[0]) + seg.[1..].ToLowerInvariant())
    |> String.concat ""

/// Derive the Lyric package name from a Maven coordinate.
///
/// Convention (D053 / docs/31-maven-linking.md §6):
///   group  segments (split on `.`) → concatenated PascalCase, no dots
///   artifact segments (split on `-`/`.`/`_`) → PascalCase joined
///   result → `<PascalGroup>.<PascalArtifact>`
///
/// Examples:
///   `com.fasterxml.jackson.core` + `jackson-databind`
///       → `ComFasterxmlJacksonCore.JacksonDatabind`
///   `org.slf4j` + `slf4j-api`
///       → `OrgSlf4j.Slf4jApi`
let lyricPackageName (group: string) (artifact: string) : string =
    let pascalGroup =
        group.Split('.')
        |> Array.map (fun seg ->
            if seg.Length = 0 then ""
            else string (Char.ToUpperInvariant seg.[0]) + seg.[1..])
        |> String.concat ""
    let pascalArtifact = pascalSegments artifact
    sprintf "%s.%s" pascalGroup pascalArtifact

// ---------------------------------------------------------------------------
// Cross-platform user cache directory
// ---------------------------------------------------------------------------

/// Resolve `$LYRIC_USER_CACHE` per docs/31-maven-linking.md §3.
///
/// Priority:
///   1. `LYRIC_USER_CACHE` env var (if set and non-empty).
///   2. Platform default:
///      - Windows : `%APPDATA%\lyric`
///      - POSIX   : `~/.lyric`
let userCacheDir () : string =
    let envVal = Environment.GetEnvironmentVariable "LYRIC_USER_CACHE"
    match Option.ofObj envVal with
    | Some v when v.Length > 0 -> v
    | _ ->
        if Environment.OSVersion.Platform = PlatformID.Win32NT then
            let appData = Environment.GetFolderPath Environment.SpecialFolder.ApplicationData
            Path.Combine(appData, "lyric")
        else
            Path.Combine(
                Environment.GetFolderPath Environment.SpecialFolder.UserProfile,
                ".lyric")

// ---------------------------------------------------------------------------
// Resolver JAR location (docs/22-distribution-and-tooling.md §3)
// ---------------------------------------------------------------------------

type ResolverLocateError =
    /// `LYRIC_SDK_ROOT` was set but the JAR doesn't exist there.
    | SdkRootMissingJar of sdkRoot: string
    /// No `lyric-resolver.jar` found in any standard location.
    | JarNotFound of searchedPaths: string list

/// Locate `lyric-resolver.jar` following the SDK lookup order from
/// docs/22-distribution-and-tooling.md §4.
///
/// Search order:
///   1. `$LYRIC_SDK_ROOT/lib/lyric-resolver.jar`
///   2. Walk up from the CLI binary's directory looking for
///      `lib/lyric-resolver.jar` (installed layout).
///   3. Walk up from the CLI binary's directory looking for
///      `resolver/target/lyric-resolver.jar` (source-tree layout).
let findResolverJar () : Result<string, ResolverLocateError> =
    let envSdkRoot = Environment.GetEnvironmentVariable "LYRIC_SDK_ROOT"
    match Option.ofObj envSdkRoot with
    | Some root when root.Length > 0 ->
        let candidate = Path.Combine(root, "lib", "lyric-resolver.jar")
        if File.Exists candidate then Ok candidate
        else Error (SdkRootMissingJar root)
    | _ ->
        let exeDir =
            let loc = System.Reflection.Assembly.GetExecutingAssembly().Location
            if loc.Length > 0 then
                match Option.ofObj (Path.GetDirectoryName loc) with
                | Some d -> d
                | None   -> Directory.GetCurrentDirectory()
            else Directory.GetCurrentDirectory()
        let maxDepth = 8
        let rec walkUp (dir: string) (depth: int) (tried: string list) =
            if depth = 0 then tried
            else
                let c1 = Path.Combine(dir, "lib", "lyric-resolver.jar")
                let c2 = Path.Combine(dir, "resolver", "target", "lyric-resolver.jar")
                if File.Exists c1 then [ c1 ]   // sentinel: non-empty means "found"
                elif File.Exists c2 then [ c2 ]
                else
                    match Option.ofObj (Path.GetDirectoryName dir) with
                    | None -> tried @ [c1; c2]
                    | Some parent when parent = dir -> tried @ [c1; c2]
                    | Some parent -> walkUp parent (depth - 1) (tried @ [c1; c2])
        let results = walkUp exeDir maxDepth []
        match results with
        | [ single ] when File.Exists single -> Ok single
        | candidates ->
            // If walkUp returned a sentinel (the found path), it's a single
            // existing file; otherwise it's the list of paths we tried.
            match candidates |> List.tryFind File.Exists with
            | Some p -> Ok p
            | None -> Error (JarNotFound candidates)

let renderLocateError (err: ResolverLocateError) : string =
    match err with
    | SdkRootMissingJar root ->
        sprintf
            "maven: LYRIC_SDK_ROOT='%s' but '%s/lib/lyric-resolver.jar' not found \
             (B0040)"
            root root
    | JarNotFound paths ->
        let tried = paths |> List.map (sprintf "  %s") |> String.concat "\n"
        sprintf
            "maven: lyric-resolver.jar not found; tried:\n%s\n\
             Install the Lyric SDK or set LYRIC_SDK_ROOT (B0040)"
            tried

// ---------------------------------------------------------------------------
// JSON protocol with lyric-resolver.jar (docs/31-maven-linking.md §3)
// ---------------------------------------------------------------------------

/// One coordinate to resolve.
type MavenCoordinate =
    { Group:    string
      Artifact: string
      Version:  string }

/// Request sent to `lyric-resolver.jar` as JSON via stdin.
type MavenResolveRequest =
    { Coordinates:   MavenCoordinate list
      /// Repository identifiers/URLs.  `"central"` is the shorthand.
      Repositories:  string list
      /// Java release target (e.g. `"21"`).
      JavaVersion:   string
      /// Where the resolver should cache downloaded artifacts.
      CacheDir:      string
      /// Where the resolver should copy the resolved JARs.
      OutputDir:     string }

/// One parameter of a Java method.
type JavaParam =
    { /// Parameter name as declared in the source (or `arg0`, `arg1`
      /// when bytecode doesn't carry names).
      Name:     string
      /// Java binary type name, e.g. `"java.lang.String"`,
      /// `"int"`, `"boolean"`, `"com.example.Foo"`.
      TypeName: string }

/// One public method from a Java class surface.
type JavaMethod =
    { Name:                 string
      Params:               JavaParam list
      ReturnType:           string
      IsStatic:             bool
      /// True when the method's `throws` clause lists at least one checked
      /// exception (i.e. not a subclass of RuntimeException or Error).
      /// When true, MavenShim wraps the return type in Result[T, JvmException].
      HasCheckedExceptions: bool }

/// Public surface of a single Java class as reported by the resolver.
type JavaClass =
    { /// Fully-qualified class name, e.g. `"com.example.Foo"`.
      ClassName: string
      Methods:   JavaMethod list }

/// One resolved JAR returned by the resolver.
type ResolvedMavenJar =
    { /// Maven coordinate that produced this JAR.
      Group:        string
      Artifact:     string
      Version:      string
      /// Absolute path to the JAR on disk (inside `OutputDir`).
      JarPath:      string
      /// SHA-256 hex digest of the JAR (verified by the resolver).
      Sha256:       string
      /// `true` iff this JAR was named directly in `[maven]`; `false`
      /// for transitive dependencies.
      IsTopLevel:   bool
      /// Public class surface extracted by the resolver.  Empty for
      /// transitive deps (the shim generator only processes top-level
      /// JARs); `None` when the resolver couldn't load the JAR's
      /// bytecode (e.g. a POM-only or native artifact).
      Classes:      JavaClass list option }

type MavenResolveError =
    | JavaNotFound
    | ResolverExitFailure of exitCode: int * stderr: string
    | ResolverOutputMalformed of detail: string

let renderResolveError (err: MavenResolveError) : string =
    match err with
    | JavaNotFound ->
        "maven: 'java' not found on PATH; a JRE is required for Maven \
         dependency resolution"
    | ResolverExitFailure (code, stderr) ->
        sprintf
            "maven: lyric-resolver.jar exited with code %d:\n%s"
            code stderr
    | ResolverOutputMalformed detail ->
        sprintf "maven: lyric-resolver.jar returned unexpected output: %s" detail

/// Find the `java` executable.
let private findJava () : string option =
    let envJava = Environment.GetEnvironmentVariable "JAVA_HOME"
    let candidates =
        [ match Option.ofObj envJava with
          | Some home when home.Length > 0 ->
              yield Path.Combine(home, "bin", "java")
              yield Path.Combine(home, "bin", "java.exe")
          | _ -> ()
          yield "java" ]
    candidates |> List.tryFind (fun j ->
        try
            let psi = ProcessStartInfo(j, "-version")
            psi.UseShellExecute <- false
            psi.RedirectStandardError <- true
            psi.RedirectStandardOutput <- true
            psi.CreateNoWindow <- true
            match Option.ofObj (Process.Start psi) with
            | None -> false
            | Some p ->
                use _ = p
                p.WaitForExit(3000) |> ignore
                p.ExitCode = 0
        with _ -> false)

/// Serialise a `MavenResolveRequest` to the JSON wire format expected by
/// `lyric-resolver.jar`.
let private serializeRequest (req: MavenResolveRequest) : string =
    use ms = new System.IO.MemoryStream()
    use w = new Utf8JsonWriter(ms, JsonWriterOptions(Indented = false))
    w.WriteStartObject()
    w.WriteStartArray("coordinates")
    for c in req.Coordinates do
        w.WriteStartObject()
        w.WriteString("group", c.Group)
        w.WriteString("artifact", c.Artifact)
        w.WriteString("version", c.Version)
        w.WriteEndObject()
    w.WriteEndArray()
    w.WriteStartArray("repositories")
    for r in req.Repositories do w.WriteStringValue r
    w.WriteEndArray()
    w.WriteString("javaVersion", req.JavaVersion)
    w.WriteString("cacheDir", req.CacheDir)
    w.WriteString("outputDir", req.OutputDir)
    w.WriteEndObject()
    w.Flush()
    System.Text.Encoding.UTF8.GetString(ms.ToArray())

/// Parse a `classes` JSON array from the resolver response into `JavaClass list`.
let private parseClasses (classesEl: JsonElement) : JavaClass list =
    [ for cls in classesEl.EnumerateArray() do
        let mutable clsName = Unchecked.defaultof<JsonElement>
        let mutable methodsEl = Unchecked.defaultof<JsonElement>
        if cls.TryGetProperty("className", &clsName)
           && cls.TryGetProperty("methods", &methodsEl) then
            let methods =
                [ for m in methodsEl.EnumerateArray() do
                    let get (name: string) =
                        let mutable p = Unchecked.defaultof<JsonElement>
                        if m.TryGetProperty(name, &p) then Option.ofObj (p.GetString())
                        else None
                    let getBool (name: string) =
                        let mutable p = Unchecked.defaultof<JsonElement>
                        if m.TryGetProperty(name, &p) then p.GetBoolean()
                        else false
                    let mutable paramsEl = Unchecked.defaultof<JsonElement>
                    let ps =
                        if m.TryGetProperty("params", &paramsEl) then
                            [ for param in paramsEl.EnumerateArray() do
                                let getName () =
                                    let mutable pn = Unchecked.defaultof<JsonElement>
                                    if param.TryGetProperty("name", &pn) then Option.ofObj (pn.GetString())
                                    else None
                                let getType () =
                                    let mutable pt = Unchecked.defaultof<JsonElement>
                                    if param.TryGetProperty("typeName", &pt) then Option.ofObj (pt.GetString())
                                    else None
                                match getName (), getType () with
                                | Some pname, Some ptype ->
                                    yield { Name = pname; TypeName = ptype }
                                | _ -> () ]
                        else []
                    match get "name", get "returnType" with
                    | Some mname, Some ret ->
                        yield { Name = mname; Params = ps
                                ReturnType = ret; IsStatic = getBool "isStatic"
                                HasCheckedExceptions = getBool "hasCheckedExceptions" }
                    | _ -> () ]
            match Option.ofObj (clsName.GetString()) with
            | Some cn -> yield { ClassName = cn; Methods = methods }
            | None -> () ]

/// Parse the JSON array returned by `lyric-resolver.jar`.
let private parseResponse (json: string) : Result<ResolvedMavenJar list, MavenResolveError> =
    try
        use doc = JsonDocument.Parse json
        let root = doc.RootElement
        if root.ValueKind <> JsonValueKind.Array then
            Error (ResolverOutputMalformed "expected a JSON array at root")
        else
            let results = ResizeArray<ResolvedMavenJar>()
            let mutable err : string option = None
            for el in root.EnumerateArray() do
                if err.IsNone then
                    let get (name: string) =
                        let mutable prop = Unchecked.defaultof<JsonElement>
                        if el.TryGetProperty(name, &prop) then Option.ofObj (prop.GetString())
                        else None
                    let getBool (name: string) =
                        let mutable prop = Unchecked.defaultof<JsonElement>
                        if el.TryGetProperty(name, &prop) then prop.GetBoolean()
                        else false
                    let mutable classesEl = Unchecked.defaultof<JsonElement>
                    let classesOpt =
                        if el.TryGetProperty("classes", &classesEl)
                           && classesEl.ValueKind = JsonValueKind.Array then
                            Some (parseClasses classesEl)
                        else None
                    match get "group", get "artifact", get "version",
                          get "jarPath", get "sha256" with
                    | Some grp, Some art, Some ver, Some path, Some sha ->
                        results.Add
                            { Group      = grp
                              Artifact   = art
                              Version    = ver
                              JarPath    = path
                              Sha256     = sha
                              IsTopLevel = getBool "isTopLevel"
                              Classes    = classesOpt }
                    | _ ->
                        err <- Some (sprintf "element missing required fields: %s" (el.ToString()))
            match err with
            | Some e -> Error (ResolverOutputMalformed e)
            | None -> Ok (List.ofSeq results)
    with ex ->
        Error (ResolverOutputMalformed (ex.Message))

/// Invoke `lyric-resolver.jar` with the given request, collect results.
///
/// The resolver reads the serialised `MavenResolveRequest` JSON from
/// stdin and writes a JSON array of `ResolvedMavenJar` objects to
/// stdout.  Errors are written to stderr with a non-zero exit code.
let runMavenResolve
        (jarPath:  string)
        (req:      MavenResolveRequest)
        (quiet:    bool)
        : Result<ResolvedMavenJar list, MavenResolveError> =
    match findJava () with
    | None -> Error JavaNotFound
    | Some java ->
        let psi = ProcessStartInfo()
        psi.FileName <- java
        psi.ArgumentList.Add "-jar"
        psi.ArgumentList.Add jarPath
        psi.UseShellExecute <- false
        psi.RedirectStandardInput <- true
        psi.RedirectStandardOutput <- true
        psi.RedirectStandardError <- true
        psi.CreateNoWindow <- true
        let proc =
            match Option.ofObj (Process.Start psi) with
            | Some p -> p
            | None -> failwith "lyric: failed to start java"
        use _ = proc
        let input = serializeRequest req
        proc.StandardInput.Write input
        proc.StandardInput.Close()
        let stdout = proc.StandardOutput.ReadToEnd()
        let stderr = proc.StandardError.ReadToEnd()
        proc.WaitForExit()
        if not quiet && stderr.Length > 0 then
            eprintfn "%s" stderr
        if proc.ExitCode <> 0 then
            Error (ResolverExitFailure (proc.ExitCode, stderr))
        else
            parseResponse stdout
