module Lyric.Cli.Tests.ProveTests

/// End-to-end CLI tests for `lyric prove --json` and
/// `lyric prove --explain --goal <n>`.  The JSON surface is part of
/// the M4.3 frozen public surface (`docs/15-phase-4-proof-plan.md`
/// §9.3 + appendix B); these tests pin down the schema so any
/// downstream tooling — editor extensions, CI gates,
/// `lyric public-api-diff` consumers — can rely on it.

open System
open System.Diagnostics
open System.IO
open System.Text.Json
open System.Text.Json.Nodes
open Expecto

let private cliDll () : string =
    Path.Combine(AppContext.BaseDirectory, "lyric.dll")

let private runCli (args: string list) : string * string * int =
    let psi = ProcessStartInfo()
    psi.FileName <- "dotnet"
    psi.ArgumentList.Add "exec"
    psi.ArgumentList.Add (cliDll ())
    for a in args do psi.ArgumentList.Add a
    psi.UseShellExecute <- false
    psi.RedirectStandardOutput <- true
    psi.RedirectStandardError  <- true
    psi.CreateNoWindow <- true
    match Option.ofObj (Process.Start(psi)) with
    | None -> failwith "Process.Start returned null"
    | Some proc ->
        use proc = proc
        let stdout = proc.StandardOutput.ReadToEnd()
        let stderr = proc.StandardError.ReadToEnd()
        proc.WaitForExit()
        stdout, stderr, proc.ExitCode

