// patch-stdlib-generics.fsx — retarget TypeRefs in F#-emitted Lyric.Stdlib.*.dll
// files to match the arity-suffix naming convention used by the self-hosted emitter.
//
// WHY THIS EXISTS
// ---------------
// The F# bootstrap compiler emits generic TypeDefs WITHOUT the CLR arity
// suffix (e.g. `Option` instead of `Option`1`, `Result` instead of
// `Result`2`).  The self-hosted MSIL emitter probes the installed
// Lyric.Stdlib.Core.dll at compile time (bridge.l::detectStdlibUsesAritySuffix)
// and adapts its TypeRef emission to match the installed convention.  This
// makes arity-suffix patching of TypeDefs (Pass 1) obsolete.
//
// Pass 2 (TypeRef patching in Lyric.Stdlib.*.dll) remains available as a
// correctness safety net for cross-stdlib TypeRefs (e.g. Sort.dll referencing
// Core types).  It is a no-op when the rename map is empty (e.g. in
// LYRIC_BOOTSTRAP_MINT=1 mode where the per-package output carries no
// arity-suffix TypeDefs).
//
// HOW IT WORKS
// ------------
//   1. Scan the self-hosted-built DLLs in --source <dir> (the per-package
//      emit output) to build a rename map:
//        (namespace, base_name_without_suffix) -> arity_suffixed_name
//      e.g. ("Std.Core", "Option") -> "Option`1"
//   2. Walk every Lyric.Stdlib.*.dll in each target <dir> and rename
//      matching TypeRefs in place so all stdlib cross-assembly references
//      use the suffixed name.
//
// Pass 2 is idempotent: a TypeRef that already carries the suffix will
// not match any rename-map key and will not be modified.
//
// SCOPE RESTRICTION ON Pass 2
// ---------------------------
// Intentionally targets only Lyric.Stdlib.*.dll files and NOT the compiler
// DLLs (Lyric.Lyric.*.dll, Lyric.Msil.*.dll, Lyric.Jvm.*.dll, etc.).
// Mono.Cecil's full metadata round-trip (asm.Write) corrupts static `Instance`
// singleton fields in F#-built compiler DLLs — e.g.
// `SyntaxKind_SkPackageDecl.Instance` in Lyric.Lyric.Parser.dll and
// `MsilType_MInt.Instance` in Lyric.Msil.Lowering.dll — causing
// `MissingFieldException` at runtime.
//
// Run:  dotnet fsi scripts/patch-stdlib-generics.fsx --source <dir> <dir> [<dir>...]
//   --source <dir>  : directory containing self-hosted per-package emit output
//                     (for rename map).  Must precede the target <dir>... arguments.

#r "nuget: Mono.Cecil, 0.11.6"

open System
open System.IO
open Mono.Cecil

// Build rename map by reading TypeDefs from all Lyric.Stdlib.*.dll files
// found in the given directory.  A TypeDef whose name contains a backtick
// (e.g. "Option`1") is generic with an arity suffix; we record:
//   (namespace, base_name_without_suffix) -> name_with_suffix
// so that TypeDefs / TypeRefs using the old no-suffix form can be updated.
let buildRenameMap (sourceDir: string) : Map<string * string, string> =
    let mutable map = Map.empty
    if Directory.Exists sourceDir then
        for dll in Directory.GetFiles(sourceDir, "Lyric.Stdlib.*.dll") do
            try
                use asm = AssemblyDefinition.ReadAssembly dll
                for t in asm.MainModule.Types do
                    let name = t.Name
                    let idx  = name.IndexOf('`')
                    if idx > 0 then
                        let baseName = name.[..idx - 1]
                        let ns       = t.Namespace
                        let key      = (ns, baseName)
                        if not (Map.containsKey key map) then
                            map <- Map.add key name map
            with ex ->
                eprintfn "  warning: skipping %s while building rename map: %s"
                    (Path.GetFileName dll) ex.Message
    map

// Patch TypeRefs in one DLL file in place.
// Returns the number of TypeRef renames made.
let patchTypeRefs (renameMap: Map<string * string, string>) (path: string) : int =
    try
        use asm = AssemblyDefinition.ReadAssembly(path, ReaderParameters(ReadWrite = true))
        let m = asm.MainModule
        let mutable rewrites = 0
        for tr in m.GetTypeReferences() do
            let key = (tr.Namespace, tr.Name)
            match Map.tryFind key renameMap with
            | Some newName ->
                tr.Name  <- newName
                rewrites <- rewrites + 1
            | None -> ()
        if rewrites > 0 then
            asm.Write()
        rewrites
    with ex ->
        eprintfn "  warning: could not patch TypeRefs in %s: %s"
            (Path.GetFileName path) ex.Message
        0

let main (args: string[]) =
    // Parse --source <dir> followed by one or more target dirs.
    let argList = args |> Array.toList
    let sourceDir, targetDirs =
        match argList with
        | "--source" :: src :: rest when rest.Length > 0 -> src, rest
        | _ ->
            eprintfn "Usage: dotnet fsi scripts/patch-stdlib-generics.fsx --source <self-hosted-out-dir> <target-dir>..."
            eprintfn "  --source: directory of self-hosted per-package emit output (for rename map)"
            Environment.Exit 1
            "", []

    printfn "patch-stdlib-generics: building rename map from self-hosted output in '%s'..." sourceDir
    let renameMap = buildRenameMap sourceDir

    if Map.isEmpty renameMap then
        printfn "  info: no arity-suffix TypeDefs found in '%s' — rename map is empty, skipping patches"
            sourceDir
        printfn "patch-stdlib-generics: done — nothing to patch"
        0
    else

    printfn "  rename map (%d entries):" renameMap.Count
    for ((ns, baseName), newName) in Map.toSeq renameMap do
        printfn "    %s.%s  ->  %s" ns baseName newName

    let mutable totalPatched  = 0
    let mutable totalRewrites = 0

    // Patch TypeRefs in Lyric.Stdlib.*.dll files in the target dirs.
    // Restricted to stdlib DLLs to avoid Mono.Cecil's asm.Write() corrupting
    // static Instance singletons in compiler DLLs (MissingFieldException).
    // TypeDef patching (the former Pass 1) is no longer needed: bridge.l probes
    // Core.dll at compile time and emits TypeRefs matching the installed convention.
    printfn "patch-stdlib-generics: patching TypeRefs in Lyric.Stdlib.*.dll..."
    for dir in targetDirs do
        if Directory.Exists dir then
            for dll in Directory.GetFiles(dir, "Lyric.Stdlib.*.dll") do
                let rewrites = patchTypeRefs renameMap dll
                if rewrites > 0 then
                    totalPatched  <- totalPatched  + 1
                    totalRewrites <- totalRewrites + rewrites
                    printfn "  patched TypeRefs in %-50s (%d rename(s))"
                        (Path.GetFileName dll) rewrites

    printfn "patch-stdlib-generics: done — %d stdlib DLL(s) patched, %d total rename(s)"
        totalPatched totalRewrites
    0

exit (main fsi.CommandLineArgs.[1..])
