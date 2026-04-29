/// Persistent assembly backend. Wraps `System.Reflection.Emit`'s
/// .NET-9 `PersistedAssemblyBuilder` so the rest of the emitter can
/// stay backend-agnostic. If we later swap to
/// `System.Reflection.Metadata` for tighter PE control (private-field
/// reflection sealing per Q002, AOT compatibility per §21 of the
/// MSIL strategy doc), only this file changes.
module Lyric.Emitter.Backend

open System
open System.IO
open System.Reflection
open System.Reflection.Emit

/// Description of the assembly to emit. `Name` becomes both the
/// assembly identity and the runtime entry-point class name (Lyric
/// packages map to namespaces per §3 of the MSIL strategy doc, but
/// the file containing a `func main` lifts that function to a class
/// whose name matches the assembly).
type AssemblyDescriptor =
    { Name:        string
      Version:     Version
      OutputPath:  string }

/// Handle returned to the emitter once the backend is initialised.
/// The emitter calls into `ModuleBuilder` / `TypeBuilder` /
/// `MethodBuilder` to define types and methods; `save` finalises the
/// assembly to disk.
type EmitContext =
    { Assembly:    PersistedAssemblyBuilder
      Module:      ModuleBuilder
      Descriptor:  AssemblyDescriptor }

/// Open a persisted-assembly backend. The PE that lands at
/// `OutputPath` is consumable by `dotnet exec` once the matching
/// `*.runtimeconfig.json` is written next to it (handled by the
/// emitter, not the backend).
let create (desc: AssemblyDescriptor) : EmitContext =
    let asmName = AssemblyName(desc.Name)
    asmName.Version <- desc.Version
    // Reference the runtime's own Object/String/etc. via the
    // currently-loaded mscorlib.
    let coreAssembly = typeof<Object>.Assembly
    let asm = PersistedAssemblyBuilder(asmName, coreAssembly)
    let m = asm.DefineDynamicModule(desc.Name)
    { Assembly = asm; Module = m; Descriptor = desc }

/// Emit the runtimeconfig.json that lets `dotnet exec out.dll` find a
/// suitable .NET 9 host. Without this file the runtime aborts with
/// "no runtimeconfig.json present" before the entry point runs.
let private writeRuntimeConfig (path: string) : unit =
    let config = """{
  "runtimeOptions": {
    "tfm": "net9.0",
    "framework": {
      "name": "Microsoft.NETCore.App",
      "version": "9.0.0"
    }
  }
}
"""
    File.WriteAllText(path, config)

/// Finalise the assembly to disk. Must be called after every type
/// has been `CreateTypeInfo()`-completed by the emitter.
let save (ctx: EmitContext) : unit =
    match Option.ofObj (Path.GetDirectoryName(ctx.Descriptor.OutputPath)) with
    | Some dir when not (String.IsNullOrEmpty dir) && not (Directory.Exists dir) ->
        Directory.CreateDirectory dir |> ignore
    | _ -> ()
    ctx.Assembly.Save(ctx.Descriptor.OutputPath)
    let cfgPath =
        match Option.ofObj (Path.ChangeExtension(ctx.Descriptor.OutputPath, "runtimeconfig.json")) with
        | Some p -> p
        | None   -> ctx.Descriptor.OutputPath + ".runtimeconfig.json"
    writeRuntimeConfig cfgPath
