/// Auto-generated `extern type` / `@externTarget` shims for NuGet
/// packages (Phase 5 §M5.1 stage 2d.iii per `docs/21-nuget-linking.md`
/// §4).
///
/// This is the second half of the NuGet path: stage 2d.ii extended
/// `lyric restore` to feed `[nuget]` entries into `dotnet restore`,
/// populating the local NuGet cache.  Stage 2d.iii reflects over each
/// restored DLL's public surface and writes a Lyric source file
/// (`_extern/<lyric-pkg-name>.l`) plus a skip report
/// (`_extern/<lyric-pkg-name>.skip.md`) to the manifest directory.
///
/// The generator's design tracks `docs/21` §4 closely:
///
///   - **Every shim carries `@axiom("from NuGet package <id> v<ver>")`.**
///     This is the auditable annotation that distinguishes verified
///     Lyric code from the unverified host surface.  Hand-written
///     `_kernel/*.l` files use the same scheme.
///   - **Files are committed to the source tree** so reviewers see
///     the surface that will be in scope.  The generator is
///     deterministic (sorted output, locked to the package version).
///   - **Skipped surface is reported** in `_extern/<pkg>.skip.md`
///     with a short reason — visible in code review.
///   - **Lyric-keyword collisions** are renamed to `name_` and the
///     skip report records the rename.
///
/// Bootstrap-grade scope (intentional cuts, expanded in follow-ups):
///   - **No generic methods.**  `JsonSerializer.Serialize[T](T)`
///     becomes a skip entry with reason `"generic method"`.  The
///     spec mentions `pub func serialize[T](...)` as the eventual
///     shape; emitting parametric externs awaits the emitter's
///     monomorphisation hooks for FFI.
///   - **No nested types.**  `JsonValueKind` etc. are skipped at
///     this layer.
///   - **No instance method receivers — yet.**  Static methods only
///     in stage 2d.iii.  Instance methods land in 2d.iii.b once the
///     receiver-as-first-param shape is exercised against the
///     reflection-driven FFI path.
///   - **Translatable type set** is the BCL primitives plus the
///     types this package itself exports.  `slice[T]`, arrays,
///     ref / out / Span<T>, generic containers, and pointers are
///     all skip reasons.
module Lyric.Cli.NugetShim

open System
open System.Collections.Generic
open System.IO
open System.Reflection
open System.Reflection.PortableExecutable
open System.Reflection.Metadata
open System.Text

/// One generated shim file's contents plus a side-channel skip
/// report.  Both come back as strings so the caller decides where
/// to write them; tests can assert against the shape directly.
type ShimFile =
    { /// `<manifest-dir>/_extern/<lyric-pkg-name>.l` content.
      LyricSource:    string
      /// `<manifest-dir>/_extern/<lyric-pkg-name>.skip.md` content,
      /// or `None` when the entire surface translated cleanly.
      SkipReport:     string option
      /// Lyric package name derived from the NuGet id per §5.
      LyricPackage:   string
      /// Counts useful for the CLI's restore-progress message.
      ExternTypes:    int
      ExternMethods:  int
      SkippedMembers: int }

/// Errors that can stop generation early.  The DLL might be unreadable
/// (corrupt PE, wrong runtime), missing entirely, or refuse to surface
/// types via `MetadataLoadContext` (very rare; usually a sign the
/// runtime closure passed to the loader is incomplete).
type ShimError =
    | ShimDllMissing      of path: string
    | ShimDllUnreadable   of path: string * detail: string
    | ShimReflectionError of path: string * detail: string

let renderShimError (err: ShimError) : string =
    match err with
    | ShimDllMissing p ->
        sprintf "shim: '%s' not found (run `lyric restore` first)" p
    | ShimDllUnreadable (p, d) ->
        sprintf "shim: '%s' unreadable: %s" p d
    | ShimReflectionError (p, d) ->
        sprintf "shim: '%s' reflection failed: %s" p d

// ---------------------------------------------------------------------------
// NuGet cache locator.
// ---------------------------------------------------------------------------

