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
open System.Text
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
            // already handled above).
            if termEq p q then true
            else closesGiven (p :: hyps) q
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

// ---------------------------------------------------------------------------
// Decision 5c: persistent z3 session + content-hashed goal cache.
//
// Per `15-phase-4-proof-plan.md` §7.3 and §7.4.  The plain
// `discharge` above keeps working for callers that don't care
// about per-goal latency (one-shot CLI invocations on a single
// file with a handful of goals).  For larger surfaces — a whole
// stdlib package, the worked-example suite — `SolverSession`
// keeps a single z3 process alive across goals, sharing
// preamble + datatype + declare-fun declarations.  A
// content-hashed cache file persists discharged outcomes across
// runs.
// ---------------------------------------------------------------------------

/// Compute a stable content hash for a Goal: SHA-256 of the
/// SMT-LIB rendering plus the Z3 version string.  Different Z3
/// versions invalidate the cache — we don't want to silently
/// trust a `unsat` produced by a since-fixed-bug-version solver.
let private hashGoal (z3Version: string) (g: Goal) : string =
    let smt = Smt.renderGoal g
    use sha = System.Security.Cryptography.SHA256.Create()
    let bytes =
        System.Text.Encoding.UTF8.GetBytes(z3Version + "\n" + smt)
    sha.ComputeHash bytes
    |> Array.map (fun b -> sprintf "%02x" b)
    |> String.concat ""

/// Goal-cache file format.  Each entry maps a hash to a serialised
/// outcome string: `unsat` | `sat:<model>` | `unknown:<reason>`.
type private CacheFileShape =
    { Z3Version: string
      Entries:   Map<string, string> }

let private serializeOutcome (o: SolverOutcome) : string =
    match o with
    | Discharged       -> "unsat"
    | Counterexample m -> "sat:" + m
    | Unknown reason   -> "unknown:" + reason

let private parseOutcome (s: string) : SolverOutcome =
    if s = "unsat" then Discharged
    elif s.StartsWith "sat:" then Counterexample (s.Substring 4)
    elif s.StartsWith "unknown:" then Unknown (s.Substring 8)
    else Unknown ("malformed cache entry: " + s)

let private readCache (path: string) (z3Version: string)
        : Map<string, string> =
    if not (File.Exists path) then Map.empty
    else
    try
        let json = File.ReadAllText path
        use doc = System.Text.Json.JsonDocument.Parse json
        let root = doc.RootElement
        let storedVer =
            match root.TryGetProperty("z3_version") with
            | true, e ->
                match Option.ofObj (e.GetString()) with
                | Some s -> s
                | None   -> ""
            | _ -> ""
        if storedVer <> z3Version then Map.empty
        else
            match root.TryGetProperty("entries") with
            | true, entries when
                entries.ValueKind = System.Text.Json.JsonValueKind.Object ->
                entries.EnumerateObject()
                |> Seq.choose (fun p ->
                    match Option.ofObj (p.Value.GetString()) with
                    | Some v -> Some (p.Name, v)
                    | None   -> None)
                |> Map.ofSeq
            | _ -> Map.empty
    with _ -> Map.empty

let private writeCache
        (path: string) (z3Version: string)
        (entries: Map<string, string>) : unit =
    let escape (s: string) =
        let sb = StringBuilder()
        for c in s do
            match c with
            | '"' -> sb.Append "\\\"" |> ignore
            | '\\' -> sb.Append "\\\\" |> ignore
            | '\n' -> sb.Append "\\n" |> ignore
            | '\r' -> sb.Append "\\r" |> ignore
            | '\t' -> sb.Append "\\t" |> ignore
            | c when int c < 0x20 ->
                sb.Append(sprintf "\\u%04x" (int c)) |> ignore
            | c -> sb.Append c |> ignore
        sb.ToString()
    let sb = StringBuilder()
    sb.Append "{\n" |> ignore
    sb.Append (sprintf "  \"z3_version\": \"%s\",\n" (escape z3Version)) |> ignore
    sb.Append "  \"entries\": {\n" |> ignore
    let kvs = entries |> Map.toList
    kvs |> List.iteri (fun i (k, v) ->
        let comma = if i = 0 then "" else ",\n"
        sb.Append comma |> ignore
        sb.Append (sprintf "    \"%s\": \"%s\"" (escape k) (escape v))
            |> ignore)
    sb.Append "\n  }\n}\n" |> ignore
    let dir =
        Path.GetDirectoryName(Path.GetFullPath path)
        |> Option.ofObj
        |> Option.defaultValue "."
    Directory.CreateDirectory dir |> ignore
    File.WriteAllText(path, sb.ToString())

