module Lyric.Verifier.Tests.ImportsTests

open Expecto
open Lyric.Emitter
open Lyric.Verifier.Imports

let tests =
    testList "Verifier — Imports" [

        test "level string maps to VerificationLevel" {
            Expect.equal
                (levelStringToMode "runtime_checked") Lyric.Verifier.Mode.RuntimeChecked
                "runtime_checked"
            Expect.equal
                (levelStringToMode "proof_required") Lyric.Verifier.Mode.ProofRequired
                "proof_required"
            Expect.equal
                (levelStringToMode "proof_required(unsafe_blocks_allowed)")
                Lyric.Verifier.Mode.ProofRequiredUnsafe
                "proof_required(unsafe)"
            Expect.equal
                (levelStringToMode "proof_required(checked_arithmetic)")
                Lyric.Verifier.Mode.ProofRequiredChecked
                "proof_required(checked)"
            Expect.equal
                (levelStringToMode "axiom") Lyric.Verifier.Mode.Axiom "axiom"
            Expect.equal
                (levelStringToMode "garbage") Lyric.Verifier.Mode.RuntimeChecked
                "unknown -> runtime_checked"
        }

        test "findDeclByLeaf finds a func across imports" {
            let imp =
                { Name     = "P"
                  Contract =
                      ContractMeta.Contract.legacy "P" "1.0.0"
                          [ ContractMeta.ContractDecl.basic "func" "foo" "()"
                            ContractMeta.ContractDecl.basic "record" "R" "{}" ]
                  Proof    = None
                  DllPath  = "" }
            let result = findDeclByLeaf [imp] "foo"
            match result with
            | Some(_, decl) ->
                Expect.equal decl.Name "foo" "foo"
                Expect.equal decl.Kind "func" "func kind"
            | None -> failtest "should find foo"
        }

        test "findDeclByLeaf does not match record kinds" {
            // Records aren't function callees; findDeclByLeaf
            // filters to `kind = func`.
            let imp =
                { Name     = "P"
                  Contract =
                      ContractMeta.Contract.legacy "P" "1.0.0"
                          [ ContractMeta.ContractDecl.basic "record" "R" "{}" ]
                  Proof    = None
                  DllPath  = "" }
            let result = findDeclByLeaf [imp] "R"
            Expect.isNone result "record not a func"
        }

        test "findTypeByLeaf reads ProofMeta types" {
            let pm : ProofMeta.ProofMeta =
                { PackageName = "P"
                  Version     = "1.0.0"
                  Types       =
                      [ { Name = "Amount"
                          Kind = ProofMeta.PTKRecord
                                    [ { Name     = "value"
                                        TypeRepr = "Int" } ] } ] }
            let imp =
                { Name     = "P"
                  Contract = ContractMeta.Contract.legacy "P" "1.0.0" []
                  Proof    = Some pm
                  DllPath  = "" }
            match findTypeByLeaf [imp] "Amount" with
            | Some(_, t) -> Expect.equal t.Name "Amount" "Amount"
            | None -> failtest "should find Amount"
        }
    ]