/// TFM compatibility fallback chain: when a NuGet package doesn't
/// ship `lib/<requested-target>/`, work down through compatible
/// frameworks the .NET runtime is happy to load against.  This is
/// the .NET tooling's own NuGet-fallback ordering, conservatively
/// truncated to the modern .NET / .NET Standard heads.  Reading
/// `project.assets.json` would be more authoritative but doesn't
/// gain enough over this heuristic for the bootstrap.
let private tfmFallbackChain (target: string) : string list =
    // Numeric-suffix order for `net<X>.0`: try the requested TFM,
    // then walk down monotonically.  The string match keeps things
    // deterministic without heavyweight version parsing.
    let modernNets =
        [ "net10.0"; "net9.0"; "net8.0"; "net7.0"; "net6.0"; "net5.0" ]
    let netCoreApps =
        [ "netcoreapp3.1"; "netcoreapp3.0"; "netcoreapp2.1" ]
    let netStandards =
        [ "netstandard2.1"; "netstandard2.0"; "netstandard1.6"
          "netstandard1.5"; "netstandard1.4"; "netstandard1.3"
          "netstandard1.2"; "netstandard1.1"; "netstandard1.0" ]
    let tail =
        if target.StartsWith "netstandard" then netStandards
        elif target.StartsWith "netcoreapp" then netCoreApps @ netStandards
        else modernNets @ netCoreApps @ netStandards
    target :: (tail |> List.filter (fun t -> t <> target))

/// Probe the standard NuGet cache for a restored package's primary
/// DLL.  Tries the requested TFM first, then walks the compatibility
/// fallback chain (`lib/net9.0`, `lib/net8.0`, …, `lib/netstandard2.0`,
/// …) and finally `ref/<tfm>/`.  Within each `lib/<tfm>/` directory
/// the locator prefers `<id>.dll`; if absent, the first DLL in
/// alphabetical order — meta-packages occasionally ship content
/// whose file name doesn't match the package id, but reflection
/// works regardless.  Returns `None` if nothing matches — the
/// caller surfaces a B0030-flavoured diagnostic.
let tryLocateNugetDll (packageId: string) (version: string)
                      (target: string) : string option =
    let nugetRoot =
        match Option.ofObj (Environment.GetEnvironmentVariable "NUGET_PACKAGES") with
        | Some p -> p
        | None ->
            Path.Combine(
                Environment.GetFolderPath Environment.SpecialFolder.UserProfile,
                ".nuget", "packages")
    let pkgLower = packageId.ToLowerInvariant()
    let baseDir = Path.Combine(nugetRoot, pkgLower, version)
    let probe (kind: string) (tfm: string) : string option =
        let dir = Path.Combine(baseDir, kind, tfm)
        if not (Directory.Exists dir) then None
        else
            let preferred = Path.Combine(dir, packageId + ".dll")
            if File.Exists preferred then Some preferred
            else
                Directory.GetFiles(dir, "*.dll")
                |> Array.sort
                |> Array.tryHead
    let chain = tfmFallbackChain target
    chain
    |> List.tryPick (probe "lib")
    |> Option.orElseWith (fun () ->
        chain |> List.tryPick (probe "ref"))

// ---------------------------------------------------------------------------
// Lyric naming conventions.
// ---------------------------------------------------------------------------

/// `System.Text.Json` -> `SystemTextJson`.  Preserves casing.
/// `polly` -> `Polly` (capitalises a leading lowercase letter).
let lyricNameFromNugetId (nugetId: string) : string =
    let nodots = nugetId.Replace(".", "")
    if nodots.Length = 0 then nodots
    elif Char.IsLower nodots.[0] then
        string (Char.ToUpperInvariant nodots.[0]) + nodots.Substring 1
    else
        nodots

/// Lyric reserved words — anything matching one of these is
/// rewritten to `<name>_` per `docs/21` §4.  This is intentionally
/// the conservative superset of the actual keyword tables in
/// `compiler/src/Lyric.Lexer/Keywords.fs`; missing one just means a
/// generated function name keeps a CLR-y feel, missing nothing means
/// no false collisions can break parsing.
let private lyricKeywords =
    Set.ofList [
        "package"; "import"; "pub"; "internal"; "func"; "let"; "val"
        "if"; "else"; "match"; "for"; "while"; "return"; "break"; "continue"
        "type"; "alias"; "record"; "union"; "interface"; "enum"; "extern"
        "in"; "out"; "inout"; "self"; "this"; "true"; "false"; "null"
        "and"; "or"; "not"; "as"; "where"; "with"; "try"; "catch"; "finally"
        "throw"; "panic"; "assert"; "expect"; "do"; "yield"; "lazy"; "case"
        "is"; "new"; "ref"; "default"; "async"; "await"; "wire"; "spawn"
        "protected"; "shared"; "task"; "channel"; "barrier"; "axiom"
        "requires"; "ensures"; "invariant"; "module"; "of"; "when"; "from"
    ]

let private maybeRename (name: string) : string * bool =
    if Set.contains name lyricKeywords then (name + "_", true)
    else (name, false)

// ---------------------------------------------------------------------------
// CLR -> Lyric type mapping.
// ---------------------------------------------------------------------------

