/// SDK root discovery for the `lyric` toolchain.
///
/// Implements `docs/22-distribution-and-tooling.md` §4: locate the installed
/// SDK root by checking `LYRIC_SDK_ROOT` first, then walking up from the CLI
/// binary directory looking for a `lib/Lyric.Stdlib.dll` layout.
///
/// Also supports reading the `Lyric.SdkVersion` embedded resource from a
/// pre-built stdlib DLL (`docs/22` §5) for version-compatibility diagnostics.
module Lyric.Emitter.SdkRoot

open System
open System.IO

/// How the SDK root was discovered.
[<RequireQualifiedAccess>]
type SdkSource =
    /// `LYRIC_SDK_ROOT` environment variable was set and the DLL was found.
    | EnvVar
    /// The `lib/Lyric.Stdlib.dll` layout was found relative to the CLI binary.
    | BinaryRelative
    /// No installed binary stdlib found; source-tree fallback applies.
    | NotFound

/// Summary of the located SDK.
type SdkInfo =
    { /// Install root (e.g. `/usr/local/lib/lyric`).  `None` when not found.
      Root:      string option
      /// Absolute path to `lib/Lyric.Stdlib.dll` inside `Root`.
      StdlibDll: string option
      /// Version tuple `(language_version, stdlib_version, compiler_version, build_date)`
      /// read from the `Lyric.SdkVersion` embedded resource in `StdlibDll`.
      /// `None` when the DLL is absent or carries no version resource (B0042).
      Version:   (string * string * string * string) option
      /// How the SDK root was resolved.
      Source:    SdkSource }

/// Parse the compact JSON written by `emitProject` into the `Lyric.SdkVersion`
/// resource.  Hand-rolled to keep the emitter dependency-free.
let private parseSdkVersionJson (json: string) : (string * string * string * string) option =
    let field (key: string) =
        let prefix = "\"" + key + "\":"
        match json.IndexOf(prefix, StringComparison.Ordinal) with
        | -1 -> None
        | i ->
            let after = json.Substring(i + prefix.Length).TrimStart()
            if after.Length > 0 && after.[0] = '"' then
                let inner = after.Substring 1
                let e = inner.IndexOf '"'
                if e >= 0 then Some (inner.Substring(0, e)) else None
            else None
    match field "language_version", field "stdlib_version",
          field "compiler_version", field "build_date" with
    | Some lv, Some sv, Some cv, Some bd -> Some (lv, sv, cv, bd)
    | _ -> None

/// Read the `Lyric.SdkVersion` managed resource from the DLL at `dllPath`
/// using Mono.Cecil (no AppDomain load, no file lock on Windows).
/// Returns `None` when the DLL is unreadable or the resource is absent.
let tryReadSdkVersion (dllPath: string) : (string * string * string * string) option =
    try
        let asm =
            Mono.Cecil.AssemblyDefinition.ReadAssembly(
                dllPath,
                Mono.Cecil.ReaderParameters(InMemory = true))
        let hit =
            asm.MainModule.Resources
            |> Seq.tryFind (fun r -> r.Name = "Lyric.SdkVersion")
        match hit with
        | Some (:? Mono.Cecil.EmbeddedResource as er) ->
            use stream = er.GetResourceStream()
            use reader = new StreamReader(stream)
            parseSdkVersionJson (reader.ReadToEnd())
        | _ -> None
    with _ -> None

/// Locate the SDK root.  `binaryDir` is typically `AppContext.BaseDirectory`.
///
/// Search order per `docs/22` §4:
///   1. `LYRIC_SDK_ROOT` env-var → check `$LYRIC_SDK_ROOT/lib/Lyric.Stdlib.dll`.
///   2. Walk up from `binaryDir` looking for a `lib/Lyric.Stdlib.dll` sibling.
///   3. If neither found → `Source = NotFound`.
///
/// Diagnostics B0040/B0042 are reported by the caller against the returned info.
let locate (binaryDir: string) : SdkInfo =
    let dllName = "Lyric.Stdlib.dll"
    match Option.ofObj (Environment.GetEnvironmentVariable "LYRIC_SDK_ROOT") with
    | Some root ->
        let dll = Path.Combine(root, "lib", dllName)
        if File.Exists dll then
            { Root      = Some root
              StdlibDll = Some dll
              Version   = tryReadSdkVersion dll
              Source    = SdkSource.EnvVar }
        else
            { Root = None; StdlibDll = None; Version = None; Source = SdkSource.NotFound }
    | None ->
        let mutable dir = Some (DirectoryInfo binaryDir)
        let mutable result : SdkInfo option = None
        while result.IsNone && dir.IsSome do
            let d = dir.Value
            let dll = Path.Combine(d.FullName, "lib", dllName)
            if File.Exists dll then
                result <-
                    Some { Root      = Some d.FullName
                           StdlibDll = Some dll
                           Version   = tryReadSdkVersion dll
                           Source    = SdkSource.BinaryRelative }
            dir <- d.Parent |> Option.ofObj
        match result with
        | Some info -> info
        | None      ->
            { Root = None; StdlibDll = None; Version = None; Source = SdkSource.NotFound }
