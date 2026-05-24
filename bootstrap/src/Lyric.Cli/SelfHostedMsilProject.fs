/// Bootstrap-test shim for the self-hosted multi-package MSIL bridge
/// (`Msil.Bridge.compileProjectToMsilEncoded`).  Mirrors the single-file
/// `Lyric.Cli.SelfHostedMsil` shim: reflects out the static entry point
/// on the cached `Lyric.Msil.Bridge.dll` and forwards an F#-friendly
/// `(packageName, source) list` payload to it.
///
/// Exists so `bootstrap/tests/Lyric.Cli.Tests/SelfHostedMsilProjectBridgeTests.fs`
/// can drive the self-hosted multi-package pipeline through F# without
/// shelling out to a separate `lyric --internal-project-build` process —
/// the same pattern `SelfHostedMsil.fs` follows for the single-file path.
///
/// Tracks #1183 (Phase 1).  This shim disappears once the F# bootstrap
/// CLI's `--internal-project-build` handler is retired in Phase 5.
module Lyric.Cli.SelfHostedMsilProject

open System
open System.IO
open System.Reflection

/// Process-wide cache of the resolved delegate.  The driver compile happens
/// once per process; subsequent calls reuse the loaded method handle.
let private bridgeLock = obj ()
let mutable private resolved
    : (System.Collections.Generic.List<string>
        -> string
        -> string
        -> System.Collections.Generic.List<string>
        -> bool) option =
    None

/// Reflect out the `compileProjectToMsilEncoded` entry point on
/// `Msil.Bridge.Program`.  The driver compile is delegated to
/// `SelfHostedMsil.compileToDll` (called once per process via its own
/// lazy initialisation) — running it first guarantees the Lyric.Msil.Bridge.dll
/// is sitting in the stdlib cache by the time we look it up.
let private resolveDelegate ()
    : System.Collections.Generic.List<string>
        -> string
        -> string
        -> System.Collections.Generic.List<string>
        -> bool =
    // Force the bridge DLL to land in the cache.  The empty driver compile
    // is the same one `SelfHostedMsil.compileToDll` triggers on its first
    // call — running a no-op compile here gives us the side effect without
    // needing access to the private `ensureLyricMsilBridgeAssembly` helper.
    let scratch =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-msil-bridge-warmup-%d" (System.Diagnostics.Process.GetCurrentProcess().Id))
    Directory.CreateDirectory scratch |> ignore
    let scratchDll = Path.Combine(scratch, "WarmUp.dll")
    let _ = SelfHostedMsil.compileToDll "package WarmUp\nfunc main(): Unit { }\n" scratchDll
    try Directory.Delete(scratch, true) with _ -> ()

    // Now the cached Lyric.Msil.Bridge.dll exists.  Find it the same way
    // SelfHostedMsil.fs does.
    let bridgeDll =
        Lyric.Emitter.Emitter.stdlibAssemblyPaths ()
        |> List.tryFind (fun p ->
            let n = Path.GetFileNameWithoutExtension p
            n = "Lyric.Msil.Bridge")
    let dll =
        match bridgeDll with
        | Some p -> p
        | None   ->
            failwith "self-hosted MSIL project bridge: 'Lyric.Msil.Bridge.dll' not in stdlib cache"

    let asm = SelfHostedBridge.loadFromCache dll
    let progType =
        match Option.ofObj (asm.GetType "Msil.Bridge.Program") with
        | Some t -> t
        | None -> failwithf "self-hosted MSIL project bridge: 'Msil.Bridge.Program' missing in %s" dll

    let listOfStringType = typeof<System.Collections.Generic.List<string>>
    let m =
        match Option.ofObj
                (progType.GetMethod(
                    "compileProjectToMsilEncoded",
                    [| listOfStringType
                       typeof<string>
                       typeof<string>
                       listOfStringType |])) with
        | Some m when m.IsStatic -> m
        | _ ->
            failwith
                "self-hosted MSIL project bridge: static 'compileProjectToMsilEncoded(List<string>,string,string,List<string>)' missing"

    fun (specLines: System.Collections.Generic.List<string>)
        (assemblyName: string)
        (outputPath: string)
        (stdlibSources: System.Collections.Generic.List<string>) ->
        match Option.ofObj
                (m.Invoke(null,
                          [| box specLines
                             box assemblyName
                             box outputPath
                             box stdlibSources |])) with
        | Some o -> unbox<bool> o
        | None   -> false

let private getDelegate ()
    : System.Collections.Generic.List<string>
        -> string
        -> string
        -> System.Collections.Generic.List<string>
        -> bool =
    lock bridgeLock (fun () ->
        match resolved with
        | None ->
            let fn = resolveDelegate ()
            resolved <- Some fn
            fn
        | Some r -> r)

/// Write a minimal `.runtimeconfig.json` next to `dllPath` so `dotnet exec`
/// can locate the runtime.  Copied from `SelfHostedMsil.fs` to keep the
/// shim self-contained.
let private writeRuntimeConfig (dllPath: string) : unit =
    let configPath =
        let changed = Path.ChangeExtension(dllPath, ".runtimeconfig.json")
        match Option.ofObj changed with
        | Some p -> p
        | None   -> dllPath + ".runtimeconfig.json"
    let v = System.Environment.Version
    let json =
        "{\n" +
        "  \"runtimeOptions\": {\n" +
        (sprintf "    \"tfm\": \"net%d.%d\",\n" v.Major v.Minor) +
        "    \"framework\": {\n" +
        "      \"name\": \"Microsoft.NETCore.App\",\n" +
        (sprintf "      \"version\": \"%s\"\n" (v.ToString())) +
        "    }\n" +
        "  }\n" +
        "}\n"
    File.WriteAllText(configPath, json)

/// Compile a list of `(packageName, source)` payloads into a single bundled
/// .NET PE DLL via the self-hosted multi-package MSIL pipeline.  Returns true
/// on success.  Writes a matching `.runtimeconfig.json` next to `outputPath`
/// so the produced DLL is `dotnet exec`-runnable straight away.
let compileProjectToDll
        (packages: (string * string) list)
        (assemblyName: string)
        (outputPath: string)
        : bool =
    let fn = getDelegate ()
    let specLines = System.Collections.Generic.List<string>()
    for (name, source) in packages do
        // Wire-encoded form: "<pkg name>\t<source text>".  The Lyric side
        // splits on the first tab; subsequent tabs in the source survive.
        specLines.Add(name + "\t" + source)
    let stdlibSources = SelfHostedBridge.findStdlibSources ()
    let ok = fn specLines assemblyName outputPath stdlibSources
    if ok then writeRuntimeConfig outputPath
    ok
