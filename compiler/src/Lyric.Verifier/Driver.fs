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

    let unknownCount (s: ProofSummary) : int =
        s.Results
        |> List.filter (fun r ->
            match r.Outcome with Unknown _ -> true | _ -> false)
        |> List.length

    let counterexampleCount (s: ProofSummary) : int =
        s.Results
        |> List.filter (fun r ->
            match r.Outcome with Counterexample _ -> true | _ -> false)
        |> List.length

    let hasFailure (s: ProofSummary) : bool =
        s.Results
        |> List.exists (fun r ->
            match r.Outcome with
            | Discharged -> false
            | _          -> true)

    let hasCounterexample (s: ProofSummary) : bool =
        s.Results
        |> List.exists (fun r ->
            match r.Outcome with Counterexample _ -> true | _ -> false)

    let hasErrorDiag (s: ProofSummary) : bool =
        s.Diagnostics
        |> List.exists (fun d -> d.Severity = DiagError)

/// Options threaded through the driver from the CLI.  `AllowUnverified`
/// downgrades `Unknown` outcomes (V0007) from an error to a warning so
/// `lyric prove --allow-unverified` exits 0 in their presence; genuine
/// counterexamples (V0008) remain errors regardless (M4.2 close-out).
type ProveOptions =
    { AllowUnverified: bool }

module ProveOptions =

    let defaults : ProveOptions =
        { AllowUnverified = false }

/// Reconstruct a human-readable counterexample trace from a model and
/// goal.  Tries to identify which hypothesis was violated by substituting
/// the model's variable bindings into each hypothesis term and checking
/// whether it simplifies to `false`.  The trace is appended after the
/// raw variable bindings.
let private buildCounterexampleTrace
        (g: Goal)
        (bindings: CounterexampleBinding list) : string =

    // Build a substitution map from the model bindings.
    let modelSubst : Map<string, Term> =
        bindings
        |> List.choose (fun b ->
            // Try to parse the value as an integer literal.
            let termOpt =
                match System.Int64.TryParse b.Value with
                | true, n -> Some (TLit(LInt n, SInt))
                | _ ->
                    match b.Value with
                    | "true"  -> Some (TLit(LBool true,  SBool))
                    | "false" -> Some (TLit(LBool false, SBool))
                    | _       -> None
            termOpt |> Option.map (fun t -> b.Name, t))
        |> Map.ofList

    // Evaluate a term under the model substitution — collapses TBuiltin
    // nodes whose args all simplified to literals.  Returns `Some bool`
    // only when the result is definitively `true` or `false`.
    let rec eval (t: Term) : Term =
        let t' = Term.subst modelSubst t
        match t' with
        | TBuiltin(BOpAnd, args) ->
            let args' = args |> List.map eval
            if args' |> List.exists (fun a -> a = TLit(LBool false, SBool))
            then TLit(LBool false, SBool)
            elif args' |> List.forall (fun a -> a = TLit(LBool true, SBool))
            then TLit(LBool true, SBool)
            else TBuiltin(BOpAnd, args')
        | TBuiltin(BOpOr, args) ->
            let args' = args |> List.map eval
            if args' |> List.exists (fun a -> a = TLit(LBool true, SBool))
            then TLit(LBool true, SBool)
            elif args' |> List.forall (fun a -> a = TLit(LBool false, SBool))
            then TLit(LBool false, SBool)
            else TBuiltin(BOpOr, args')
        | TBuiltin(BOpNot, [x]) ->
            match eval x with
            | TLit(LBool b, _) -> TLit(LBool (not b), SBool)
            | x'               -> TBuiltin(BOpNot, [x'])
        | TBuiltin(BOpEq, [a; b]) ->
            let a', b' = eval a, eval b
            match a', b' with
            | TLit(LInt x, _),  TLit(LInt y, _)  -> TLit(LBool (x = y), SBool)
            | TLit(LBool x, _), TLit(LBool y, _) -> TLit(LBool (x = y), SBool)
            | _ -> TBuiltin(BOpEq, [a'; b'])
        | TBuiltin(BOpLte, [a; b]) ->
            match eval a, eval b with
            | TLit(LInt x, _), TLit(LInt y, _) -> TLit(LBool (x <= y), SBool)
            | a', b'                            -> TBuiltin(BOpLte, [a'; b'])
        | TBuiltin(BOpLt, [a; b]) ->
            match eval a, eval b with
            | TLit(LInt x, _), TLit(LInt y, _) -> TLit(LBool (x < y), SBool)
            | a', b'                            -> TBuiltin(BOpLt, [a'; b'])
        | TBuiltin(BOpGte, [a; b]) ->
            match eval a, eval b with
            | TLit(LInt x, _), TLit(LInt y, _) -> TLit(LBool (x >= y), SBool)
            | a', b'                            -> TBuiltin(BOpGte, [a'; b'])
        | TBuiltin(BOpGt, [a; b]) ->
            match eval a, eval b with
            | TLit(LInt x, _), TLit(LInt y, _) -> TLit(LBool (x > y), SBool)
            | a', b'                            -> TBuiltin(BOpGt, [a'; b'])
        | TBuiltin(BOpAdd, [a; b]) ->
            match eval a, eval b with
            | TLit(LInt x, _), TLit(LInt y, _) -> TLit(LInt (x + y), SInt)
            | a', b'                            -> TBuiltin(BOpAdd, [a'; b'])
        | TBuiltin(BOpSub, [a; b]) ->
            match eval a, eval b with
            | TLit(LInt x, _), TLit(LInt y, _) -> TLit(LInt (x - y), SInt)
            | a', b'                            -> TBuiltin(BOpSub, [a'; b'])
        | TBuiltin(BOpMul, [a; b]) ->
            match eval a, eval b with
            | TLit(LInt x, _), TLit(LInt y, _) -> TLit(LInt (x * y), SInt)
            | a', b'                            -> TBuiltin(BOpMul, [a'; b'])
        | TBuiltin(BOpImplies, [p; q]) ->
            match eval p with
            | TLit(LBool false, _) -> TLit(LBool true, SBool)
            | TLit(LBool true,  _) -> eval q
            | p'                   -> TBuiltin(BOpImplies, [p'; eval q])
        | _ -> t'

    let isFalse (t: Term) =
        match eval t with
        | TLit(LBool false, _) -> true
        | _ -> false

    let isTrue (t: Term) =
        match eval t with
        | TLit(LBool true, _) -> true
        | _ -> false

    let sb = System.Text.StringBuilder()
    let ln (s: string) = sb.Append(s).Append('\n') |> ignore

    // Show variable bindings.
    ln (renderCounterexample bindings)

    // Identify falsified hypotheses.
    let falsified =
        g.Hypotheses
        |> List.mapi (fun i h -> i, h)
        |> List.filter (fun (_, h) -> isFalse h)
    if not (List.isEmpty falsified) then
        ln "  violated hypotheses:"
        for (i, _) in falsified do
            ln (sprintf "    h%d: %s" (i+1)
                    (PrettyPrint.term g.Hypotheses.[i]))

    // Check the conclusion directly.
    if isFalse g.Conclusion then
        ln (sprintf "  falsified conclusion: %s" (PrettyPrint.term g.Conclusion))
    elif isTrue g.Conclusion then
        ln "  (conclusion holds under model — check hypothesis contradiction)"

    sb.ToString().TrimEnd()

