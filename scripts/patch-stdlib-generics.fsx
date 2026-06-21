// patch-stdlib-generics.fsx — retarget TypeDefs and TypeRefs in F#-emitted DLLs so they
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
// HOW IT WORKS
// ------------
//   1. Scan the self-hosted-built DLLs in --source <dir> (the per-package
//      emit output) to build a rename map:
//        (namespace, base_name_without_suffix) -> arity_suffixed_name
//      e.g. ("Std.Core", "Option") -> "Option`1"
//   2. Walk every Lyric.Stdlib.*.dll in each target <dir> and rename
//      matching TypeDefs in place (so the F#-built Core etc. gain the
//      correct arity-suffix TypeDef names while keeping all their methods).
//   3. Walk every DLL in each target <dir> and rename matching TypeRefs
//      in place so all cross-assembly references use the suffixed name.
//
// Both passes are idempotent: a name that already carries the suffix will
// not match any rename-map key and will not be modified.
//
// NOT force-replacing Core: the self-hosted Core has a different ABI for
// generic functions (e.g. unwrapOr signature) vs. the F#-built Core that
// the F#-built TypeChecker was compiled against.  Patching TypeDefs
// in-place preserves all existing methods.
//
// Run:  dotnet fsi scripts/patch-stdlib-generics.fsx --source <dir> <dir> [<dir>...]
//   --source <dir>  : directory containing self-hosted-built DLLs used to
//                     discover arity-suffix TypeDef names (the per-package
//                     emit temp dir from stage-selfhosted-stdlib.sh).
//                     Must precede the target <dir>... arguments.

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

// Patch TypeDefs in a Lyric.Stdlib.*.dll file in place.
// Returns the number of TypeDef renames made.
let patchTypeDefs (renameMap: Map<string * string, string>) (path: string) : int =
    try
        use asm = AssemblyDefinition.ReadAssembly(path, ReaderParameters(ReadWrite = true))
        let m = asm.MainModule
        let mutable rewrites = 0
        for td in m.Types do
            let key = (td.Namespace, td.Name)
            match Map.tryFind key renameMap with
            | Some newName when td.Name <> newName ->
                td.Name  <- newName
                rewrites <- rewrites + 1
            | _ -> ()
        if rewrites > 0 then
            asm.Write()
        rewrites
    with ex ->
        eprintfn "  warning: could not patch TypeDefs in %s: %s"
            (Path.GetFileName path) ex.Message
        0

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
        eprintfn "  ERROR: no arity-suffix TypeDefs found in '%s'" sourceDir
        eprintfn "         Has --internal-perpackage-build run successfully?"
        Environment.Exit 1

    printfn "  rename map (%d entries):" renameMap.Count
    for ((ns, baseName), newName) in Map.toSeq renameMap do
        printfn "    %s.%s  ->  %s" ns baseName newName

    let mutable totalPatched  = 0
    let mutable totalRewrites = 0

    // Pass 1: patch TypeDefs in Lyric.Stdlib.*.dll files in the target dirs.
    // This renames the generic TypeDef entries in the F#-built stdlib DLLs
    // (e.g. Option -> Option`1 in Lyric.Stdlib.Core.dll) so they match the
    // arity-suffix convention without replacing the DLLs (which would change
    // the method ABI the F#-built TypeChecker was compiled against).
    printfn "patch-stdlib-generics: pass 1 — patching TypeDefs in stdlib DLLs..."
    for dir in targetDirs do
        if Directory.Exists dir then
            for dll in Directory.GetFiles(dir, "Lyric.Stdlib.*.dll") do
                let rewrites = patchTypeDefs renameMap dll
                if rewrites > 0 then
                    totalPatched  <- totalPatched  + 1
                    totalRewrites <- totalRewrites + rewrites
                    printfn "  patched TypeDefs in %-50s (%d rename(s))"
                        (Path.GetFileName dll) rewrites

    // Pass 2: patch TypeRefs in ALL DLLs in the target dirs.
    // This updates cross-assembly references (e.g. Lyric.Lyric.TypeChecker.dll
    // calling Std.Core.Program.unwrapOr(Option`1<T>, T)) to use the suffix.
    printfn "patch-stdlib-generics: pass 2 — patching TypeRefs in all DLLs..."
    for dir in targetDirs do
        if Directory.Exists dir then
            for dll in Directory.GetFiles(dir, "*.dll") do
                let rewrites = patchTypeRefs renameMap dll
                if rewrites > 0 then
                    totalPatched  <- totalPatched  + 1
                    totalRewrites <- totalRewrites + rewrites
                    printfn "  patched TypeRefs in %-50s (%d rename(s))"
                        (Path.GetFileName dll) rewrites

    printfn "patch-stdlib-generics: done — %d DLL(s) patched, %d total rename(s)"
        totalPatched totalRewrites
    0

exit (main fsi.CommandLineArgs.[1..])
