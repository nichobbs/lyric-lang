/// Tests for the stability-annotation analysis (Q011 / D040).
/// S0001 — stable pub func calls @experimental callee.
/// S0002 — @stable and @experimental both present on the same item.
module Lyric.Verifier.Tests.StabilityCheckTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Parser
open Lyric.Verifier.StabilityCheck

let private parseAndCheck (src: string) =
    let parsed = parse src
    Expect.isFalse
        (parsed.Diagnostics |> List.exists (fun d -> d.Severity = DiagError))
        (sprintf "expected clean parse:\n%A" parsed.Diagnostics)
    checkFile parsed.File

let private hasDiag (code: string) (diags: Diagnostic list) =
    diags |> List.exists (fun d -> d.Code = code)

let tests =
    testList "Verifier — StabilityCheck (S0001/S0002)" [

        // ----------------------------------------------------------------
        // stabilityOfAnnotations unit tests
        // ----------------------------------------------------------------

        test "no annotation yields Unmarked" {
            let result = stabilityOfAnnotations []
            Expect.equal result Unmarked "empty annotation list is Unmarked"
        }

        test "@experimental annotation yields Experimental" {
            let src = """
                package P
                @experimental
                pub func f(): Unit { }
                """
            let parsed = parse src
            let item = parsed.File.Items |> List.find (fun it ->
                match it.Kind with
                | Lyric.Parser.Ast.IFunc fn -> fn.Name = "f"
                | _ -> false)
            let stab = stabilityOfItem item
            Expect.equal stab Experimental "@experimental yields Experimental"
        }

        test "@stable(since=...) annotation yields Stable" {
            let src = """
                package P
                @stable(since="1.0")
                pub func g(): Unit { }
                """
            let parsed = parse src
            let item = parsed.File.Items |> List.find (fun it ->
                match it.Kind with
                | Lyric.Parser.Ast.IFunc fn -> fn.Name = "g"
                | _ -> false)
            let stab = stabilityOfItem item
            Expect.equal stab (Stable "1.0") "@stable(since=\"1.0\") yields Stable \"1.0\""
        }

        // ----------------------------------------------------------------
        // S0002: @stable + @experimental conflict
        // ----------------------------------------------------------------

        test "S0002 fires when @stable and @experimental both present" {
            let src = """
                package P
                @stable(since="1.0")
                @experimental
                pub func bad(): Unit { }
                """
            let diags = parseAndCheck src
            Expect.isTrue (hasDiag "S0002" diags) "expected S0002 for conflicting annotations"
        }

        test "no S0002 for @stable alone" {
            let src = """
                package P
                @stable(since="1.0")
                pub func ok(): Unit { }
                """
            let diags = parseAndCheck src
            Expect.isFalse (hasDiag "S0002" diags) "no S0002 for @stable alone"
        }

        test "no S0002 for @experimental alone" {
            let src = """
                package P
                @experimental
                pub func ok(): Unit { }
                """
            let diags = parseAndCheck src
            Expect.isFalse (hasDiag "S0002" diags) "no S0002 for @experimental alone"
        }

        // ----------------------------------------------------------------
        // S0001: stable pub func calls @experimental callee
        // ----------------------------------------------------------------

        test "S0001 fires when stable pub func calls @experimental callee" {
            let src = """
                package P
                @experimental
                pub func beta(): Int { return 42 }

                @stable(since="1.0")
                pub func stable_caller(): Int { return beta() }
                """
            let diags = parseAndCheck src
            Expect.isTrue (hasDiag "S0001" diags)
                "stable func calling experimental callee should be S0001"
        }

        test "no S0001 when @experimental func calls @experimental callee" {
            let src = """
                package P
                @experimental
                pub func beta(): Int { return 42 }

                @experimental
                pub func also_beta(): Int { return beta() }
                """
            let diags = parseAndCheck src
            Expect.isFalse (hasDiag "S0001" diags)
                "experimental calling experimental is fine"
        }

        test "no S0001 when stable func calls another stable func" {
            let src = """
                package P
                @stable(since="1.0")
                pub func helper(): Int { return 1 }

                @stable(since="1.0")
                pub func caller(): Int { return helper() }
                """
            let diags = parseAndCheck src
            Expect.isFalse (hasDiag "S0001" diags)
                "stable calling stable is fine"
        }

        test "no S0001 when unmarked pub func calls another unmarked pub func" {
            let src = """
                package P
                pub func helper(): Int { return 1 }
                pub func caller(): Int { return helper() }
                """
            let diags = parseAndCheck src
            Expect.isFalse (hasDiag "S0001" diags)
                "unmarked calling unmarked is fine"
        }

        test "no S0001 when unmarked func calls @stable func" {
            let src = """
                package P
                @stable(since="1.0")
                pub func helper(): Int { return 1 }
                pub func caller(): Int { return helper() }
                """
            let diags = parseAndCheck src
            Expect.isFalse (hasDiag "S0001" diags)
                "unmarked calling stable is fine"
        }

        test "S0001 fires when unmarked pub func calls @experimental callee" {
            let src = """
                package P
                @experimental
                pub func beta(): Int { return 42 }

                pub func caller(): Int { return beta() }
                """
            let diags = parseAndCheck src
            Expect.isTrue (hasDiag "S0001" diags)
                "unmarked-stable calling experimental is S0001"
        }

        test "no S0001 for private (non-pub) callers" {
            let src = """
                package P
                @experimental
                pub func beta(): Int { return 42 }

                func private_caller(): Int { return beta() }
                """
            let diags = parseAndCheck src
            Expect.isFalse (hasDiag "S0001" diags)
                "non-pub callers are not subject to the stable-calls-experimental rule"
        }

        test "no S0001 when calling an unknown (imported) name" {
            let src = """
                package P
                import Std.Math

                @stable(since="1.0")
                pub func hypo(a: Int, b: Int): Int { return sqrt(a) }
                """
            let diags = parseAndCheck src
            Expect.isFalse (hasDiag "S0001" diags)
                "unknown imported callee is not flagged (conservative skip)"
        }

        // ----------------------------------------------------------------
        // Contract metadata: stability string encoding
        // ----------------------------------------------------------------

        test "ContractDecl.basic has empty stability" {
            let d = Lyric.Emitter.ContractMeta.ContractDecl.basic "func" "f" "()"
            Expect.equal d.Stability "" "basic decl has empty stability"
        }

        test "buildContract emits stability for @experimental pub func" {
            let src = """
                package Demo
                @experimental
                pub func beta(): Int { return 1 }
                """
            let parsed = parse src
            Expect.isFalse
                (parsed.Diagnostics |> List.exists (fun d -> d.Severity = DiagError))
                "clean parse"
            let contract = Lyric.Emitter.ContractMeta.buildContract parsed.File "0.1.0"
            let betaDecl = contract.Decls |> List.tryFind (fun d -> d.Name = "beta")
            match betaDecl with
            | None -> failtest "beta not in contract"
            | Some d ->
                Expect.equal d.Stability "experimental" "stability = experimental"

        }

        test "buildContract emits stability for @stable pub func" {
            let src = """
                package Demo
                @stable(since="1.0")
                pub func production(): Int { return 1 }
                """
            let parsed = parse src
            Expect.isFalse
                (parsed.Diagnostics |> List.exists (fun d -> d.Severity = DiagError))
                "clean parse"
            let contract = Lyric.Emitter.ContractMeta.buildContract parsed.File "1.0.0"
            let decl = contract.Decls |> List.tryFind (fun d -> d.Name = "production")
            match decl with
            | None -> failtest "production not in contract"
            | Some d ->
                Expect.equal d.Stability "stable:1.0" "stability = stable:1.0"
        }

        // ----------------------------------------------------------------
        // public-api-diff stability-aware breaking-change detection
        // ----------------------------------------------------------------

        test "removing @experimental item is NOT breaking" {
            let experimentalDecl =
                { Lyric.Emitter.ContractMeta.ContractDecl.basic "func" "beta" "()"
                    with Stability = "experimental" }
            let oldC =
                { Lyric.Emitter.ContractMeta.Contract.legacy "Demo" "1.0.0"
                    [] with
                    Lyric.Emitter.ContractMeta.Contract.Decls = [experimentalDecl] }
            let newC =
                Lyric.Emitter.ContractMeta.Contract.legacy "Demo" "2.0.0" []
            let entries = Lyric.Emitter.ContractMeta.diffContracts oldC newC
            Expect.isTrue
                (entries |> List.exists (function
                    | Lyric.Emitter.ContractMeta.DiffRemoved _ -> true
                    | _ -> false))
                "removal recorded in diff"
            Expect.isFalse
                (Lyric.Emitter.ContractMeta.hasBreakingChanges entries)
                "removing experimental surface is not a SemVer major bump"
        }

        test "removing @stable item IS breaking" {
            let stableDecl =
                { Lyric.Emitter.ContractMeta.ContractDecl.basic "func" "production" "()"
                    with Stability = "stable:1.0" }
            let oldC =
                { Lyric.Emitter.ContractMeta.Contract.legacy "Demo" "1.0.0"
                    [] with
                    Lyric.Emitter.ContractMeta.Contract.Decls = [stableDecl] }
            let newC =
                Lyric.Emitter.ContractMeta.Contract.legacy "Demo" "2.0.0" []
            let entries = Lyric.Emitter.ContractMeta.diffContracts oldC newC
            Expect.isTrue
                (Lyric.Emitter.ContractMeta.hasBreakingChanges entries)
                "removing stable surface is a SemVer major bump"
        }

        test "removing unannotated item is breaking (conservative)" {
            let d = Lyric.Emitter.ContractMeta.ContractDecl.basic "func" "plain" "()"
            let oldC =
                { Lyric.Emitter.ContractMeta.Contract.legacy "Demo" "1.0.0"
                    [] with
                    Lyric.Emitter.ContractMeta.Contract.Decls = [d] }
            let newC =
                Lyric.Emitter.ContractMeta.Contract.legacy "Demo" "2.0.0" []
            let entries = Lyric.Emitter.ContractMeta.diffContracts oldC newC
            Expect.isTrue
                (Lyric.Emitter.ContractMeta.hasBreakingChanges entries)
                "unannotated items are conservatively treated as stable"
        }
    ]
