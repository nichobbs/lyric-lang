/// Walker for `project.assets.json` (Phase 5 §M5.1 stage 2d.v).
///
/// `dotnet restore` writes `<scratch>/obj/project.assets.json`
/// listing the full resolved NuGet graph: every transitive
/// dependency, the exact `lib/<tfm>/<file>.dll` it picked, and the
/// cache-relative path of each package.  This module turns that JSON
/// into an `AssetsResolution` record the rest of the build flow
/// consumes — both restore (for shim generation) and build (for
/// emitter assembly-load + `.deps.json` emission).
///
/// Reading the assets file is more work than the heuristic
/// `tryLocateNugetDll` cache walker in `NugetShim.fs`, but it's the
/// only way to get correctness for transitive deps and to agree
/// with `dotnet restore`'s own choice when a package ships several
/// compatible TFMs (e.g. `net6.0` + `net8.0` + `netstandard2.0`).
/// Without the assets file, build-time symbol resolution and
/// runtime DLL probing can disagree, producing "type X is missing
/// at runtime" failures after a clean compile.
module Lyric.Cli.NugetAssets

open System
open System.IO
open System.Text.Json

/// One package + DLL pair resolved by `dotnet restore`.  `IsTopLevel`
/// distinguishes packages the user named directly in `[nuget]` from
/// transitive deps; the shim generator only emits `_extern/<pkg>.l`
/// for top-level packages, but every DLL (top-level + transitive)
/// joins the emitter's assembly-load set and the output `.deps.json`.
type ResolvedNugetPackage =
    { Id:           string
      Version:      string
      /// Absolute path to the `compile` (build-time reference) DLL.
      CompileDll:   string
      /// Absolute path to the `runtime` DLL (often the same file).
      RuntimeDll:   string
      /// `true` iff the user wrote this package id in `[nuget]`.
      IsTopLevel:   bool }

/// What the assets walker returns to the caller.
type AssetsResolution =
    { Packages:     ResolvedNugetPackage list
      /// Target framework `dotnet restore` resolved against
      /// (e.g. `"net10.0"`).  Surface for the consumer's `.deps.json`
      /// runtime block.
      TargetMoniker: string }

type AssetsError =
    | AssetsFileMissing  of path: string
    | AssetsParseError   of path: string * detail: string
    | AssetsShapeError   of path: string * detail: string

let renderError (err: AssetsError) : string =
    match err with
    | AssetsFileMissing p ->
        sprintf
            "assets: '%s' not found — run `lyric restore` against \
             a manifest with `[nuget]` first"
            p
    | AssetsParseError (p, d) ->
        sprintf "assets: '%s' parse failed: %s" p d
    | AssetsShapeError (p, d) ->
        sprintf "assets: '%s' shape unexpected: %s" p d

let private nugetCacheRoot () : string =
    match Option.ofObj (Environment.GetEnvironmentVariable "NUGET_PACKAGES") with
    | Some p -> p
    | None ->
        Path.Combine(
            Environment.GetFolderPath Environment.SpecialFolder.UserProfile,
            ".nuget", "packages")

