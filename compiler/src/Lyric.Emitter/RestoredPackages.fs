/// Build-time consumer of restored Lyric packages
/// (C8 follow-up to D-progress-077).
///
/// `lyric publish` ships Lyric `.nupkg`s that carry the user's
/// compiled DLL plus an embedded `Lyric.Contract` managed resource
/// (D-progress-031) describing the package's `pub` surface.
/// `lyric restore` populates the standard NuGet cache with the
/// restored package's DLLs.
///
/// This module closes the loop: given a list of restored package
/// references (DLL path + manifest version), it produces
/// `StdlibArtifact`-equivalent records that the emitter's existing
/// import pipeline can consume.  Synthesis works by pasting each
/// contract decl's `Repr` string under a `package <name>` header,
/// running the bootstrap parser + type checker against that
/// synthesised source, and pairing the result with the loaded
/// assembly.  The function bodies are absent from contract Repr
/// (the parser accepts bodyless `pub func` decls — same shape as
/// interface signatures and externs); records, unions, enums
/// already carry their full structural shape.
///
/// Bootstrap-grade scope: function / record / union / enum / opaque
/// / interface / distinct / alias / const items are recognised
/// (matches `ContractMeta.declOf`).  Generic-aware parsing already
/// works because each Repr keeps its `[T]` brackets verbatim.
/// Cross-package symbol references inside a contract Repr (e.g.
/// `pub func parse(): Result[Int, ParseError]` where `Result` lives
/// in `Std.Core`) require the consumer's source to also `import
/// Std.Core` so the identifier resolves — same constraint as
/// hand-written stdlib modules.  When the contract's items
/// reference identifiers the consumer hasn't imported, the type
/// checker surfaces a regular `T0001 unknown name` diagnostic.
module Lyric.Emitter.RestoredPackages

open System
open System.IO
open System.Reflection
open Lyric.Lexer
open Lyric.Parser.Ast

/// One restored Lyric package: name + version + absolute path to
/// its `.dll` in the NuGet cache (the `lyric.toml` consumer
/// already resolved the `~/.nuget/packages/<lower-pkg>/<version>/
/// lib/net10.0/<pkg>.dll` path before handing the ref over).
type RestoredPackageRef =
    { Name:    string
      Version: string
      DllPath: string }

/// Synthesise a Lyric source string from a `Contract`.  Each decl's
/// `Repr` is the parser's canonical surface form; pasting them
/// under a `package <name>` header produces a parseable file the
/// type checker can register as imported items.
///
/// One adjustment: contract Reprs for interfaces don't carry a
/// `{}` body block (the parser requires one), so synthesise an
/// empty body for them.  Other shapes parse verbatim.
let synthesiseSource (contract: ContractMeta.Contract) : string =
    let sb = System.Text.StringBuilder()
    sb.AppendLine ("package " + contract.PackageName) |> ignore
    sb.AppendLine "" |> ignore
    for d in contract.Decls do
        match d.Kind with
        | "interface" -> sb.AppendLine (d.Repr + " {}") |> ignore
        | _ -> sb.AppendLine d.Repr |> ignore
    sb.ToString()

/// Locate a restored package DLL in the standard NuGet cache.
/// NuGet cache convention: `<NUGET_PACKAGES>/<name-lowercased>/
/// <version>/lib/net10.0/<name>.dll`.  `NUGET_PACKAGES` env var
/// overrides; default is `~/.nuget/packages/`.  Returns the first
/// existing DLL path found, or `None`.
let tryLocateRestoredDll (packageName: string) (version: string) : string option =
    let nugetRoot =
        match Option.ofObj (Environment.GetEnvironmentVariable "NUGET_PACKAGES") with
        | Some p -> p
        | None ->
            Path.Combine(
                Environment.GetFolderPath Environment.SpecialFolder.UserProfile,
                ".nuget",
                "packages")
    let pkgLower = packageName.ToLowerInvariant()
    let dll =
        Path.Combine(
            nugetRoot,
            pkgLower,
            version,
            "lib",
            "net10.0",
            packageName + ".dll")
    if File.Exists dll then Some dll else None