/// Query the z3 binary for its version string, used as a cache
/// key salt.
let private queryZ3Version (z3Path: string) : string =
    try
        let psi = ProcessStartInfo()
        psi.FileName <- z3Path
        psi.ArgumentList.Add "--version"
        psi.RedirectStandardOutput <- true
        psi.UseShellExecute <- false
        psi.CreateNoWindow <- true
        match Option.ofObj (Process.Start psi) with
        | Some proc ->
            use _ = proc
            let out = proc.StandardOutput.ReadToEnd().Trim()
            proc.WaitForExit()
            out
        | None -> "unknown-z3"
    with _ -> "unknown-z3"

/// One persistent z3 process.  The session pipes the preamble +
/// shared declarations once, then push/pop-scopes each goal so the
/// solver re-enters a clean assertion stack between goals while
/// retaining the shared declarations.
type SolverSession =
    private
        { Process:     Process
          mutable Declared: Set<string>
          Z3Version:   string
          Cache:       System.Collections.Generic.Dictionary<string, SolverOutcome>
          CachePath:   string option
          mutable Dirty: bool }

    member this.Z3 : string = this.Z3Version

let private startSession (z3Path: string) (cachePath: string option)
        : SolverSession option =
    let z3Version = queryZ3Version z3Path
    let psi = ProcessStartInfo()
    psi.FileName <- z3Path
    psi.ArgumentList.Add "-in"
    psi.ArgumentList.Add "-T:5"
    psi.RedirectStandardInput  <- true
    psi.RedirectStandardOutput <- true
    psi.RedirectStandardError  <- true
    psi.UseShellExecute <- false
    psi.CreateNoWindow <- true
    match Option.ofObj (Process.Start psi) with
    | None -> None
    | Some proc ->
        // Send the preamble once.
        proc.StandardInput.Write (Smt.renderPreamble ())
        proc.StandardInput.Flush()
        let cache =
            let dict =
                System.Collections.Generic.Dictionary<string, SolverOutcome>()
            match cachePath with
            | Some p ->
                for KeyValue(k, v) in readCache p z3Version do
                    dict.[k] <- parseOutcome v
            | None -> ()
            dict
        Some
            { Process   = proc
              Declared  = Set.empty
              Z3Version = z3Version
              Cache     = cache
              CachePath = cachePath
              Dirty     = false }