/// Read `<scratchDir>/obj/project.assets.json` (or the explicit
/// path given) and translate it into an `AssetsResolution`.
/// `topLevelIds` is the user's `[nuget]` set (the keys of
/// `manifest.Nuget.Packages`); transitive deps are detected as
/// "in `targets` but not in `topLevelIds`".
let read
        (assetsPath: string)
        (topLevelIds: Set<string>)
        : Result<AssetsResolution, AssetsError> =
    if not (File.Exists assetsPath) then
        Error (AssetsFileMissing assetsPath)
    else
    let bytes =
        try Ok (File.ReadAllBytes assetsPath)
        with ex -> Error (AssetsParseError (assetsPath, ex.Message))
    match bytes with
    | Error e -> Error e
    | Ok bytes ->
    let doc =
        try Ok (JsonDocument.Parse(ReadOnlyMemory(bytes)))
        with
        | :? JsonException as ex ->
            Error (AssetsParseError (assetsPath, ex.Message))
        | ex ->
            Error (AssetsParseError (assetsPath, ex.Message))
    match doc with
    | Error e -> Error e
    | Ok doc ->
    use _ = doc
    let root = doc.RootElement
    // Pull the single `targets.<tfm>` block.  `dotnet restore` always
    // emits exactly one TFM (the one we asked for in the csproj).
    let targets =
        try root.GetProperty "targets" |> Some
        with _ -> None
    let libraries =
        try root.GetProperty "libraries" |> Some
        with _ -> None
    match targets, libraries with
    | None, _ | _, None ->
        Error (AssetsShapeError (assetsPath, "missing `targets` or `libraries`"))
    | Some targetsEl, Some librariesEl ->

    let mutable tfmKv = Unchecked.defaultof<JsonProperty>
    let mutable tfmFound = false
    for kv in targetsEl.EnumerateObject() do
        if not tfmFound then
            tfmKv <- kv
            tfmFound <- true
    if not tfmFound then
        Error (AssetsShapeError (assetsPath, "no TFM in `targets`"))
    else

    let tfm = tfmKv.Name
    let tfmEl = tfmKv.Value

    // Walk libraries to build a `<id>/<ver> -> cache-relative-path` map.
    let libPaths =
        let acc = System.Collections.Generic.Dictionary<string, string>()
        for kv in librariesEl.EnumerateObject() do
            let key = kv.Name      // "<id>/<ver>"
            try
                let pathEl = kv.Value.GetProperty "path"
                match Option.ofObj (pathEl.GetString()) with
                | Some p -> acc.[key] <- p
                | None   -> ()
            with _ ->
                ()  // skip libraries without a `path` (unusual)
        acc

    let cacheRoot = nugetCacheRoot ()

    // For each package in `targets[<tfm>]`, pull `compile` and
    // `runtime` first-key DLL paths.
    let pkgs = ResizeArray<ResolvedNugetPackage>()
    let mutable shapeErr : string option = None
    for kv in tfmEl.EnumerateObject() do
        if shapeErr.IsNone then
            let key = kv.Name      // "<id>/<ver>"
            let parts = key.Split('/')
            if parts.Length <> 2 then
                shapeErr <- Some (sprintf "package key '%s' is not <id>/<ver>" key)
            else
            let id = parts.[0]
            let version = parts.[1]
            // The `package`/`project` distinction matters: only
            // `package` entries live in the NuGet cache.  `project`
            // entries point at sibling csprojs; not relevant for
            // Lyric's flow.
            let isPackage =
                try
                    kv.Value.GetProperty "type"
                    |> fun e -> e.GetString() = "package"
                with _ -> false
            if isPackage then
                let firstKey (block: JsonElement) : string option =
                    let mutable found : string option = None
                    let mutable enumerator = block.EnumerateObject()
                    while found.IsNone && enumerator.MoveNext() do
                        let prop = enumerator.Current
                        // Skip `_._` placeholder entries — the
                        // dotnet tooling uses them to mean "no real
                        // file, the package is a meta-ref."
                        if prop.Name <> "_._" then
                            found <- Some prop.Name
                    found
                let compileRel =
                    try
                        kv.Value.GetProperty "compile"
                        |> firstKey
                    with _ -> None
                let runtimeRel =
                    try
                        kv.Value.GetProperty "runtime"
                        |> firstKey
                    with _ -> None
                // A package without a `compile` entry usually means
                // "compile-only" assets (analyzers, build targets);
                // skip it silently.
                match compileRel with
                | None -> ()
                | Some compileRel ->
                let basePath =
                    match libPaths.TryGetValue key with
                    | true, p  -> p
                    | false, _ -> id.ToLowerInvariant() + "/" + version
                let absRoot = Path.Combine(cacheRoot, basePath)
                let compileAbs = Path.Combine(absRoot, compileRel)
                let runtimeAbs =
                    match runtimeRel with
                    | Some r -> Path.Combine(absRoot, r)
                    | None   -> compileAbs
                pkgs.Add
                    { Id          = id
                      Version     = version
                      CompileDll  = compileAbs
                      RuntimeDll  = runtimeAbs
                      IsTopLevel  = topLevelIds.Contains id }

    match shapeErr with
    | Some e -> Error (AssetsShapeError (assetsPath, e))
    | None ->
        Ok { Packages      = List.ofSeq pkgs
             TargetMoniker = tfm }

/// Convenience wrapper: locate `project.assets.json` under the
/// scratch dir `lyric.toml`'s `runRestore` writes against, and
/// delegate to `read`.
let readForManifest
        (manifestDir: string)
        (manifest: Lyric.Cli.Manifest.Manifest)
        : Result<AssetsResolution, AssetsError> =
    let scratch =
        Lyric.Cli.Pack.scratchProjectDir manifest manifestDir "restore"
    let assetsPath = Path.Combine(scratch, "obj", "project.assets.json")
    let topLevelIds =
        match manifest.Nuget with
        | None   -> Set.empty
        | Some n -> n.Packages |> List.map (fun p -> p.Id) |> Set.ofList
    read assetsPath topLevelIds