/// Maps a `System.Type` from a `MetadataLoadContext` to a Lyric type
/// spelling.  Returns `Error reason` for any type the bootstrap shim
/// generator can't safely translate; the caller turns it into a
/// skip entry with that reason.
///
/// `knownExternTypes` is the set of full CLR names the shim is about
/// to declare via `extern type` — references between two types in
/// the same package resolve through this map.
let private mapClrType
        (t: Type)
        (knownExternTypes: Map<string, string>)
        : Result<string, string> =
    // `MetadataLoadContext`-loaded `Type` properties throw when the
    // referenced type isn't in the load closure (a third-party
    // package referencing a runtime type we forgot to feed).  Wrap
    // every property access defensively so a bad reference becomes
    // a clean skip reason instead of an unhandled exception.
    try
        if t.IsByRef then Error "by-ref parameter"
        elif t.IsPointer then Error "pointer parameter"
        elif t.ContainsGenericParameters then Error "open generic"
        elif t.IsGenericType then Error "generic type"
        elif t.IsArray then Error "array type"
        elif t.IsNested then Error "nested type"
        else
            let full =
                match Option.ofObj t.FullName with
                | Some f -> f
                | None   -> ""
            match full with
            | "System.Boolean" -> Ok "Bool"
            | "System.Byte"    -> Ok "Byte"
            | "System.Int32"   -> Ok "Int"
            | "System.Int64"   -> Ok "Long"
            | "System.UInt32"  -> Ok "UInt"
            | "System.UInt64"  -> Ok "ULong"
            | "System.Single"  -> Ok "Float"
            | "System.Double"  -> Ok "Double"
            | "System.Char"    -> Ok "Char"
            | "System.String"  -> Ok "String"
            | "System.Void"    -> Ok "Unit"
            | "" ->
                Error "anonymous / open generic type"
            | _ ->
                match Map.tryFind full knownExternTypes with
                | Some lyricName -> Ok lyricName
                | None -> Error (sprintf "type %s not translatable" full)
    with ex ->
        Error (sprintf "reflection failure: %s" ex.Message)

// ---------------------------------------------------------------------------
// MetadataLoadContext setup.
// ---------------------------------------------------------------------------

/// Build a list of CLR runtime DLL paths that `MetadataLoadContext`
/// uses to resolve referenced assemblies (`mscorlib`, `System.Runtime`,
/// etc.).  Failing to include the runtime closure yields cryptic
/// `FileNotFoundException`s during reflection; we feed
/// `RuntimeEnvironment.GetRuntimeDirectory()` plus the user's NuGet
/// directory so referenced types resolve cleanly.
let private buildResolverPaths
        (mainDll: string)
        (extraSearchDirs: string list)
        : string list =
    let runtimeDir =
        System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory()
    let runtimeDlls =
        if Directory.Exists runtimeDir then
            Directory.GetFiles(runtimeDir, "*.dll") |> Array.toList
        else []
    let extraDlls =
        extraSearchDirs
        |> List.collect (fun d ->
            if Directory.Exists d then
                Directory.GetFiles(d, "*.dll") |> Array.toList
            else [])
    mainDll :: runtimeDlls @ extraDlls
    |> List.distinct

// ---------------------------------------------------------------------------
// Top-level generator.
// ---------------------------------------------------------------------------