let private freshSourcePath (contents: string) : string =
    let dir =
        Path.Combine(Path.GetTempPath(),
                     "lyric-prove-test-" + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory dir |> ignore
    let path = Path.Combine(dir, "p.l")
    File.WriteAllText(path, contents)
    path

/// Discharges trivially under the syntactic checker (no z3 needed).
let private trivialSource =
    "@proof_required\n"
    + "package P\n"
    + "\n"
    + "pub func id(x: Int): Int\n"
    + "  ensures: result == x\n"
    + "{ return x }\n"

let private prop (n: JsonNode) (key: string) : JsonNode option =
    match n with
    | :? JsonObject as o ->
        // Explicit byref disambiguates the .NET 10 2-arg and 3-arg
        // `TryGetPropertyValue` overloads.
        let mutable v : JsonNode | null = null
        if o.TryGetPropertyValue(key, &v) then Option.ofObj v else None
    | _ -> None

let private propStr (n: JsonNode) (key: string) : string =
    match prop n key with
    | Some v -> try v.GetValue<string>() with _ -> ""
    | None -> ""

let private propInt (n: JsonNode) (key: string) : int =
    match prop n key with
    | Some v -> try v.GetValue<int>() with _ -> 0
    | None -> 0

let tests =
    testList "Lyric.Cli.Prove" [

        testCase "[--json] minimal discharged proof emits stable schema" <| fun () ->
            let path = freshSourcePath trivialSource
            let stdout, _stderr, exitCode = runCli ["prove"; path; "--json"]
            Expect.equal exitCode 0 "discharged proofs exit 0"
            // Parse — the schema must be parseable JSON.
            let doc =
                match Option.ofObj (JsonNode.Parse stdout) with
                | Some n -> n
                | None -> failtestf "stdout is not valid JSON:\n%s" stdout
            // Top-level keys: file, level, goals, diagnostics, summary.
            Expect.equal (propStr doc "file") path "file"
            Expect.equal (propStr doc "level") "@proof_required" "level"
            // goals[0]: discharged, model null, kind "ensures".
            let goals =
                match prop doc "goals" with
                | Some (:? JsonArray as a) -> a
                | _ -> failtest "goals missing or not an array"
            Expect.equal goals.Count 1 "exactly one goal"
            let g =
                match Option.ofObj goals.[0] with
                | Some n -> n
                | None   -> failtest "goals[0] is null"
            Expect.equal (propStr g "outcome") "discharged" "outcome"
            Expect.equal (propInt g "index") 0 "index"
            Expect.stringContains (propStr g "kind") "postcondition"
                "goal kind names the postcondition"
            Expect.stringContains (propStr g "label") "id"
                "goal label mentions the function name"
            Expect.isGreaterThan (propInt g "line") 0 "line is set"
            // model is null on discharged.  `Option.ofObj` collapses
            // both "no key" and "JSON null" to None, so probe via the
            // underlying object's `ContainsKey` to distinguish.
            match g with
            | :? JsonObject as o ->
                Expect.isTrue (o.ContainsKey "model")
                    "model key is present on every goal"
                Expect.isTrue (isNull o.["model"])
                    "model is JSON null on a discharged goal"
            | _ -> failtest "goal is not a JsonObject"
            // summary.
            let summary =
                match prop doc "summary" with
                | Some s -> s
                | None   -> failtest "summary missing"
            Expect.equal (propInt summary "total") 1 "summary.total"
            Expect.equal (propInt summary "discharged") 1 "summary.discharged"
            Expect.equal (propInt summary "unknown") 0 "summary.unknown"
            Expect.equal (propInt summary "counterexamples") 0
                "summary.counterexamples"

        testCase "[--json] no-proof-obligation file emits empty goals array" <| fun () ->
            // A @runtime_checked package generates no proof obligations.
            let src = "@runtime_checked\npackage P\npub func f(x: Int): Int { return x }\n"
            let path = freshSourcePath src
            let stdout, _stderr, exitCode = runCli ["prove"; path; "--json"]
            Expect.equal exitCode 0 "no obligations -> exit 0"
            let doc =
                match Option.ofObj (JsonNode.Parse stdout) with
                | Some n -> n
                | None -> failtestf "stdout is not valid JSON:\n%s" stdout
            Expect.equal (propStr doc "level") "@runtime_checked" "level"
            let goals =
                match prop doc "goals" with
                | Some (:? JsonArray as a) -> a
                | _ -> failtest "goals must always be an array"
            Expect.equal goals.Count 0 "zero goals"

        testCase "[--explain --goal 0] prints the Lyric-VC IR for the goal" <| fun () ->
            let path = freshSourcePath trivialSource
            let stdout, _stderr, exitCode =
                runCli ["prove"; path; "--explain"; "--goal"; "0"]
            Expect.equal exitCode 0 "--explain --goal 0 exits 0 on success"
            // The IR block must include the keyword headers and the
            // postcondition's conclusion text.
            Expect.stringContains stdout "Goal 0:" "block header"
            Expect.stringContains stdout "kind:" "kind label"
            Expect.stringContains stdout "hypotheses:" "hypotheses label"
            Expect.stringContains stdout "conclusion:" "conclusion label"
            // The wp/sp calculus substitutes the return expression for
            // `result`, so the conclusion of `id`'s postcondition is
            // `x == x` (Term.subst result -> x).
            Expect.stringContains stdout "x == x" "rendered conclusion"

        testCase "[--explain] without --goal lists every goal index" <| fun () ->
            let path = freshSourcePath trivialSource
            let _stdout, stderr, exitCode = runCli ["prove"; path; "--explain"]
            Expect.equal exitCode 1 "missing --goal exits 1"
            Expect.stringContains stderr "specify a goal index"
                "user-facing error guides them"

        testCase "[--explain --goal N] out of range exits 1 with diagnostic" <| fun () ->
            let path = freshSourcePath trivialSource
            let _stdout, stderr, exitCode =
                runCli ["prove"; path; "--explain"; "--goal"; "99"]
            Expect.equal exitCode 1 "out-of-range goal exits 1"
            Expect.stringContains stderr "out of range"
                "stderr explains the out-of-range index"

        testCase "[--json] preserves diagnostics array shape" <| fun () ->
            // Force a V0001 by importing a runtime_checked stub — but
            // for unit-test simplicity we use an unbounded quantifier
            // (V0006) which is fully syntactic and needs no imports.
            let src =
                "@proof_required\n"
                + "package P\n"
                + "\n"
                + "pub func f(x: Int): Bool\n"
                + "  ensures: forall(y: Int) { y == y }\n"
                + "{ return true }\n"
            let path = freshSourcePath src
            let stdout, _stderr, exitCode = runCli ["prove"; path; "--json"]
            Expect.equal exitCode 1 "V0006 is an error"
            let doc =
                match Option.ofObj (JsonNode.Parse stdout) with
                | Some n -> n
                | None -> failtestf "stdout is not valid JSON:\n%s" stdout
            let diags =
                match prop doc "diagnostics" with
                | Some (:? JsonArray as a) -> a
                | _ -> failtest "diagnostics must be an array"
            // At least one V0006 with severity error.
            let codes =
                [ for i in 0 .. diags.Count - 1 do
                    match Option.ofObj diags.[i] with
                    | Some n -> yield propStr n "code", propStr n "severity"
                    | None   -> () ]
            Expect.contains codes ("V0006", "error")
                "V0006 surfaces in JSON diagnostics"
    ]