/// Synthesised view of a restored package — a parsed + type-
/// checked SourceFile plus the loaded assembly.  Mirrors the
/// emitter's internal `StdlibArtifact` shape so the import
/// pipeline can splice it into the same artifact list it
/// already consumes.
type RestoredArtifact =
    { Reference:    RestoredPackageRef
      Contract:     ContractMeta.Contract
      AssemblyPath: string
      Assembly:     Assembly
      Source:       SourceFile
      Symbols:      Lyric.TypeChecker.SymbolTable
      Signatures:   Map<string, Lyric.TypeChecker.ResolvedSignature> }

/// Errors produced when building a `RestoredArtifact`.  The
/// emitter renders these as a single user-facing diagnostic
/// rather than splattering individual parser / type-check errors
/// (the synthesised source is internal — users care that the
/// package failed to load, not which intermediate token tripped
/// the parser).
type RestoredLoadError =
    | DllMissing       of path: string
    | NoContractResource of dllPath: string
    | MalformedContract  of dllPath: string
    | SynthesisDiagnostics of dllPath: string * diagnostics: Diagnostic list

let private renderError (err: RestoredLoadError) : string =
    match err with
    | DllMissing p ->
        sprintf "restored package: '%s' not found (run `lyric restore` first)" p
    | NoContractResource p ->
        sprintf "restored package: '%s' is missing the `Lyric.Contract` resource — was it published with `lyric publish`?" p
    | MalformedContract p ->
        sprintf "restored package: '%s' carries a malformed `Lyric.Contract` resource" p
    | SynthesisDiagnostics (p, ds) ->
        let count = List.length ds
        sprintf "restored package: '%s' contract did not type-check (%d diagnostic%s); first: %s"
            p count (if count = 1 then "" else "s")
            (match ds with d :: _ -> d.Message | [] -> "(none)")

/// Build a `RestoredArtifact` from a single `RestoredPackageRef`.
/// Reads the DLL, extracts its `Lyric.Contract` resource,
/// synthesises a Lyric source from the contract decls, parses +
/// type-checks the synthesised source, and pairs the result with
/// the loaded assembly.
let loadRestoredPackage
        (ref': RestoredPackageRef) : Result<RestoredArtifact, RestoredLoadError> =
    if not (File.Exists ref'.DllPath) then Error (DllMissing ref'.DllPath)
    else
    match ContractMeta.readFromAssembly ref'.DllPath with
    | None -> Error (NoContractResource ref'.DllPath)
    | Some json ->
        match ContractMeta.parseFromJson json with
        | None -> Error (MalformedContract ref'.DllPath)
        | Some contract ->
            let synthSource = synthesiseSource contract
            let parsed = Lyric.Parser.Parser.parse synthSource
            let parseErrors =
                parsed.Diagnostics
                |> List.filter (fun d -> d.Severity = DiagError)
            if not (List.isEmpty parseErrors) then
                Error (SynthesisDiagnostics (ref'.DllPath, parseErrors))
            else
                // Type-check the synthesised source on its own —
                // imports inside the contract aren't supported in
                // the bootstrap (the contract Repr loses cross-
                // package qualifications).  Type-check failures
                // surface as a single load error.
                let checked' = Lyric.TypeChecker.Checker.check parsed.File
                let checkErrors =
                    checked'.Diagnostics
                    |> List.filter (fun d -> d.Severity = DiagError)
                if not (List.isEmpty checkErrors) then
                    Error (SynthesisDiagnostics (ref'.DllPath, checkErrors))
                else
                    let assembly = Assembly.LoadFrom ref'.DllPath
                    Ok { Reference    = ref'
                         Contract     = contract
                         AssemblyPath = ref'.DllPath
                         Assembly     = assembly
                         Source       = parsed.File
                         Symbols      = checked'.Symbols
                         Signatures   = checked'.Signatures }

/// Render a load error into a fatal Diagnostic that the emit
/// loop surfaces alongside other import-resolution errors.
let toDiagnostic (err: RestoredLoadError) : Diagnostic =
    let zeroSpan = Span.make Position.initial Position.initial
    Diagnostic.error "E901" (renderError err) zeroSpan
