/// Verifier driver: takes a parsed source file, runs the mode check
/// and VC generator, discharges every goal, and produces a summary.
///
/// (`15-phase-4-proof-plan.md` §§4–8)
module Lyric.Verifier.Driver

open System
open System.IO
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Verifier
open Lyric.Verifier.Vcir
open Lyric.Verifier.Solver

type ProofResult =
    { Goal:    Goal
      Outcome: SolverOutcome
      SmtPath: string option }

type ProofSummary =
    { Level:        Mode.VerificationLevel
      Diagnostics:  Diagnostic list
      Results:      ProofResult list }

module ProofSummary =

    let dischargedCount (s: ProofSummary) : int =
        s.Results
        |> List.filter (fun r ->
            match r.Outcome with Discharged -> true | _ -> false)
        |> List.length

    let totalCount (s: ProofSummary) : int = List.length s.Results

    let hasFailure (s: ProofSummary) : bool =
        s.Results
        |> List.exists (fun r ->
            match r.Outcome with
            | Discharged -> false
            | _          -> true)

    let hasErrorDiag (s: ProofSummary) : bool =
        s.Diagnostics
        |> List.exists (fun d -> d.Severity = DiagError)

/// Render a discharge outcome into a Diagnostic.  Discharged goals
/// produce no diagnostic (success is silent).
let private outcomeToDiag (g: Goal) (outcome: SolverOutcome) : Diagnostic option =
    match outcome with
    | Discharged ->
        None
    | Counterexample model ->
        let bindings = parseModel model
        let body =
            if List.isEmpty bindings then
                let raw =
                    model.Split('\n')
                    |> Array.truncate 6
                    |> String.concat "\n"
                sprintf "raw model:\n%s" raw
            else
                renderCounterexample bindings
        Some
            (Diagnostic.error "V0008"
                (sprintf "%s — proof failed (counterexample below)\n%s"
                    (GoalKind.display g.Kind) body)
                g.Origin)
    | Unknown reason ->
        Some
            (Diagnostic.error "V0007"
                (sprintf "%s — solver returned unknown: %s"
                    (GoalKind.display g.Kind) reason)
                g.Origin)

/// Optionally write the SMT-LIB source for each goal to a sibling
/// `target/proofs/` directory next to the source file.  Returns the
/// emitted path so callers can include it in --explain output.
let private writeSmtToDisk
        (proofDir: string option)
        (g: Goal) : string option =
    match proofDir with
    | None -> None
    | Some dir ->
        Directory.CreateDirectory dir |> ignore
        let path = Path.Combine(dir, sprintf "%s.smt2" g.Label)
        File.WriteAllText(path, Smt.renderGoal g)
        Some path

/// End-to-end: parse + mode-check + VC-gen + discharge.  Carries
/// `imports` (loaded by `Lyric.Verifier.Imports.loadMany`) through
/// to the mode checker (V0001) and the VC generator (cross-package
/// call rule).
let proveSourceWithImports
        (source: string)
        (proofDir: string option)
        (imports: Imports.ImportedPackage list) : ProofSummary =

    let parsed = Lyric.Parser.Parser.parse source
    let parseDiags = parsed.Diagnostics
    let parseFatal =
        parseDiags |> List.exists (fun d ->
            d.Severity = DiagError
            && d.Code.StartsWith "P")

    if parseFatal then
        { Level       = Mode.RuntimeChecked
          Diagnostics = parseDiags
          Results     = [] }
    else

    let level, modeDiags = ModeCheck.checkFileWithImports parsed.File imports

    if not (Mode.VerificationLevel.isProofRequired level) then
        // Pass-through: nothing to verify.  Report the level so
        // `lyric prove` can print "no proof obligations" cleanly.
        { Level       = level
          Diagnostics = parseDiags @ modeDiags
          Results     = [] }
    else

    let goals, vcDiags = VCGen.goalsForFileWithImports parsed.File level imports

    let modeFatal =
        modeDiags |> List.exists (fun d -> d.Severity = DiagError)

    if modeFatal then
        { Level       = level
          Diagnostics = parseDiags @ modeDiags @ vcDiags
          Results     = [] }
    else

    let results =
        goals
        |> List.map (fun g ->
            let outcome = discharge g
            let smtPath = writeSmtToDisk proofDir g
            { Goal = g; Outcome = outcome; SmtPath = smtPath })

    let resultDiags =
        results
        |> List.choose (fun r -> outcomeToDiag r.Goal r.Outcome)

    { Level       = level
      Diagnostics = parseDiags @ modeDiags @ vcDiags @ resultDiags
      Results     = results }

/// Backwards-compatible alias for callers without an imports list.
let proveSource
        (source: string)
        (proofDir: string option) : ProofSummary =
    proveSourceWithImports source proofDir []

/// Convenience: prove an on-disk source file.  `dllImports` is the
/// list of restored / built dependency .dll paths the verifier
/// reads `Lyric.Contract` + `Lyric.Proof` resources from to apply
/// V0001 / cross-package call rule / cross-package datatype
/// encoding.
let proveFileWithImports
        (path: string)
        (proofDir: string option)
        (dllImports: string list) : ProofSummary =
    let source = File.ReadAllText path
    let imports, importDiags = Imports.loadMany dllImports
    let summary = proveSourceWithImports source proofDir imports
    { summary with
        Diagnostics = importDiags @ summary.Diagnostics }

let proveFile (path: string) (proofDir: string option) : ProofSummary =
    proveFileWithImports path proofDir []
