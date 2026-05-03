/// Cross-package contract loading for the verifier
/// (`15-phase-4-proof-plan.md` §3.2 — D-progress-086).
///
/// Reads the embedded `Lyric.Contract` (JSON) and `Lyric.Proof`
/// (binary) resources from each imported assembly, parses them,
/// and presents a bundled view to the mode checker, the VC
/// generator, and the theory layer.
module Lyric.Verifier.Imports

open System.IO
open Lyric.Lexer
open Lyric.Emitter

/// Bundled cross-package metadata for one imported assembly.
type ImportedPackage =
    { /// Dotted package path, e.g. "Std.Math".
      Name:     string
      /// Contract metadata (level + per-decl pure/requires/ensures/body).
      Contract: ContractMeta.Contract
      /// Proof-only metadata (type representations).  `None` when
      /// the imported assembly was built before format-2 (no
      /// `Lyric.Proof` resource present).
      Proof:    ProofMeta.ProofMeta option
      /// Path to the .dll the metadata was extracted from.
      DllPath:  string }

/// Errors produced when loading.  Renderable to a verifier
/// diagnostic; the verifier degrades gracefully (treats the
/// import as if it were a runtime-checked black box) when a
/// load fails.
type ImportLoadError =
    | DllMissing       of path: string
    | NoContract       of dllPath: string
    | MalformedContract of dllPath: string

let private renderError (err: ImportLoadError) : string =
    match err with
    | DllMissing p          -> sprintf "verifier import: '%s' not found" p
    | NoContract p          -> sprintf "verifier import: '%s' has no Lyric.Contract resource" p
    | MalformedContract p   -> sprintf "verifier import: '%s' has a malformed Lyric.Contract resource" p

let toDiagnostic (err: ImportLoadError) : Diagnostic =
    Diagnostic.warning
        "V0030"
        (renderError err)
        (Span.pointAt Position.initial)

/// Load one DLL into an `ImportedPackage`.  The proof resource is
/// optional; its absence is silent (verifier degrades to opaque
/// types only).
let loadOne (dllPath: string) : Result<ImportedPackage, ImportLoadError> =
    if not (File.Exists dllPath) then Error (DllMissing dllPath)
    else
    match ContractMeta.readFromAssembly dllPath with
    | None -> Error (NoContract dllPath)
    | Some json ->
        match ContractMeta.parseFromJson json with
        | None -> Error (MalformedContract dllPath)
        | Some contract ->
            let proof = ProofMeta.readFromAssembly dllPath
            Ok
                { Name     = contract.PackageName
                  Contract = contract
                  Proof    = proof
                  DllPath  = dllPath }

/// Load every DLL.  Errors are turned into warning diagnostics —
/// the verifier never *fails* on a missing import; it just loses
/// the cross-package facts the import would have provided.
let loadMany (paths: string list)
        : ImportedPackage list * Diagnostic list =
    paths
    |> List.fold
        (fun (acc, diags) p ->
            match loadOne p with
            | Ok ip -> ip :: acc, diags
            | Error err -> acc, toDiagnostic err :: diags)
        ([], [])
    |> fun (xs, ds) -> List.rev xs, List.rev ds

/// Look up a callee by its (package, name) pair across the import
/// list.  Returns the matching `ContractDecl` or `None`.
let findDecl
        (imports: ImportedPackage list)
        (pkg: string)
        (name: string) : ContractMeta.ContractDecl option =
    imports
    |> List.tryFind (fun ip -> ip.Name = pkg)
    |> Option.bind (fun ip ->
        ip.Contract.Decls
        |> List.tryFind (fun d -> d.Name = name && d.Kind = "func"))

/// Look up a callee by its leaf name (no package qualification)
/// across all imports — used when the source uses a bare reference
/// to a `pub use`d helper.  Returns the *first* matching package
/// and decl.
let findDeclByLeaf
        (imports: ImportedPackage list)
        (name: string) : (ImportedPackage * ContractMeta.ContractDecl) option =
    imports
    |> List.tryPick (fun ip ->
        ip.Contract.Decls
        |> List.tryFind (fun d -> d.Name = name && d.Kind = "func")
        |> Option.map (fun d -> ip, d))

/// Look up a type by its leaf name across all imports.  Used by
/// the theory layer to discover datatype declarations for the
/// SMT encoding.
let findTypeByLeaf
        (imports: ImportedPackage list)
        (name: string) : (ImportedPackage * ProofMeta.ProofType) option =
    imports
    |> List.tryPick (fun ip ->
        match ip.Proof with
        | None -> None
        | Some pm ->
            pm.Types
            |> List.tryFind (fun t -> t.Name = name)
            |> Option.map (fun t -> ip, t))

/// Resolve a package's level from its contract.
let levelStringToMode (s: string) : Mode.VerificationLevel =
    match s with
    | "axiom"                                   -> Mode.Axiom
    | "proof_required"                          -> Mode.ProofRequired
    | "proof_required(unsafe_blocks_allowed)"   -> Mode.ProofRequiredUnsafe
    | "proof_required(checked_arithmetic)"      -> Mode.ProofRequiredChecked
    | _                                          -> Mode.RuntimeChecked
