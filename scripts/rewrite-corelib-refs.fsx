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

// Discover the installed `Microsoft.NETCore.App.Ref` major-10 patch
// version dynamically.  Hard-coding a specific 10.x.y string breaks
// every host whose dotnet SDK ships a different patch — and the patch
// number changes with each monthly servicing release.  We scan the
// candidate pack roots, list directories whose name starts with `10.`,
// and prefer the highest semantic version.  Lexicographic sorting is
// wrong for `10.0.9` vs `10.0.10` (`9` > `1`), so parse via
// `System.Version` and pick the maximum.
let refPackDir =
    // Helper to find a 10.x.y subdirectory and extract the highest version
    let pickVersion (root: string) : string option =
        try
            Directory.GetDirectories(root)
            |> Array.map Path.GetFileName
            |> Array.choose (fun n ->
                if n.StartsWith "10." then
                    match System.Version.TryParse n with
                    | true,  v -> Some (v, n)
                    | false, _ -> None
                else None)
            |> Array.sortByDescending fst
            |> Array.tryHead
            |> Option.map snd
        with _ -> None
    
    // Build a list of candidate pack roots to search
    let buildPackRoots () =
        let roots = System.Collections.Generic.List<string>()
        
        // 1. Check DOTNET_ROOT environment variable (used by some installers)
        let dotnetRoot = Environment.GetEnvironmentVariable("DOTNET_ROOT")
        if not (System.String.IsNullOrEmpty dotnetRoot) then
            roots.Add(Path.Combine(dotnetRoot, "packs/Microsoft.NETCore.App.Ref"))
        
        // 2. Try to infer from DOTNET_ROOT(x86) on Windows
        let dotnetRootX86 = Environment.GetEnvironmentVariable("DOTNET_ROOT(x86)")
        if not (System.String.IsNullOrEmpty dotnetRootX86) then
            roots.Add(Path.Combine(dotnetRootX86, "packs/Microsoft.NETCore.App.Ref"))
        
        // 3. Check HOME/.dotnet (standard location on Unix)
        let homeOpt =
            Environment.GetEnvironmentVariable("HOME")
            |> Option.ofObj
            |> Option.filter (fun s -> not (System.String.IsNullOrEmpty s))
        match homeOpt with
        | Some h -> roots.Add(Path.Combine(h, ".dotnet/packs/Microsoft.NETCore.App.Ref"))
        | None -> ()
        
        // 4. Check common Linux system locations
        roots.Add("/usr/share/dotnet/packs/Microsoft.NETCore.App.Ref")
        roots.Add("/root/.dotnet/packs/Microsoft.NETCore.App.Ref")
        
        // 5. Check common Homebrew location on macOS
        roots.Add("/opt/homebrew/Cellar/dotnet")
        
        // 6. Check standard macOS location
        roots.Add("/usr/local/share/dotnet/packs/Microsoft.NETCore.App.Ref")
        
        roots |> Seq.toList
    
    let findRefPackInHomebrew (baseDir: string) : string option =
        // For Homebrew, the structure is:
        // /opt/homebrew/Cellar/dotnet/<version>/libexec/packs/Microsoft.NETCore.App.Ref/<version>/ref/net10.0/
        try
            if Directory.Exists baseDir then
                let versions = Directory.GetDirectories(baseDir)
                                 |> Array.map Path.GetFileName
                                 |> Array.filter (fun v -> v.Contains("."))
                                 |> Array.map (fun v -> (v, Path.Combine(baseDir, v, "libexec/packs/Microsoft.NETCore.App.Ref")))
                                 |> Array.filter (fun (_, path) -> Directory.Exists path)
                if versions.Length > 0 then
                    let (_, packRoot) = versions.[0]
                    pickVersion packRoot
                    |> Option.map (fun v -> Path.Combine(packRoot, v, "ref/net10.0"))
                    |> Option.filter Directory.Exists
                else None
            else None
        with _ -> None
    
    let allRoots = buildPackRoots ()
    let candidate =
        // Try standard pack root locations first
        allRoots
        |> List.filter (fun root -> root <> "/opt/homebrew/Cellar/dotnet")
        |> List.tryPick (fun root ->
            if Directory.Exists root then
                pickVersion root
                |> Option.map (fun v -> Path.Combine(root, v, "ref/net10.0"))
                |> Option.filter Directory.Exists
            else None)
        |> Option.orElseWith (fun () ->
            // Fall back to Homebrew special handling
            findRefPackInHomebrew "/opt/homebrew/Cellar/dotnet")
    
    candidate
    |> Option.defaultWith (fun () ->
        let searchedRoots = buildPackRoots ()
        failwithf
            "Reference pack not found.  Searched: %A (expected a 10.x.y/ref/net10.0 directory)\n\nDotnet info:\n  DOTNET_ROOT=%s\n  SDK base: %s"
            searchedRoots
            (match Environment.GetEnvironmentVariable("DOTNET_ROOT") with null -> "(not set)" | s -> s)
            (System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory()))

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
    // `use` ensures `asm` is disposed even when `getOrAddAssemblyRef` /
    // `Write()` throw mid-flight.  Without this a `ReadWrite = true`
    // handle would stay locked on Windows and the next pass would fail
    // with a sharing-violation IOException.
    use asm = AssemblyDefinition.ReadAssembly(path, ReaderParameters(ReadWrite = true))
    let m = asm.MainModule

    // Find the System.Private.CoreLib AssemblyRef, if any.
    let coreLibRef =
        m.AssemblyReferences
        |> Seq.tryFind (fun r -> r.Name = "System.Private.CoreLib")

    match coreLibRef with
    | None ->
        false
    | Some _ ->
        // For each TypeRef pointing at System.Private.CoreLib, find
        // the type's facade and retarget the scope.
        let mutable rewrites = 0
        let mutable unmapped = []
        for tr in m.GetTypeReferences() do
            match tr.Scope with
            | :? AssemblyNameReference as r when r.Name = "System.Private.CoreLib" ->
                // Cecil reports nested types as `Outer/Inner` in
                // `FullName` while `System.Reflection` produces
                // `Outer+Inner`.  Our `typeMap` is keyed by the
                // reflection form (`+`), so first normalise Cecil's
                // `/` to `+`; if that misses, also try a fully-dotted
                // form for the rare ref-pack types whose `FullName`
                // we recorded with `.` separators.
                let plusName = tr.FullName.Replace('/', '+')
                let lookupKey =
                    if Map.containsKey plusName typeMap then Some plusName
                    else
                        let dotted = tr.FullName.Replace('+', '.')
                        if Map.containsKey dotted typeMap then Some dotted
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
            let distinctUnmapped = List.distinct unmapped
            eprintfn "  warning: %d typerefs in %s have no facade mapping; left pointing at System.Private.CoreLib"
                (List.length unmapped) (Path.GetFileName path)
            for u in (distinctUnmapped |> List.take (min 5 (List.length distinctUnmapped))) do
                eprintfn "    %s" u

        pruneUnusedAssemblyRefs m

        if rewrites > 0 then
            asm.Write()
            true
        else
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
