/// Solver back-end: discharge a `Goal` to {unsat, sat, unknown}.
///
/// M4.1 ships two implementations:
///
///   * A *trivial syntactic discharger* that closes goals whose
///     conclusion is structurally `true`, an exact hypothesis, or
///     of shape `P ⇒ P`.  This handles the most common
///     trivially-tautological VCs without needing a solver
///     dependency.
///
///   * A *Z3 shell-out* used when the `z3` binary is on `$PATH`.
///     The `Microsoft.Z3` NuGet bindings are intentionally avoided
///     for the bootstrap (`15-phase-4-proof-plan.md` §7.1 carve-out)
///     so the toolchain stays AOT-clean.
module Lyric.Verifier.Solver

open System
open System.Diagnostics
open System.IO
open Lyric.Verifier.Vcir

type SolverOutcome =
    | Discharged
    | Counterexample of model: string
    | Unknown        of reason: string

/// Parsed shape of a Z3 `(get-model)` block.  Values are kept as the
/// raw S-expression text so we can later swap the formatter out for
/// the Lyric-typed pretty-printer §9.1 calls for.
type CounterexampleBinding =
    { Name:  string
      Sort:  string
      Value: string }

/// Pull `(define-fun NAME () SORT VAL)` clauses out of a Z3 model
/// blob.  Best-effort: unrecognised lines are skipped silently.
let parseModel (modelText: string) : CounterexampleBinding list =
    let lines = modelText.Split('\n') |> Array.toList
    let rec loop acc remaining =
        match remaining with
        | [] -> List.rev acc
        | (line: string) :: rest ->
            let trimmed = line.Trim()
            if trimmed.StartsWith "(define-fun " then
                // Form: (define-fun NAME () SORT
                //          VALUE)
                let header = trimmed.Substring("(define-fun ".Length)
                let parts = header.Split([|' '|], 4, System.StringSplitOptions.RemoveEmptyEntries)
                match parts with
                | [| name; "()"; sort; _ |] | [| name; "()"; sort |] ->
                    // Value is the next line(s) up to the closing paren.
                    let valueLines =
                        rest
                        |> List.takeWhile (fun (l: string) ->
                            not (l.TrimEnd().EndsWith ")"))
                    let lastLine =
                        rest
                        |> List.skip (List.length valueLines)
                        |> List.tryHead
                        |> Option.defaultValue ""
                    let allValueText =
                        valueLines @ [lastLine]
                        |> List.map (fun s -> s.Trim())
                        |> String.concat " "
                    // Strip trailing ')'.
                    let value =
                        let v = allValueText.TrimEnd()
                        if v.EndsWith ")" then
                            v.Substring(0, v.Length - 1).TrimEnd()
                        else v
                    let consumed = List.length valueLines + 1
                    loop ({ Name = name; Sort = sort; Value = value } :: acc)
                         (List.skip consumed rest)
                | _ -> loop acc rest
            else
                loop acc rest
    loop [] lines

/// Render a parsed counterexample into the `name = value` form that
/// the plan's §9.3 human output calls for.  Each binding is one line.
let renderCounterexample (bindings: CounterexampleBinding list) : string =
    if List.isEmpty bindings then "(no model bindings)"
    else
        bindings
        |> List.map (fun b ->
            sprintf "  %s : %s = %s" b.Name b.Sort b.Value)
        |> String.concat "\n"

/// Structural term equality, used by the trivial discharger.  Two
/// terms are equal iff they have the same shape and every leaf
/// matches.  Sort tags are compared too — variables of different
/// sorts are not equal even if their names match.
let rec private termEq (a: Term) (b: Term) : bool =
    match a, b with
    | TVar(n1, s1), TVar(n2, s2) -> n1 = n2 && s1 = s2
    | TLit(l1, _),  TLit(l2, _)  -> l1 = l2
    | TBuiltin(o1, xs), TBuiltin(o2, ys) ->
        o1 = o2 && List.length xs = List.length ys
        && List.forall2 termEq xs ys
    | TApp(n1, xs, _), TApp(n2, ys, _) ->
        n1 = n2 && List.length xs = List.length ys
        && List.forall2 termEq xs ys
    | TIte(c1, a1, b1), TIte(c2, a2, b2) ->
        termEq c1 c2 && termEq a1 a2 && termEq b1 b2
    | _ -> false

