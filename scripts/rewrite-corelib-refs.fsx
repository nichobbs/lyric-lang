// Track A A1.3 — retarget Lyric-emitted DLLs' AssemblyRefs from
// `System.Private.CoreLib` (the unified CoreCLR runtime assembly) to
// the matching public-facade reference assemblies (`System.Runtime`,
// `System.Collections`, `System.Console`, …) so the result is usable
// as a compile-time `<Reference>` from a C# project.
//
// Why per-TypeRef and not a bulk AssemblyRef rename:
//
//   The F# Lyric emitter writes every typeref to System.Private.CoreLib
//   because that's where the type actually lives in CoreCLR.  But the
//   reference assemblies that the C# compiler trusts ("contracts")
//   split BCL types across ~200 facade assemblies — `System.Object` is
//   exposed by `System.Runtime`, `List<T>` by `System.Collections`,
//   `Console` by `System.Console`, etc.  Simply renaming the single
//   AssemblyRef means every TypeRef now resolves through, say,
//   `System.Runtime`, but `System.Runtime.dll` doesn't expose
//   `List<T>` and the C# compiler / CLR loader rejects the assembly.
//
// What this script does:
//
//   1. Use MetadataLoadContext to crawl the .NET reference pack at
//      `~/.dotnet/packs/Microsoft.NETCore.App.Ref/<version>/ref/net10.0/`.
//      Build a `(TypeFullName) → AssemblyName` lookup table.
//   2. For each input DLL, walk the AssemblyRef + TypeRef tables.
//      For every TypeRef whose Scope is `System.Private.CoreLib`,
//      look up the type's facade, ensure an AssemblyRef row exists
//      for it (add if missing), and retarget the TypeRef.Scope to the
//      new ref.
//   3. Write the DLL back in place.
//
// Run:
//     dotnet fsi scripts/rewrite-corelib-refs.fsx <dll> [<dll> ...]

#r "nuget: Mono.Cecil, 0.11.6"

open System
open System.IO
open Mono.Cecil

let refPackVersion = "10.0.7"
let refPackDir =
    let home = Environment.GetEnvironmentVariable("HOME")
    let candidates =
        [ Path.Combine(home, ".dotnet/packs/Microsoft.NETCore.App.Ref", refPackVersion, "ref/net10.0")
          $"/root/.dotnet/packs/Microsoft.NETCore.App.Ref/{refPackVersion}/ref/net10.0"
          $"/usr/share/dotnet/packs/Microsoft.NETCore.App.Ref/{refPackVersion}/ref/net10.0" ]
    candidates
    |> List.tryFind Directory.Exists
    |> Option.defaultWith (fun () ->
        failwithf "Reference pack not found.  Searched: %A" candidates)

// Identity record for a ref-pack assembly: name + the version and
// public-key token the runtime expects.  Version + PKT vary across
// the facade family (System.Runtime / System.Collections use the BCL
// PKT b03f5f7f11d50a3a at Version 10.0.0.0; mscorlib uses the ECMA
// PKT b77a5c561934e089 at Version 4.0.0.0 for back-compat).
type FacadeId =
    { Name:    string
      Version: Version
      Token:   byte[] }

// Build two lookup tables from the reference pack:
//   typeMap   : type-full-name -> facade name
//   facadeIds : facade name    -> (version, public-key-token)
//
// The ref pack ships some assemblies whose dependencies (e.g.
// System.Security.Permissions) aren't in the pack itself.  Cecil reads
// metadata even when transitive refs are missing, so we walk each DLL
// directly rather than going through System.Reflection.MetadataLoadContext.
let buildTypeMap () : Map<string, string> * Map<string, FacadeId> =
    let dlls = Directory.GetFiles(refPackDir, "*.dll")
    let mutable typeMap = Map.empty
    let mutable facadeIds = Map.empty
    for dll in dlls do
        let asmName = Path.GetFileNameWithoutExtension dll
        try
            let asm = AssemblyDefinition.ReadAssembly(dll)
            try
                let id =
                    { Name    = asmName
                      Version = asm.Name.Version
                      Token   =
                        if asm.Name.HasPublicKey then asm.Name.PublicKeyToken
                        elif not (isNull asm.Name.PublicKeyToken) then asm.Name.PublicKeyToken
                        else [||] }
                facadeIds <- Map.add asmName id facadeIds

                for t in asm.MainModule.Types do
                    if t.IsPublic then
                        let key = t.FullName
                        if not (Map.containsKey key typeMap) then
                            typeMap <- Map.add key asmName typeMap
                for t in asm.MainModule.ExportedTypes do
                    if t.IsForwarder then
                        let key = t.FullName
                        if not (Map.containsKey key typeMap) then
                            typeMap <- Map.add key asmName typeMap
            finally
                asm.Dispose()
        with ex ->
            eprintfn "  warning: skipping %s (%s)" asmName ex.Message
    printfn "  loaded %d type → facade mappings from ref pack (%d facades)"
        typeMap.Count facadeIds.Count
    typeMap, facadeIds

