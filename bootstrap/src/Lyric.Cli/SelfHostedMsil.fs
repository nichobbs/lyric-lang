/// Bridge from the F# `lyric` CLI to the self-hosted MSIL compilation pipeline
/// (`Msil.Bridge` — Phase R6).  Chains the self-hosted lexer → parser → codegen
/// → MSIL lowering → PE writer in a single in-process call via reflection,
/// avoiding any subprocess round-trip.
///
/// Strategy: compile a tiny "driver" Lyric program whose only job is to
/// `import Msil.Bridge`.  The emitter precompiles `Msil.Bridge.dll` into its
/// per-process stdlib cache as a side-effect.  We then `Assembly.LoadFrom`
/// every cached DLL into the AppDomain (so the transitive dependency chain
/// resolves), reflect out the static `compileToMsil(string, string)` entry
/// point on `Msil.Bridge.Program`, and cache the resulting delegate for
/// subsequent calls in the same process.
module Lyric.Cli.SelfHostedMsil

open System
open System.Reflection
open Lyric.Emitter

/// Source of the throwaway driver program.  The empty `main` is the minimum
/// the emitter accepts; the `import Msil.Bridge` triggers the stdlib precompile
/// path that drops `Lyric.Msil.Bridge.dll` into the cache returned by
/// `Emitter.stdlibAssemblyPaths`.
let private driverSource = """package Msil.MsilBridge
import Msil.Bridge

func main(): Unit { }
"""

/// Process-wide cache of the resolved delegate.  The driver compile is the
/// slow part (~3-5 s on a cold cache); we only do it once per `lyric`
/// invocation that touches the self-hosted MSIL emitter.
let private bridgeLock = obj ()
let private resolved : (string -> string -> System.Collections.Generic.List<string> -> string -> bool) option ref = ref None

/// Compile the driver source so the emitter produces and caches
/// `Lyric.Msil.Bridge.dll`.  Returns the absolute path to it.
let private ensureLyricMsilBridgeAssembly () : string =
    Lyric.Cli.SelfHostedBridge.compileBridgeDriver
        "lyric-msil-bridge"
        driverSource
        "Lyric.Msil.MsilBridge"
        "Lyric.Msil.Bridge"
        "self-hosted MSIL bridge"

/// Reflect out the `compileToMsilWithVersion` entry point and stash it in
/// `resolved`.  The 4th parameter is a `[package].version` string (empty
/// = no version threaded; bridge falls back to `0.0.0.0`).  See #1364
/// for the threading wiring.
let private resolveDelegates () : string -> string -> System.Collections.Generic.List<string> -> string -> bool =
    let dll = ensureLyricMsilBridgeAssembly ()
    let asm = Lyric.Cli.SelfHostedBridge.loadFromCache dll
    let progType =
        match Option.ofObj (asm.GetType "Msil.Bridge.Program") with
        | Some t -> t
        | None ->
            failwithf "self-hosted MSIL bridge: 'Msil.Bridge.Program' type missing from %s" dll

    let listOfStringType = typeof<System.Collections.Generic.List<string>>
    let compileToMsilM =
        match Option.ofObj (progType.GetMethod("compileToMsilWithVersion", [| typeof<string>; typeof<string>; listOfStringType; typeof<string> |])) with
        | Some m when m.IsStatic -> m
        | _ -> failwithf "self-hosted MSIL bridge: static method 'compileToMsilWithVersion(string,string,List<string>,string)' not found on Msil.Bridge.Program"

    let compileToMsilFn
        (source: string)
        (outputPath: string)
        (stdlibSources: System.Collections.Generic.List<string>)
        (packageVersion: string) : bool =
        match Option.ofObj (compileToMsilM.Invoke(null, [| box source; box outputPath; box stdlibSources; box packageVersion |])) with
        | Some o -> unbox<bool> o
        | None   -> false

    compileToMsilFn

let private getDelegate () : string -> string -> System.Collections.Generic.List<string> -> string -> bool =
    Lyric.Cli.SelfHostedBridge.lockOnce bridgeLock resolved resolveDelegates

/// Compile `source` to a .NET PE DLL at `outputPath` using the self-hosted
/// `Msil.Bridge` pipeline, threading `packageVersion` through to the
/// Assembly row and embedded `Lyric.Contract` resource.  Empty
/// `packageVersion` falls back to the legacy `0.0.0.0` default (#1364).
/// Returns true on success, false on parse errors or write failure.
let compileToDllWithVersion (source: string) (outputPath: string)
                             (packageVersion: string) : bool =
    let fn = getDelegate ()
    let stdlibSources = Lyric.Cli.SelfHostedBridge.findStdlibSources ()
    let ok = fn source outputPath stdlibSources packageVersion
    if ok then Lyric.Cli.SelfHostedBridge.writeRuntimeConfig outputPath
    ok

/// Forwarder for callers that don't have a manifest version available;
/// delegates to `compileToDllWithVersion` with an empty version string.
let compileToDll (source: string) (outputPath: string) : bool =
    compileToDllWithVersion source outputPath ""
