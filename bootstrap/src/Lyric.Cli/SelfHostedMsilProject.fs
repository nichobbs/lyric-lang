/// Bridge from the F# `lyric` CLI test harness to the self-hosted multi-
/// package MSIL pipeline (`Msil.Bridge.compileProjectToMsilWithRestoredEncoded`).
/// Follows the same in-process reflection pattern as `SelfHostedMsil`, but
/// targets the project-level entry point so the slice-3 E2E test in
/// `Lyric.Cli.Tests.SelfHostedRestoredPackageE2ETests` can exercise the full
/// build → load-restored → re-emit pipeline without shelling out to the F#
/// `--internal-project-build` subprocess.
module Lyric.Cli.SelfHostedMsilProject

open System
open System.Reflection
open Lyric.Emitter

let private driverSource = """package Msil.MsilProjectBridge
import Msil.Bridge

func main(): Unit { }
"""

type private CompileFn =
    System.Collections.Generic.List<string>
        -> string
        -> string
        -> System.Collections.Generic.List<string>
        -> System.Collections.Generic.List<string>
        -> string
        -> bool

let private bridgeLock = obj ()
let private resolved : CompileFn option ref = ref None

/// Compile the driver source so the emitter produces and caches
/// `Lyric.Msil.Bridge.dll`.  Delegates to the shared helper in
/// `SelfHostedBridge.compileBridgeDriver`.
let private ensureLyricMsilBridgeAssembly () : string =
    Lyric.Cli.SelfHostedBridge.compileBridgeDriver
        "lyric-msil-project-bridge"
        driverSource
        "Lyric.Msil.MsilProjectBridge"
        "Lyric.Msil.Bridge"
        "self-hosted MSIL project bridge"

let private resolveDelegate () =
    let dll = ensureLyricMsilBridgeAssembly ()
    let asm = Lyric.Cli.SelfHostedBridge.loadFromCache dll
    let progType =
        match Option.ofObj (asm.GetType "Msil.Bridge.Program") with
        | Some t -> t
        | None ->
            failwithf "self-hosted MSIL project bridge: 'Msil.Bridge.Program' type missing from %s" dll

    let listOfStringType = typeof<System.Collections.Generic.List<string>>
    let methodInfo =
        progType.GetMethod(
            "compileProjectToMsilWithRestoredEncoded",
            [| listOfStringType
               typeof<string>
               typeof<string>
               listOfStringType
               listOfStringType
               typeof<string> |])
    match Option.ofObj methodInfo with
    | Some m when m.IsStatic ->
        fun (specLines:        System.Collections.Generic.List<string>)
            (assemblyName:     string)
            (outputPath:       string)
            (stdlibSources:    System.Collections.Generic.List<string>)
            (restoredDllPaths: System.Collections.Generic.List<string>)
            (packageVersion:   string) ->
                match Option.ofObj (m.Invoke(null,
                                             [| box specLines
                                                box assemblyName
                                                box outputPath
                                                box stdlibSources
                                                box restoredDllPaths
                                                box packageVersion |])) with
                | Some o -> unbox<bool> o
                | None   -> false
    | _ ->
        failwithf "self-hosted MSIL project bridge: static method 'compileProjectToMsilWithRestoredEncoded' not found on Msil.Bridge.Program"

let private getDelegate () =
    Lyric.Cli.SelfHostedBridge.lockOnce bridgeLock resolved resolveDelegate

/// Compile a multi-package bundle through the self-hosted MSIL bridge,
/// resolving each entry in `restoredDllPaths` against
/// `Lyric.RestoredPackages.loadRestoredPackage` so cross-assembly imports
/// see the restored deps' public surface at typecheck.  `packageVersion`
/// is the `[package].version` string for the bundled output; an empty
/// string falls back to the legacy `"0.0.0"` placeholder.  Returns true
/// on success, false on parse / type / mode errors, write failure, or
/// any restored-package load failure.
let compileProjectWithRestored
        (packages:         (string * string) list)
        (assemblyName:     string)
        (outputPath:       string)
        (restoredDllPaths: string list)
        (packageVersion:   string) : bool =
    let fn = getDelegate ()
    let specLines = System.Collections.Generic.List<string>()
    for (name, source) in packages do
        specLines.Add(name + "\t" + source)
    let restored = System.Collections.Generic.List<string>()
    for p in restoredDllPaths do restored.Add p
    let stdlibSources = Lyric.Cli.SelfHostedBridge.findStdlibSources ()
    let ok = fn specLines assemblyName outputPath stdlibSources restored packageVersion
    if ok then Lyric.Cli.SelfHostedBridge.writeRuntimeConfig outputPath
    ok