/// Render a discharge outcome into a Diagnostic.  Discharged goals
/// produce no diagnostic (success is silent).
let private outcomeToDiag
        (opts: ProveOptions)
        (g: Goal)
        (outcome: SolverOutcome) : Diagnostic option =
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
                buildCounterexampleTrace g bindings
        Some
            (Diagnostic.error "V0008"
                (sprintf "%s — proof failed (counterexample below)\n%s"
                    (GoalKind.display g.Kind) body)
                g.Origin)
    | Unknown reason ->
        let mk =
            if opts.AllowUnverified then Diagnostic.warning
            else Diagnostic.error
        Some
            (mk "V0007"
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
/// call rule).  When `proofDir` is `Some d`, a cache file
/// `<d>/cache.json` carries discharged outcomes across runs and a
/// persistent z3 session is reused across goals (decision 5c).
/// `opts.AllowUnverified` rewrites V0007 from error to warning.
let proveSourceWithOptions
        (source: string)
        (proofDir: string option)
        (imports: Imports.ImportedPackage list)
        (opts: ProveOptions) : ProofSummary =

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
    let stabilityDiags  = StabilityCheck.checkFile parsed.File

    if not (Mode.VerificationLevel.isProofRequired level) then
        // Pass-through: nothing to verify.  Report the level so
        // `lyric prove` can print "no proof obligations" cleanly.
        { Level       = level
          Diagnostics = parseDiags @ modeDiags @ stabilityDiags
          Results     = [] }
    else

    let goals, vcDiags = VCGen.goalsForFileWithImports parsed.File level imports

    let modeFatal =
        modeDiags |> List.exists (fun d -> d.Severity = DiagError)

    if modeFatal then
        { Level       = level
          Diagnostics = parseDiags @ modeDiags @ stabilityDiags @ vcDiags
          Results     = [] }
    else

    // Persistent z3 session + content-hashed goal cache when a
    // proof directory is configured (decision 5c).  Falls through
    // to the per-goal `discharge` path when no session is
    // available (no z3 binary, or no proofDir to anchor the
    // cache).
    let cachePath =
        proofDir
        |> Option.map (fun d -> Path.Combine(d, "cache.json"))
    let results =
        Solver.withSession cachePath (fun dischargeFn ->
            goals
            |> List.map (fun g ->
                let outcome = dischargeFn g
                let smtPath = writeSmtToDisk proofDir g
                { Goal = g; Outcome = outcome; SmtPath = smtPath }))

    let resultDiags =
        results
        |> List.choose (fun r -> outcomeToDiag opts r.Goal r.Outcome)

    { Level       = level
      Diagnostics = parseDiags @ modeDiags @ stabilityDiags @ vcDiags @ resultDiags
      Results     = results }

/// Backwards-compatible alias preserving the M4.1/M4.2-core call shape.
let proveSourceWithImports
        (source: string)
        (proofDir: string option)
        (imports: Imports.ImportedPackage list) : ProofSummary =
    proveSourceWithOptions source proofDir imports ProveOptions.defaults

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
let proveFileWithOptions
        (path: string)
        (proofDir: string option)
        (dllImports: string list)
        (opts: ProveOptions) : ProofSummary =
    let source = File.ReadAllText path
    let imports, importDiags = Imports.loadMany dllImports
    let summary = proveSourceWithOptions source proofDir imports opts
    { summary with
        Diagnostics = importDiags @ summary.Diagnostics }

let proveFileWithImports
        (path: string)
        (proofDir: string option)
        (dllImports: string list) : ProofSummary =
    proveFileWithOptions path proofDir dllImports ProveOptions.defaults

let proveFile (path: string) (proofDir: string option) : ProofSummary =
    proveFileWithImports path proofDir []
