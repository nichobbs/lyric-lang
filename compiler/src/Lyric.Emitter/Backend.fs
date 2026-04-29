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
open System.Reflection.Metadata
open System.Reflection.Metadata.Ecma335
open System.Reflection.PortableExecutable

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

/// Open a persisted-assembly backend.
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

/// Finalise the assembly to disk. The optional `entryPoint` becomes
/// the PE's `Main` token; passing `None` writes a library .dll.
///
/// PersistedAssemblyBuilder doesn't expose a single-call save with
/// entry point, so we lower through `GenerateMetadata` +
/// `ManagedPEBuilder` per the .NET 9 documented pattern.
let save (ctx: EmitContext) (entryPoint: MethodInfo option) : unit =
    match Option.ofObj (Path.GetDirectoryName(ctx.Descriptor.OutputPath)) with
    | Some dir when not (String.IsNullOrEmpty dir) && not (Directory.Exists dir) ->
        Directory.CreateDirectory dir |> ignore
    | _ -> ()

    let mutable ilStream    = Unchecked.defaultof<BlobBuilder>
    let mutable fieldData   = Unchecked.defaultof<BlobBuilder>
    let metadataBuilder =
        ctx.Assembly.GenerateMetadata(&ilStream, &fieldData)

    let entryHandle =
        match entryPoint with
        | Some mi ->
            MetadataTokens.MethodDefinitionHandle(mi.MetadataToken)
        | None ->
            MetadataTokens.MethodDefinitionHandle(0)

    let imageCharacteristics =
        match entryPoint with
        | Some _ -> Characteristics.ExecutableImage
        | None   -> Characteristics.Dll ||| Characteristics.ExecutableImage

    let peHeaderBuilder = PEHeaderBuilder(imageCharacteristics = imageCharacteristics)
    let peBuilder =
        ManagedPEBuilder(
            header           = peHeaderBuilder,
            metadataRootBuilder = MetadataRootBuilder(metadataBuilder),
            ilStream         = ilStream,
            mappedFieldData  = fieldData,
            entryPoint       = entryHandle)

    let peBlob = BlobBuilder()
    peBuilder.Serialize(peBlob) |> ignore

    use fs = File.Create(ctx.Descriptor.OutputPath)
    peBlob.WriteContentTo(fs)

    let cfgPath =
        match Option.ofObj (Path.ChangeExtension(ctx.Descriptor.OutputPath, "runtimeconfig.json")) with
        | Some p -> p
        | None   -> ctx.Descriptor.OutputPath + ".runtimeconfig.json"
    writeRuntimeConfig cfgPath
