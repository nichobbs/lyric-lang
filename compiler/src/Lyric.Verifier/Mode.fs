/// Verification levels (`08-contract-semantics.md` §3.1, D013).
///
/// A package's level is the file-level annotation in its source.
/// `runtime_checked` is the implicit default when no annotation is
/// present.
module Lyric.Verifier.Mode

open Lyric.Lexer
open Lyric.Parser.Ast

/// The four levels in `08-contract-semantics.md` §3.1.
///
/// The partial order is `Axiom > ProofRequired{,Unsafe} > RuntimeChecked`
/// (per `15-phase-4-proof-plan.md` §3).
type VerificationLevel =
    /// `@runtime_checked` (default).  Contracts evaluated at runtime.
    | RuntimeChecked
    /// `@proof_required`.  Contracts produce VCs.
    | ProofRequired
    /// `@proof_required(unsafe_blocks_allowed)`.  As above, but
    /// `unsafe { ... }` blocks may appear.
    | ProofRequiredUnsafe
    /// `@proof_required(checked_arithmetic)`.  Adds overflow VCs.
    | ProofRequiredChecked
    /// `@axiom`.  No body verified; postconditions trusted.
    | Axiom

module VerificationLevel =

    let allowsRuntimeAsserts (lvl: VerificationLevel) : bool =
        match lvl with
        | RuntimeChecked -> true
        | _              -> false

    let isProofRequired (lvl: VerificationLevel) : bool =
        match lvl with
        | ProofRequired | ProofRequiredUnsafe | ProofRequiredChecked -> true
        | _ -> false

    /// `15-phase-4-proof-plan.md` §3: the partial order.  `caller`
    /// may call `callee` iff `callee.level >= caller.level`.
    let dominates (callee: VerificationLevel) (caller: VerificationLevel) : bool =
        let rank lvl =
            match lvl with
            | RuntimeChecked       -> 0
            | ProofRequired
            | ProofRequiredUnsafe
            | ProofRequiredChecked -> 1
            | Axiom                -> 2
        rank callee >= rank caller

    let display (lvl: VerificationLevel) : string =
        match lvl with
        | RuntimeChecked       -> "@runtime_checked"
        | ProofRequired        -> "@proof_required"
        | ProofRequiredUnsafe  -> "@proof_required(unsafe_blocks_allowed)"
        | ProofRequiredChecked -> "@proof_required(checked_arithmetic)"
        | Axiom                -> "@axiom"

/// Look up a single annotation by its head name (`runtime_checked`,
/// `proof_required`, `axiom`) on a list of file-level annotations.
let private findAnnotation (name: string) (anns: Annotation list) : Annotation option =
    anns |> List.tryFind (fun a ->
        match a.Name.Segments with
        | [seg] -> seg = name
        | _     -> false)

/// Read the modifier of a `@proof_required(...)` annotation: returns
/// `unsafe_blocks_allowed`, `checked_arithmetic`, or none.
let private proofRequiredModifier (ann: Annotation) : string option =
    ann.Args
    |> List.tryPick (fun arg ->
        match arg with
        | ABare(name, _) -> Some name
        | _              -> None)

/// Resolve a source file's verification level from its file-level
/// annotations.  Multiple level annotations are an error reported
/// at the first redundant one.
let levelOfFile (file: SourceFile) : VerificationLevel * Diagnostic list =
    let anns = file.FileLevelAnnotations
    let runtime = findAnnotation "runtime_checked" anns
    let proof   = findAnnotation "proof_required"  anns
    let axiom   = findAnnotation "axiom"           anns

    let candidates =
        [ runtime; proof; axiom ] |> List.choose id

    let conflict (a1: Annotation) (a2: Annotation) =
        Diagnostic.error
            "V0010"
            (sprintf "package declares both %s and %s; pick one"
                (a1.Name.Segments |> String.concat ".")
                (a2.Name.Segments |> String.concat "."))
            a2.Span

    let diags =
        match candidates with
        | a1 :: a2 :: _ -> [ conflict a1 a2 ]
        | _             -> []

    let level =
        match axiom, proof, runtime with
        | Some _, _,    _    -> Axiom
        | _,      Some p, _  ->
            match proofRequiredModifier p with
            | Some "unsafe_blocks_allowed" -> ProofRequiredUnsafe
            | Some "checked_arithmetic"    -> ProofRequiredChecked
            | None                          -> ProofRequired
            | Some other ->
                // Unknown modifier — report and degrade to plain.
                ProofRequired
        | _,      _,    Some _ -> RuntimeChecked
        | None,   None, None   -> RuntimeChecked

    let modifierDiag =
        proof
        |> Option.bind (fun p ->
            match proofRequiredModifier p with
            | Some m when m <> "unsafe_blocks_allowed" && m <> "checked_arithmetic" ->
                Some (Diagnostic.error
                        "V0011"
                        (sprintf "unknown @proof_required modifier '%s'; expected unsafe_blocks_allowed or checked_arithmetic" m)
                        p.Span)
            | _ -> None)
        |> Option.toList

    level, diags @ modifierDiag

/// Per-function verification level: same as its containing file
/// unless overridden by a function-level annotation (rare; only
/// `@axiom` on individual extern declarations).
let levelOfFunction
        (fileLevel: VerificationLevel)
        (decl: FunctionDecl)
        : VerificationLevel =
    let isAxiom =
        decl.Annotations |> List.exists (fun a ->
            match a.Name.Segments with
            | ["axiom"] -> true
            | _ -> false)
    if isAxiom then Axiom else fileLevel

/// Whether a function is annotated `@pure` (see
/// `08-contract-semantics.md` §4.3).  `@pure` is admissible from
/// runtime-checked into proof-required call sites.
let isPure (decl: FunctionDecl) : bool =
    decl.Annotations |> List.exists (fun a ->
        match a.Name.Segments with
        | ["pure"] -> true
        | _ -> false)
