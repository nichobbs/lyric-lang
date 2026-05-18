/// Auto-generated `extern type` / `@externTarget` shims for Maven
/// Central packages (docs/31-maven-linking.md §4, D053).
///
/// Parallel to `NugetShim.fs` but operating on Java class surface data
/// supplied by `lyric-resolver.jar` rather than .NET `MetadataLoadContext`
/// reflection.  The resolver returns a `classes` array per resolved JAR;
/// this module translates that surface to a Lyric source file and an
/// optional skip report.
///
/// Shim file layout (per §4):
///   `<manifest-dir>/_extern/<PascalGroup>_<PascalArtifact>.l`
///
/// Header:
///   `# lyric:generated-sha256:<sha256-of-jar>`
///   `@axiom("from Maven <groupId>:<artifactId> v<version>")`
///   `package <PascalGroup>.<PascalArtifact>`
///
/// Method naming (§4 / §6):
///   - Static methods:   `<TypeName>_<methodName>(args…): ReturnType`
///   - Instance methods: `<methodName>(recv: in <TypeName>, args…): ReturnType`
///   - Checked-exception methods wrap return in `Result[T, JvmException]`.
module Lyric.Cli.MavenShim

open System
open System.IO
open System.Text
open Lyric.Cli.Maven

// ---------------------------------------------------------------------------
// Shim file record.
// ---------------------------------------------------------------------------

/// Generated shim file contents + skip report, analogous to
/// `NugetShim.ShimFile`.
type MavenShimFile =
    { /// Path suffix relative to the manifest directory:
      ///   `_extern/<PascalGroup>_<PascalArtifact>.l`
      RelativePath:   string
      /// Full Lyric source text.
      LyricSource:    string
      /// Skip report (`_extern/<...>.skip.md`) or `None` if clean.
      SkipReport:     string option
      /// Lyric package name (`<PascalGroup>.<PascalArtifact>`).
      LyricPackage:   string
      ExternTypes:    int
      ExternMethods:  int
      SkippedMembers: int }

// ---------------------------------------------------------------------------
// Java type -> Lyric type mapping.
// ---------------------------------------------------------------------------

/// Lyric reserved words — same conservative set as `NugetShim`.
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

let private safeIdent (name: string) : string * bool =
    if Set.contains name lyricKeywords then (name + "_", true)
    else (name, false)

/// Map a Java binary type name to a Lyric type spelling.
/// Returns `Error reason` for types the bootstrap generator can't
/// safely translate; the caller records a skip entry.
///
/// `knownExternTypes` maps fully-qualified Java class names to their
/// Lyric simple names as declared in the shim's `extern type` block.
let private mapJavaType
        (typeName: string)
        (knownExternTypes: Map<string, string>)
        : Result<string, string> =
    match typeName with
    | "boolean" | "java.lang.Boolean"    -> Ok "Bool"
    | "byte"    | "java.lang.Byte"       -> Ok "Byte"
    | "int"     | "java.lang.Integer"    -> Ok "Int"
    | "long"    | "java.lang.Long"       -> Ok "Long"
    | "short"   | "java.lang.Short"      -> Ok "Int"   // widened
    | "float"   | "java.lang.Float"      -> Ok "Float"
    | "double"  | "java.lang.Double"     -> Ok "Double"
    | "char"    | "java.lang.Character"  -> Ok "Char"
    | "java.lang.String"                 -> Ok "String"
    | "void"                             -> Ok "Unit"
    | t when t.EndsWith("[]")            -> Error "array type"
    | t when t.Contains("<")             -> Error "generic type"
    | t ->
        match Map.tryFind t knownExternTypes with
        | Some lyricName -> Ok lyricName
        | None -> Error (sprintf "type %s not translatable" t)

// ---------------------------------------------------------------------------
// Shim generator.
// ---------------------------------------------------------------------------