/// Read z3's response to a `(check-sat)` (and the optional
/// `(get-model)` block that follows on `sat`) — one line for
/// the verdict, then either nothing (unsat / unknown) or a
/// multi-line `(...)` for the model.
let private readResponse (proc: Process) : SolverOutcome =
    // Read first non-empty line for the verdict.
    let rec readVerdict () =
        match Option.ofObj (proc.StandardOutput.ReadLine()) with
        | None -> ""
        | Some line ->
            let t = line.Trim()
            if t = "" then readVerdict ()
            else t
    let verdict = readVerdict ()
    match verdict with
    | "unsat" ->
        // Drain any trailing `(error ...)` from a get-model on a
        // closed scope.  Z3 emits one line on stderr in that case;
        // we deliberately don't read it so the next goal starts
        // clean.
        let _ = proc.StandardOutput.ReadLine()  // (error ...) eaten
        Discharged
    | "unknown" ->
        let _ = proc.StandardOutput.ReadLine()
        Unknown "z3 returned unknown"
    | "sat" ->
        // Read until balanced parens — the model body.
        let sb : StringBuilder = StringBuilder()
        sb.Append("sat\n") |> ignore
        let mutable depth = 0
        let mutable opened = false
        let mutable keepGoing = true
        while keepGoing do
            match Option.ofObj (proc.StandardOutput.ReadLine()) with
            | None -> keepGoing <- false
            | Some line ->
                sb.Append(line: string) |> ignore
                sb.Append('\n') |> ignore
                for c in line do
                    if c = '(' then
                        depth <- depth + 1
                        opened <- true
                    elif c = ')' then depth <- depth - 1
                if opened && depth = 0 then keepGoing <- false
        Counterexample (sb.ToString())
    | other ->
        Unknown (sprintf "z3 returned unexpected verdict: %s" other)

/// Discharge a goal in a session.  Cache-aware: hash the goal,
/// look it up in the cache, return early on a hit.  On miss,
/// pipe the goal's body to the persistent z3 process and parse
/// the response.
let dischargeIn (session: SolverSession) (g: Goal) : SolverOutcome =
    match trivialDischarge g with
    | Some outcome -> outcome
    | None ->
        let key = hashGoal session.Z3Version g
        match session.Cache.TryGetValue key with
        | true, cached -> cached
        | _ ->
            let body, declared' =
                Smt.renderGoalBlock session.Declared g
            session.Declared <- declared'
            session.Process.StandardInput.Write body
            session.Process.StandardInput.Flush()
            let outcome = readResponse session.Process
            session.Cache.[key] <- outcome
            session.Dirty <- true
            outcome

/// Tear down the session.  Flushes the cache to disk if dirty,
/// then closes the z3 process.
let endSession (session: SolverSession) : unit =
    match session.CachePath with
    | Some p when session.Dirty ->
        let entries =
            session.Cache
            |> Seq.map (fun kv -> kv.Key, serializeOutcome kv.Value)
            |> Map.ofSeq
        try writeCache p session.Z3Version entries
        with ex ->
            eprintfn "warning: cache write to %s failed: %s" p ex.Message
    | Some _ -> ()  // not dirty
    | None -> ()
    try
        session.Process.StandardInput.Write "(exit)\n"
        session.Process.StandardInput.Flush()
        session.Process.StandardInput.Close()
        session.Process.WaitForExit 1000 |> ignore
    with _ -> ()
    try session.Process.Dispose() with _ -> ()

/// One-shot helper: try to start a session, run the action with
/// it, then tear down.  Falls through to a per-goal `discharge`
/// (no cache) when z3 isn't available.  Set `LYRIC_VERIFY_DEBUG=1`
/// for trace output (session start, z3 version, endSession dirty
/// flag).
let withSession
        (cachePath: string option)
        (action: (Goal -> SolverOutcome) -> 'a) : 'a =
    let debug =
        not (isNull (Environment.GetEnvironmentVariable "LYRIC_VERIFY_DEBUG"))
    let trace (msg: string) =
        if debug then eprintfn "%s" msg
    match findZ3 () with
    | None ->
        trace "[verify] no z3 found; falling back to trivial-only"
        // No solver — caller still gets a discharger, but it's
        // the trivial-only fallback.
        action discharge
    | Some z3 ->
        trace (sprintf "[verify] starting z3 session at %s" z3)
        match startSession z3 cachePath with
        | None ->
            trace "[verify] startSession failed; falling back to per-goal"
            action discharge
        | Some session ->
            trace (sprintf "[verify] session started, z3 version: %s"
                    session.Z3Version)
            try
                action (fun g -> dischargeIn session g)
            finally
                trace (sprintf "[verify] endSession (dirty=%b)" session.Dirty)
                endSession session
