/// Compile-time feature gating per `docs/24-build-features.md` (D045).
///
/// The v1 surface this module implements:
///
///   * `@cfg(feature = "X")` annotations on top-level items.
///   * Multiple `@cfg` annotations on one item AND together (every
///     predicate must hold).
///   * Any `@cfg(...)` whose form is not `feature = "X"` produces
///     `F0012` (malformed predicate).
///   * If `DeclaredFeatures` is non-empty and the named feature is
///     not declared, emits `F0013` (unknown feature) — typo guard.
///   * The item is *erased* if any `@cfg` evaluates to false.
///
/// Boolean composition (`any` / `all` / `not`) and statement-level
/// gating are deferred to v1.1 per the design note's scope cut.
module Lyric.Emitter.Cfg

open Lyric.Lexer
open Lyric.Parser.Ast

/// Result of evaluating a single `@cfg(...)` annotation.
type private CfgEval =
    /// Predicate holds — keep the item.
    | KEEP
    /// Predicate evaluated false — erase the item.
    | ERASE
    /// Malformed predicate — emit a diagnostic but treat as KEEP so
    /// downstream type-checking still sees the item (less confusing
    /// than silent erasure on a typo).
    | MALFORMED of message: string

let private err (code: string) (msg: string) (span: Span) : Diagnostic =
    Diagnostic.error code msg span

let private warn (code: string) (msg: string) (span: Span) : Diagnostic =
    Diagnostic.warning code msg span

/// True iff the annotation's name path is exactly `cfg`.
let private isCfg (a: Annotation) : bool =
    match a.Name.Segments with
    | [ name ] -> name = "cfg"
    | _ -> false

/// Evaluate one `@cfg(...)` annotation against the active feature set.
///
/// v1 only accepts a single `feature = "X"` argument.  Anything else
/// is a `MALFORMED` result; the caller decides whether to erase or
/// keep.
let private evalCfg
    (active: Set<string>)
    (declared: Set<string>)
    (a: Annotation)
    : CfgEval * Diagnostic list =
    match a.Args with
    | [ AAName ("feature", AVString (name, _), _) ] ->
        let warning =
            if not (Set.isEmpty declared) && not (Set.contains name declared) then
                [ warn "F0013"
                    (sprintf "feature '%s' is not declared in the manifest's [features] section"
                             name)
                    a.Span ]
            else
                []
        let outcome =
            if Set.contains name active then KEEP else ERASE
        outcome, warning
    | _ ->
        MALFORMED
            (sprintf
                "@cfg accepts a single 'feature = \"X\"' argument in v1 (boolean composition is deferred)"),
        []

/// Walk an item's annotations and decide whether the item is erased.
/// Returns `(keep, diagnostics)`.
let private classifyItemAnnotations
    (active: Set<string>)
    (declared: Set<string>)
    (anns: Annotation list)
    (span: Span)
    : bool * Diagnostic list =
    let cfgs = anns |> List.filter isCfg
    if List.isEmpty cfgs then true, []
    else
        let mutable keep = true
        let diags = ResizeArray<Diagnostic>()
        for a in cfgs do
            let outcome, ds = evalCfg active declared a
            for d in ds do diags.Add d
            match outcome with
            | KEEP -> ()
            | ERASE -> keep <- false
            | MALFORMED msg ->
                diags.Add (err "F0012" msg a.Span)
                // Treat malformed as keep — see module doc.
        keep, List.ofSeq diags

/// Apply `@cfg`-driven erasure to a parsed `SourceFile`.  Returns the
/// filtered file plus any diagnostics emitted during evaluation.
///
/// Items annotated with one or more `@cfg(feature = "X")` annotations
/// are dropped from the file when any of those predicates evaluates
/// to false against `active`.  Annotations on the package declaration
/// or at file level (`FileLevelAnnotations`) are processed: a false
/// predicate on the package declaration erases every item in the file
/// (the file is treated as not present).
let applyCfgErasure
    (active: Set<string>)
    (declared: Set<string>)
    (sf: SourceFile)
    : SourceFile * Diagnostic list =
    let allDiags = ResizeArray<Diagnostic>()
    // File-level / package-level cfg first: if any of those predicates
    // evaluate to false, the entire file is erased.
    let fileKeep, fileDiags =
        classifyItemAnnotations active declared sf.FileLevelAnnotations sf.Span
    for d in fileDiags do allDiags.Add d
    if not fileKeep then
        let emptied =
            { sf with Items = []; Imports = [] }
        emptied, List.ofSeq allDiags
    else
        let keptItems =
            sf.Items
            |> List.choose (fun it ->
                let keep, ds =
                    classifyItemAnnotations active declared it.Annotations it.Span
                for d in ds do allDiags.Add d
                if keep then Some it else None)
        { sf with Items = keptItems }, List.ofSeq allDiags