/// Generate the shim source + skip report for a single restored
/// NuGet package.  `dllPath` is the materialised assembly; `nugetId`
/// is the package id from `[nuget]`; `version` is the same.
/// `extraSearchDirs` should include other restored DLLs the package
/// might reference — usually the project's NuGet cache directory.
let generate
        (dllPath: string)
        (nugetId: string)
        (version: string)
        (extraSearchDirs: string list)
        : Result<ShimFile, ShimError> =
    if not (File.Exists dllPath) then Error (ShimDllMissing dllPath)
    else
    let resolverPaths = buildResolverPaths dllPath extraSearchDirs
    let resolver =
        new System.Reflection.PathAssemblyResolver(resolverPaths)
    use mlc = new MetadataLoadContext(resolver)
    let asm =
        try mlc.LoadFromAssemblyPath dllPath |> Ok
        with
        | :? FileNotFoundException as ex ->
            let p =
                match Option.ofObj ex.FileName with
                | Some f -> f
                | None   -> dllPath
            Error (ShimDllMissing p)
        | :? BadImageFormatException as ex ->
            Error (ShimDllUnreadable (dllPath, ex.Message))
        | ex ->
            Error (ShimReflectionError (dllPath, ex.Message))
    match asm with
    | Error e -> Error e
    | Ok asm ->
    let allTypes =
        try asm.GetTypes() |> Ok
        with
        | :? ReflectionTypeLoadException as ex ->
            // Partial loads are still useful; keep the types we got.
            ex.Types
            |> Array.choose Option.ofObj
            |> Ok
        | ex ->
            Error (ShimReflectionError (dllPath, ex.Message))
    match allTypes with
    | Error e -> Error e
    | Ok types ->
    // Reflection metadata strings (`Type.FullName`, `Type.Name`,
    // `MethodInfo.Name`, `ParameterInfo.Name`) are nullable in F#'s
    // nullness model — `Type.FullName` is null for open generic
    // parameter types, anonymous types, and a few other exotic
    // shapes the shim generator wouldn't translate anyway.
    // Centralise the coercion and use it as a guard.
    let nz (s: string | null) (fallback: string) : string =
        match Option.ofObj s with
        | Some v -> v
        | None   -> fallback
    let typeFullName (t: Type) : string option = Option.ofObj t.FullName
    let publicTypes =
        types
        |> Array.filter (fun t ->
            t.IsPublic
            && not t.IsNested
            && not t.IsGenericTypeDefinition
            && not t.ContainsGenericParameters
            && (typeFullName t).IsSome)
        |> Array.sortBy (fun t -> nz t.FullName "")

    // Map full CLR name -> Lyric (simple) name.  Used during method
    // signature mapping to allow self-references between types in
    // the same package.  Simple names that collide across namespaces
    // (e.g. `Newtonsoft.Json.Linq.Extensions` and
    // `Newtonsoft.Json.Schema.Extensions`) get a deterministic
    // namespace-tail prefix so each Lyric `extern type` declares a
    // unique name; the F# bootstrap parser refuses duplicate type
    // declarations.
    let externTypeMap =
        let candidates =
            publicTypes
            |> Array.choose (fun t ->
                match typeFullName t with
                | Some full -> Some (t, full, nz t.Name "")
                | None      -> None)
        // Group simple-name collisions and disambiguate the second+
        // entries by prefixing each with the last namespace segment
        // of its full name (e.g. `Linq_Extensions`).  The first
        // entry stays unprefixed for ergonomic parity with the
        // common case (simple names usually unique).
        let buckets =
            candidates
            |> Array.groupBy (fun (_, _, simple) -> simple)
        let acc = System.Collections.Generic.Dictionary<string, string>()
        for (_, members) in buckets do
            for (i, (_, full, simple)) in Array.indexed members do
                let lyricName =
                    if i = 0 then simple
                    else
                        // Pull the last namespace segment as a prefix.
                        // `Newtonsoft.Json.Linq.Extensions` ->
                        // `Linq_Extensions`.  Falls back to a
                        // numeric suffix when the full name has no
                        // distinguishable tail.
                        let dotIdx = full.LastIndexOf('.')
                        if dotIdx <= 0 then simple + "_" + string i
                        else
                            let beforeDot = full.Substring(0, dotIdx)
                            let nsTail =
                                let idx = beforeDot.LastIndexOf('.')
                                if idx >= 0 then beforeDot.Substring(idx + 1)
                                else beforeDot
                            nsTail + "_" + simple
                acc.[full] <- lyricName
        acc
        |> Seq.map (fun kv -> kv.Key, kv.Value)
        |> Map.ofSeq

    let lyricPkg = lyricNameFromNugetId nugetId
    let sb = StringBuilder()
    let skipBuf = StringBuilder()
    let mutable skipped = 0
    let mutable methodCount = 0

    let recordSkip (path: string) (reason: string) =
        if skipped = 0 then
            skipBuf.AppendLine
                (sprintf "# Skipped surface for %s v%s" nugetId version)
                |> ignore
            skipBuf.AppendLine "" |> ignore
            skipBuf.AppendLine "Members not translatable to Lyric \
                               (reflection-driven shim generator):" |> ignore
            skipBuf.AppendLine "" |> ignore
        skipped <- skipped + 1
        skipBuf.AppendLine (sprintf "- `%s` — %s" path reason) |> ignore

    sb.AppendLine
        (sprintf "@axiom(\"from NuGet package %s v%s\")" nugetId version)
        |> ignore
    sb.AppendLine (sprintf "package %s" lyricPkg) |> ignore
    sb.AppendLine "" |> ignore
    sb.AppendLine "// Auto-generated by `lyric restore` — do not edit \
                  by hand." |> ignore
    sb.AppendLine "// Re-running restore overwrites this file." |> ignore
    sb.AppendLine "" |> ignore

    if Array.isEmpty publicTypes then
        sb.AppendLine "// No public types in this package's primary \
                      assembly." |> ignore
    else
        for t in publicTypes do
            let full = nz t.FullName ""
            let lyricName =
                match Map.tryFind full externTypeMap with
                | Some n -> n
                | None   -> nz t.Name ""
            sb.AppendLine
                (sprintf "extern type %s = \"%s\"" lyricName full)
                |> ignore
        sb.AppendLine "" |> ignore

    // Emit static methods only in this stage.  Instance methods +
    // ctors land in 2d.iii.b.  `MetadataLoadContext`-loaded methods
    // can throw when their signature references types unresolvable
    // in the current resolver — wrap defensively, treating any
    // throw as "skip this method with reason" rather than aborting
    // the whole shim.
    let safeGetMethods (t: Type) : MethodInfo array =
        try
            t.GetMethods(BindingFlags.Public ||| BindingFlags.Static
                         ||| BindingFlags.DeclaredOnly)
        with _ -> [||]
    let safeGetParams (m: MethodInfo) : ParameterInfo array option =
        try Some (m.GetParameters())
        with _ -> None
    let safeReturnType (m: MethodInfo) : Type option =
        try Some m.ReturnType
        with _ -> None
    // Method name disambiguation across types is handled by always
    // prefixing the emitted Lyric function with its owner type's
    // Lyric name — `JArray.Load` becomes `JArray_Load`, `JObject.Load`
    // becomes `JObject_Load`.  Lyric supports overload-by-arity but
    // not by parameter type, and free functions in the package's
    // top-level scope can't share a name regardless of arity, so a
    // mechanical rename keeps the surface flat without collisions.
    let globalSeen = HashSet<string * int>()
    for t in publicTypes do
        let tFull = nz t.FullName ""
        let typeLyricName =
            match Map.tryFind tFull externTypeMap with
            | Some n -> n
            | None   -> nz t.Name ""
        let rawMethods = safeGetMethods t
        let staticMethods =
            rawMethods
            |> Array.filter (fun m ->
                not m.IsSpecialName
                && not m.IsGenericMethodDefinition)
            |> Array.sortBy (fun m -> nz m.Name "")
        for m in staticMethods do
            let mName = nz m.Name ""
            let qual = sprintf "%s.%s" tFull mName
            match safeGetParams m, safeReturnType m with
            | None, _ | _, None ->
                recordSkip qual "signature unresolvable in MetadataLoadContext"
            | Some parameters, Some retType ->
            let arity = parameters.Length
            // Owner-prefixed name for the emitted Lyric func.
            let baseName = typeLyricName + "_" + mName
            let key = (baseName, arity)
            if not (globalSeen.Add key) then
                recordSkip qual
                    (sprintf "duplicate (%s, arity = %d) — overload \
                              kept earlier" baseName arity)
            else
            let paramMaps =
                parameters
                |> Array.map (fun p ->
                    nz p.Name "arg", mapClrType p.ParameterType externTypeMap)
            let returnMap = mapClrType retType externTypeMap
            let firstParamErr =
                paramMaps
                |> Array.tryPick (fun (_, r) ->
                    match r with Error e -> Some e | _ -> None)
            match returnMap, firstParamErr with
            | Ok retLyric, None ->
                let argList =
                    paramMaps
                    |> Array.map (fun (pname, r) ->
                        match r with
                        | Ok ltype ->
                            let pn, _ = maybeRename pname
                            sprintf "%s: in %s" pn ltype
                        | Error _ -> "")
                    |> String.concat ", "
                let methodName, renamed = maybeRename baseName
                if renamed then
                    sb.AppendLine "// renamed to avoid keyword collision"
                        |> ignore
                sb.AppendLine
                    (sprintf "@externTarget(\"%s\")" qual) |> ignore
                sb.AppendLine
                    (sprintf "pub func %s(%s): %s = ()"
                            methodName argList retLyric) |> ignore
                methodCount <- methodCount + 1
            | Error e, _ ->
                recordSkip qual (sprintf "return: %s" e)
            | _, Some e ->
                recordSkip qual (sprintf "param: %s" e)

        if not (Array.isEmpty staticMethods) then
            sb.AppendLine "" |> ignore

    let skipReport =
        if skipped = 0 then None
        else Some (skipBuf.ToString())

    Ok { LyricSource    = sb.ToString()
         SkipReport     = skipReport
         LyricPackage   = lyricPkg
         ExternTypes    = publicTypes.Length
         ExternMethods  = methodCount
         SkippedMembers = skipped }