/// Trivial syntactic check.  Closes:
///   * the literal `true`,
///   * `P ⇒ P` for any P,
///   * reflexive `(= a a)`, `(<= a a)`, `(>= a a)`, `(iff a a)`,
///   * `(ite c a a)` collapses to `a` recursively,
///   * conjunctions/disjunctions whose closure can be decided
///     pointwise,
///   * any conclusion that appears verbatim among the hypotheses,
///   * conjunctive conclusions where every conjunct is either a
///     tautology or a hypothesis member,
///   * `(=> P Q)` conclusions where, treating P as an extra
///     hypothesis, Q is itself trivially discharged.
let private trivialDischarge (g: Goal) : SolverOutcome option =
    let rec isTautology (t: Term) : bool =
        match t with
        | TLit(LBool true, _) -> true
        | TBuiltin(BOpEq,  [a; b])
        | TBuiltin(BOpIff, [a; b])
        | TBuiltin(BOpLte, [a; b])
        | TBuiltin(BOpGte, [a; b]) when termEq a b -> true
        | TBuiltin(BOpImplies, [p; q]) when termEq p q -> true
        | TBuiltin(BOpAnd, args) -> args |> List.forall isTautology
        | TBuiltin(BOpOr,  args) -> args |> List.exists isTautology
        | TIte(_, a, b) when termEq a b -> true
        | _ -> false

    // Flatten an `And` term into its individual conjuncts (recursing
    // into nested ands).  Used when adopting an implication's
    // antecedent as a hypothesis: `(p ∧ q) ⇒ p` should close because
    // `p` is one of the conjuncts after flattening.
    let rec flattenAnd (t: Term) : Term list =
        match t with
        | TBuiltin(BOpAnd, args) -> args |> List.collect flattenAnd
        | _ -> [t]

    let rec closesGiven (hyps: Term list) (conclusion: Term) : bool =
        if isTautology conclusion then true
        elif hyps |> List.exists (termEq conclusion) then true
        else
        match conclusion with
        | TBuiltin(BOpAnd, conjuncts) ->
            // All-or-nothing: every conjunct must close on its own.
            conjuncts |> List.forall (closesGiven hyps)
        | TBuiltin(BOpImplies, [p; q]) ->
            // Adopt p as a hypothesis (only if it isn't already
            // structurally equal to q — that's the trivial P ⇒ P case
            // already handled above).  Conjunctive antecedents are
            // flattened so `(p ∧ q) ⇒ p` closes via the `p`-in-hyps
            // path on the recursion.
            if termEq p q then true
            else closesGiven (flattenAnd p @ hyps) q
        | _ -> false

    if closesGiven g.Hypotheses g.Conclusion then
        Some Discharged
    else None

/// Locate `z3` on `$PATH`.  Returns `None` if the binary isn't
/// available; the caller then falls through to trivial discharge
/// or `Unknown`.
let private findZ3 () : string option =
    match Option.ofObj (Environment.GetEnvironmentVariable "LYRIC_Z3") with
    | Some explicit when File.Exists explicit -> Some explicit
    | _ ->
        match Option.ofObj (Environment.GetEnvironmentVariable "PATH") with
        | None -> None
        | Some path ->
            let sep =
                if Environment.OSVersion.Platform = PlatformID.Win32NT then ';' else ':'
            let candidates =
                path.Split(sep)
                |> Array.collect (fun dir ->
                    let exe = Path.Combine(dir, "z3")
                    let exeWin = Path.Combine(dir, "z3.exe")
                    [| exe; exeWin |])
            candidates |> Array.tryFind File.Exists

/// Run Z3 on an SMT-LIB blob and return the parsed verdict.
let private invokeZ3 (z3Path: string) (smtSource: string) : SolverOutcome =
    let psi = ProcessStartInfo()
    psi.FileName <- z3Path
    psi.ArgumentList.Add "-in"
    psi.ArgumentList.Add "-T:5"
    psi.RedirectStandardInput  <- true
    psi.RedirectStandardOutput <- true
    psi.RedirectStandardError  <- true
    psi.UseShellExecute <- false
    psi.CreateNoWindow <- true
    try
        match Option.ofObj (Process.Start psi) with
        | None ->
            Unknown "z3 process failed to start"
        | Some proc ->
            use _ = proc
            proc.StandardInput.Write smtSource
            proc.StandardInput.Close()
            let stdout = proc.StandardOutput.ReadToEnd()
            let stderr = proc.StandardError.ReadToEnd()
            proc.WaitForExit()
            let firstLine =
                stdout.Split('\n')
                |> Array.tryHead
                |> Option.map (fun s -> s.Trim())
                |> Option.defaultValue ""
            match firstLine with
            | "unsat"   -> Discharged
            | "sat"     -> Counterexample stdout
            | "unknown" -> Unknown "z3 returned unknown"
            | other     ->
                let detail =
                    if stderr.Length > 0 then stderr else other
                Unknown (sprintf "z3 returned unexpected output: %s" detail)
    with ex ->
        Unknown (sprintf "z3 invocation failed: %s" ex.Message)

/// Discharge a goal.  Tries the trivial discharger first; falls
/// through to z3 if available; otherwise returns `Unknown`.
let discharge (g: Goal) : SolverOutcome =
    match trivialDischarge g with
    | Some outcome -> outcome
    | None ->
        match findZ3 () with
        | Some z3 -> invokeZ3 z3 (Smt.renderGoal g)
        | None    -> Unknown "no SMT solver available (set LYRIC_Z3 or install z3)"

/// Pretty-print a solver outcome for human-facing diagnostics.
let displayOutcome (o: SolverOutcome) : string =
    match o with
    | Discharged          -> "discharged"
    | Counterexample m    -> sprintf "counterexample:\n%s" m
    | Unknown reason      -> sprintf "unknown (%s)" reason