/// Generate the shim source + skip report for one top-level Maven JAR.
///
/// `jar` must be the `ResolvedMavenJar` for a top-level dependency
/// (i.e. `jar.IsTopLevel = true` and `jar.Classes <> None`).  Callers
/// should check `IsTopLevel` before calling; passing a transitive dep
/// produces an empty shim with a note.
let generate (jar: ResolvedMavenJar) : MavenShimFile =
    let lyricPkg = lyricPackageName jar.Group jar.Artifact

    // Artifact part used in the file name: `PascalGroup_PascalArtifact`
    let pascalGroup =
        jar.Group.Split('.')
        |> Array.map (fun s ->
            if s.Length = 0 then ""
            else string (Char.ToUpperInvariant s.[0]) + s.[1..])
        |> String.concat ""
    let pascalArt =
        jar.Artifact.Split([| '-'; '.'; '_' |], StringSplitOptions.RemoveEmptyEntries)
        |> Array.map (fun s ->
            if s.Length = 0 then ""
            else string (Char.ToUpperInvariant s.[0]) + s.[1..].ToLowerInvariant())
        |> String.concat ""
    let relPath =
        Path.Combine("_extern", sprintf "%s_%s.l" pascalGroup pascalArt)

    let sb = StringBuilder()
    let skipBuf = StringBuilder()
    let mutable skipped = 0
    let mutable methodCount = 0
    let mutable typeCount = 0
    let mutable needsJvmException = false

    let coord = sprintf "%s:%s" jar.Group jar.Artifact

    let recordSkip (path: string) (reason: string) =
        if skipped = 0 then
            skipBuf.AppendLine
                (sprintf "# Skipped surface for %s v%s" coord jar.Version)
                |> ignore
            skipBuf.AppendLine "" |> ignore
            skipBuf.AppendLine
                "Members not translatable to Lyric \
                 (Maven shim generator):" |> ignore
            skipBuf.AppendLine "" |> ignore
        skipped <- skipped + 1
        skipBuf.AppendLine (sprintf "- `%s` — %s" path reason) |> ignore

    // Header: drift-detection comment then @axiom + package.
    sb.AppendLine
        (sprintf "# lyric:generated-sha256:%s" jar.Sha256) |> ignore
    sb.AppendLine
        (sprintf "@axiom(\"from Maven %s v%s\")" coord jar.Version) |> ignore
    sb.AppendLine (sprintf "package %s" lyricPkg) |> ignore
    sb.AppendLine "" |> ignore
    sb.AppendLine "// Auto-generated by `lyric restore` — do not edit \
                  by hand." |> ignore
    sb.AppendLine "// Re-running restore overwrites this file." |> ignore

    match jar.Classes with
    | None ->
        sb.AppendLine "" |> ignore
        sb.AppendLine
            "// Resolver could not extract class surface (native or POM-only \
             artifact)." |> ignore

    | Some [] ->
        sb.AppendLine "" |> ignore
        sb.AppendLine
            "// No public classes found in this JAR." |> ignore

    | Some classes ->
        let sortedClasses = classes |> List.sortBy (fun c -> c.ClassName)

        // Pre-scan: do any methods have checked exceptions?  If so, we need
        // to import Std.JvmExceptionHost so `JvmException` is in scope.
        let anyChecked =
            sortedClasses
            |> List.exists (fun cls ->
                cls.Methods |> List.exists (fun m -> m.HasCheckedExceptions))
        if anyChecked then
            sb.AppendLine "" |> ignore
            sb.AppendLine "import Std.JvmExceptionHost" |> ignore
            needsJvmException <- true

        sb.AppendLine "" |> ignore

        // Build the extern-type map: fully-qualified class name -> Lyric name.
        // Disambiguate name collisions by prefixing the last package segment.
        let externTypeMap =
            let simpleOf (cls: string) =
                let dot = cls.LastIndexOf '.'
                if dot >= 0 then cls.Substring(dot + 1) else cls
            let groups =
                sortedClasses
                |> List.groupBy (fun c -> simpleOf c.ClassName)
            [ for (simple, members) in groups do
                for (i, c) in List.indexed members do
                    let lyricName =
                        if i = 0 then simple
                        else
                            let dot = c.ClassName.LastIndexOf '.'
                            if dot <= 0 then simple + "_" + string i
                            else
                                let pkg = c.ClassName.Substring(0, dot)
                                let pkgTail =
                                    let idx = pkg.LastIndexOf '.'
                                    if idx >= 0 then pkg.Substring(idx + 1)
                                    else pkg
                                pkgTail + "_" + simple
                    yield c.ClassName, lyricName ]
            |> Map.ofList

        typeCount <- List.length sortedClasses

        // Emit `extern type` block.
        for cls in sortedClasses do
            let lyricName =
                match Map.tryFind cls.ClassName externTypeMap with
                | Some n -> n
                | None   ->
                    let dot = cls.ClassName.LastIndexOf '.'
                    if dot >= 0 then cls.ClassName.Substring(dot + 1)
                    else cls.ClassName
            sb.AppendLine
                (sprintf "extern type %s = \"%s\"" lyricName cls.ClassName)
                |> ignore
        sb.AppendLine "" |> ignore

        // Build a deduplication set: (funcName, paramCount) pairs already emitted.
        let globalSeen =
            System.Collections.Generic.HashSet<string * int>()

        for cls in sortedClasses do
            let lyricTypeName =
                match Map.tryFind cls.ClassName externTypeMap with
                | Some n -> n
                | None   ->
                    let dot = cls.ClassName.LastIndexOf '.'
                    if dot >= 0 then cls.ClassName.Substring(dot + 1)
                    else cls.ClassName

            let publicMethods =
                cls.Methods
                |> List.sortBy (fun m -> m.IsStatic, m.Name)

            for m in publicMethods do
                let qual = sprintf "%s.%s" cls.ClassName m.Name

                // Map all parameters (for instance methods, receiver added below).
                let paramMaps =
                    m.Params
                    |> List.map (fun p ->
                        p.Name, mapJavaType p.TypeName externTypeMap)
                let retMap = mapJavaType m.ReturnType externTypeMap
                let firstParamErr =
                    paramMaps
                    |> List.tryPick (fun (_, r) ->
                        match r with Error e -> Some e | _ -> None)

                match retMap, firstParamErr with
                | Error e, _ ->
                    recordSkip qual (sprintf "return: %s" e)
                | _, Some e ->
                    recordSkip qual (sprintf "param: %s" e)
                | Ok rawRet, None ->
                    // Wrap return type for checked exceptions per §5.
                    let retLyric =
                        if m.HasCheckedExceptions then
                            match rawRet with
                            | "Unit" -> "Result[Unit, JvmException]"
                            | t      -> sprintf "Result[%s, JvmException]" t
                        else rawRet

                    // Build function name and parameter list.
                    // Static:   `<TypeName>_<methodName>(args…)`
                    // Instance: `<methodName>(recv: in <TypeName>, args…)`
                    let baseName, totalArity =
                        if m.IsStatic then
                            lyricTypeName + "_" + m.Name, List.length m.Params
                        else
                            m.Name, List.length m.Params + 1  // +1 for receiver

                    let key = (baseName, totalArity)
                    if not (globalSeen.Add key) then
                        recordSkip qual
                            (sprintf "duplicate (%s, arity=%d) — overload \
                                      kept earlier" baseName totalArity)
                    else
                        let argList =
                            let instanceReceiver =
                                if m.IsStatic then []
                                else
                                    let recvName, _ = safeIdent (
                                        string (Char.ToLowerInvariant lyricTypeName.[0])
                                        + lyricTypeName.[1..])
                                    [ sprintf "%s: in %s" recvName lyricTypeName ]
                            let mappedParams =
                                paramMaps
                                |> List.map (fun (pname, r) ->
                                    match r with
                                    | Ok ltype ->
                                        let pn, _ = safeIdent pname
                                        sprintf "%s: in %s" pn ltype
                                    | Error _ -> "")
                            instanceReceiver @ mappedParams
                            |> String.concat ", "

                        let funcName, renamed = safeIdent baseName
                        if renamed then
                            sb.AppendLine
                                "// renamed to avoid keyword collision"
                                |> ignore
                        sb.AppendLine
                            (sprintf "@externTarget(\"%s\")" qual) |> ignore
                        sb.AppendLine
                            (sprintf "pub func %s(%s): %s = ()"
                                    funcName argList retLyric) |> ignore
                        methodCount <- methodCount + 1

            if not (List.isEmpty publicMethods) then
                sb.AppendLine "" |> ignore

    ignore needsJvmException

    let skipReport =
        if skipped = 0 then None
        else Some (skipBuf.ToString())

    { RelativePath   = relPath
      LyricSource    = sb.ToString()
      SkipReport     = skipReport
      LyricPackage   = lyricPkg
      ExternTypes    = typeCount
      ExternMethods  = methodCount
      SkippedMembers = skipped }

