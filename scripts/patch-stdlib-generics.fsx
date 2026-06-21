// patch-stdlib-generics.fsx — retarget TypeRefs in F#-emitted DLLs so they
// match the arity-suffix naming convention used by the self-hosted emitter.
//
// WHY THIS EXISTS
// ---------------
// The F# bootstrap compiler emits generic TypeDefs WITHOUT the CLR arity
// suffix (e.g. `Option` instead of `Option`1`, `Result` instead of
// `Result`2`).  The self-hosted MSIL emitter always adds the suffix, so:
//
//   * F#-built `Lyric.Stdlib.Core.dll`     → TypeDefs: Option, Result, ...
//   * Self-hosted-built `Lyric.Stdlib.Core.dll` → TypeDefs: Option`1, Result`2, ...
//   * All F#-built DLLs that import Core   → TypeRefs:  Option, Result, ...
//   * User code compiled by self-hosted emitter → TypeRefs: Option`1, Result`2, ...
//
// After `stage-selfhosted-stdlib.sh` force-replaces the F#-built Core with
// the self-hosted-built one (which has arity-suffix TypeDefs), every F#-built
// DLL that still references `Option` or `Result` without the suffix will fail
// at load time with a TypeLoadException.  This script patches those TypeRefs.
//
// HOW IT WORKS
// ------------
//   1. Scan the self-hosted Core DLL (already force-copied into each <dir>)
//      to build a rename map: (namespace, base_name) -> arity_suffixed_name
//      e.g. ("Std.Core", "Option") -> "Option`1"
//   2. Walk every DLL in each <dir> (skipping the Core DLL itself, which is
//      already correct) and rename matching TypeRefs in place using Cecil.
//
// The patch is idempotent: a DLL whose TypeRefs already carry the suffix will
// not match any rename-map key and will not be modified.
//
// Run:  dotnet fsi scripts/patch-stdlib-generics.fsx <dir> [<dir>...]

#r "nuget: Mono.Cecil, 0.11.6"

open System
open System.IO
open Mono.Cecil

// Build rename map by reading TypeDefs from all Lyric.Stdlib.*.dll files
// found in the given directories.  A TypeDef whose name contains a backtick
// (e.g. "Option`1") is generic with an arity suffix; we record:
//   (namespace, base_name_without_suffix) -> name_with_suffix
// so that TypeRefs using the old no-suffix form can be updated.
let buildRenameMap (dirs: string list) : Map<string * string, string> =
    let mutable map = Map.empty
    for dir in dirs do
        if Directory.Exists dir then
            for dll in Directory.GetFiles(dir, "Lyric.Stdlib.*.dll") do
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

// Patch one DLL file in place.  Returns the number of TypeRef renames made.
// Returns 0 and leaves the file untouched if there is nothing to rename.
let patchOne (renameMap: Map<string * string, string>) (path: string) : int =
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
        eprintfn "  warning: could not patch %s: %s" (Path.GetFileName path) ex.Message
        0

let main (args: string[]) =
    if args.Length = 0 then
        eprintfn "Usage: dotnet fsi scripts/patch-stdlib-generics.fsx <dir>..."
        1
    else
        let dirs = args |> Array.toList

        printfn "patch-stdlib-generics: scanning for arity-suffix TypeDefs in %d dir(s)..."
            dirs.Length
        let renameMap = buildRenameMap dirs

        if Map.isEmpty renameMap then
            eprintfn "  ERROR: no arity-suffix TypeDefs found — has the self-hosted Core been staged yet?"
            1
        else
            printfn "  rename map (%d entries):" renameMap.Count
            for ((ns, baseName), newName) in Map.toSeq renameMap do
                printfn "    %s.%s  ->  %s" ns baseName newName

            let mutable totalPatched  = 0
            let mutable totalRewrites = 0

            for dir in dirs do
                if Directory.Exists dir then
                    for dll in Directory.GetFiles(dir, "*.dll") do
                        // Skip the Core DLL itself — it is already self-hosted-built
                        // and correct; its TypeDefs are the source of the rename map.
                        if not (Path.GetFileName(dll).StartsWith("Lyric.Stdlib.Core.")) then
                            let rewrites = patchOne renameMap dll
                            if rewrites > 0 then
                                totalPatched  <- totalPatched  + 1
                                totalRewrites <- totalRewrites + rewrites
                                printfn "  patched %-50s  (%d rename(s))"
                                    (Path.GetFileName dll) rewrites

            printfn "patch-stdlib-generics: done — %d DLL(s) patched, %d total TypeRef rename(s)"
                totalPatched totalRewrites
            0

exit (main fsi.CommandLineArgs.[1..])