// Make-or-find an AssemblyRef for `targetAsmName` in `module`.  Uses
// `facadeIds` to look up the right version + public-key-token for the
// target — facades use the BCL token (b03f5f7f11d50a3a) at v10.0.0.0
// but `mscorlib` uses the ECMA token (b77a5c561934e089) at v4.0.0.0.
let getOrAddAssemblyRef
        (facadeIds: Map<string, FacadeId>)
        (m: ModuleDefinition)
        (targetAsmName: string)
        : AssemblyNameReference =
    let existing =
        m.AssemblyReferences
        |> Seq.tryFind (fun r -> r.Name = targetAsmName)
    match existing with
    | Some r -> r
    | None ->
        let id =
            match Map.tryFind targetAsmName facadeIds with
            | Some i -> i
            | None   ->
                failwithf "rewrite-corelib-refs: no FacadeId for '%s' (not found in ref pack)"
                    targetAsmName
        let newRef = AssemblyNameReference(id.Name, id.Version)
        newRef.HasPublicKey   <- false
        newRef.PublicKey      <- null
        newRef.PublicKeyToken <- id.Token
        m.AssemblyReferences.Add(newRef)
        newRef

// Drop AssemblyRefs that no TypeRef references any more.  Mono.Cecil
// only writes refs that are pointed to by some scope; orphaned refs
// don't matter functionally but make the output cleaner.
let pruneUnusedAssemblyRefs (m: ModuleDefinition) : unit =
    let referenced =
        System.Collections.Generic.HashSet<string>()
    for t in m.GetTypeReferences() do
        match t.Scope with
        | :? AssemblyNameReference as r -> referenced.Add(r.Name) |> ignore
        | _ -> ()
    let toRemove =
        m.AssemblyReferences
        |> Seq.filter (fun r -> not (referenced.Contains r.Name))
        |> Seq.toList
    for r in toRemove do
        m.AssemblyReferences.Remove(r) |> ignore

let rewriteOne
        (typeMap: Map<string, string>)
        (facadeIds: Map<string, FacadeId>)
        (path: string)
        : bool =
    let asm = AssemblyDefinition.ReadAssembly(path, ReaderParameters(ReadWrite = true))
    let m = asm.MainModule

    // Find the System.Private.CoreLib AssemblyRef, if any.
    let coreLibRef =
        m.AssemblyReferences
        |> Seq.tryFind (fun r -> r.Name = "System.Private.CoreLib")

    match coreLibRef with
    | None ->
        asm.Dispose()
        false
    | Some _ ->
        // For each TypeRef pointing at System.Private.CoreLib, find
        // the type's facade and retarget the scope.
        let mutable rewrites = 0
        let mutable unmapped = []
        for tr in m.GetTypeReferences() do
            match tr.Scope with
            | :? AssemblyNameReference as r when r.Name = "System.Private.CoreLib" ->
                // Type names with nested-class `+` separators in Cecil's
                // FullName don't always match the `.` separator used in
                // System.Reflection.GetExportedTypes() / .FullName.
                // Try both forms.
                let dottedName = tr.FullName.Replace('/', '+')
                let lookupKey =
                    if Map.containsKey dottedName typeMap then Some dottedName
                    else
                        let alt = tr.FullName.Replace('+', '.')
                        if Map.containsKey alt typeMap then Some alt
                        else None
                match lookupKey with
                | Some k ->
                    let targetAsm = Map.find k typeMap
                    if targetAsm <> "System.Private.CoreLib" then
                        let newRef = getOrAddAssemblyRef facadeIds m targetAsm
                        tr.Scope <- newRef :> IMetadataScope
                        rewrites <- rewrites + 1
                | None ->
                    unmapped <- tr.FullName :: unmapped
            | _ -> ()

        if not (List.isEmpty unmapped) then
            eprintfn "  warning: %d typerefs in %s have no facade mapping; left pointing at System.Private.CoreLib"
                (List.length unmapped) (Path.GetFileName path)
            for u in (List.distinct unmapped |> List.take (min 5 (List.length (List.distinct unmapped)))) do
                eprintfn "    %s" u

        pruneUnusedAssemblyRefs m

        if rewrites > 0 then
            asm.Write()
            asm.Dispose()
            true
        else
            asm.Dispose()
            false

let main args =
    printfn "Loading reference pack from %s" refPackDir
    let typeMap, facadeIds = buildTypeMap ()
    let mutable count = 0
    for path in args do
        if File.Exists path then
            if rewriteOne typeMap facadeIds path then
                count <- count + 1
                if count % 10 = 0 then printfn "  rewrote %d DLLs so far..." count
        else
            eprintfn "rewrite-corelib-refs: file not found: %s" path
    printfn "rewrote %d DLL(s)" count
    0

exit (main fsi.CommandLineArgs.[1..])