/// Write `shim.LyricSource` (and optionally the skip report) to the
/// manifest directory.  Creates `_extern/` if it doesn't exist.
let writeShim (manifestDir: string) (shim: MavenShimFile) : unit =
    let externDir = Path.Combine(manifestDir, "_extern")
    Directory.CreateDirectory externDir |> ignore
    let shimPath = Path.Combine(manifestDir, shim.RelativePath)
    File.WriteAllText(shimPath, shim.LyricSource)
    match shim.SkipReport with
    | None -> ()
    | Some report ->
        let skipPath =
            match Option.ofObj (Path.ChangeExtension(shimPath, ".skip.md")) with
            | Some p -> p
            | None   -> shimPath + ".skip.md"
        File.WriteAllText(skipPath, report)

/// Check whether an existing shim file is up to date with the given
/// JAR SHA-256.  Returns `true` when the file exists and its header
/// comment matches, `false` otherwise.  When `false`, the caller
/// should regenerate and overwrite (B0053 drift check).
let shimIsCurrentFor (manifestDir: string) (relPath: string) (sha256: string) : bool =
    let shimPath = Path.Combine(manifestDir, relPath)
    if not (File.Exists shimPath) then false
    else
        let firstLine =
            use sr = new StreamReader(shimPath)
            sr.ReadLine()
        match Option.ofObj firstLine with
        | Some line ->
            let expected = sprintf "# lyric:generated-sha256:%s" sha256
            line.TrimEnd() = expected
        | None -> false
