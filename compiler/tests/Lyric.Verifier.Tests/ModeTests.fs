module Lyric.Verifier.Tests.ModeTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Parser
open Lyric.Verifier.Mode

let private level (src: string) =
    let parsed = parse src
    let lvl, _ = levelOfFile parsed.File
    lvl

let tests =
    testList "Verifier — verification level parsing" [

        test "no annotation defaults to runtime_checked" {
            let src = "package P\n"
            Expect.equal (level src) RuntimeChecked "default"
        }

        test "@runtime_checked is recognised" {
            let src = "@runtime_checked\npackage P\n"
            Expect.equal (level src) RuntimeChecked "@runtime_checked"
        }

        test "@proof_required is recognised" {
            let src = "@proof_required\npackage P\n"
            Expect.equal (level src) ProofRequired "@proof_required"
        }

        test "@proof_required(unsafe_blocks_allowed)" {
            let src = "@proof_required(unsafe_blocks_allowed)\npackage P\n"
            Expect.equal (level src) ProofRequiredUnsafe "modifier"
        }

        test "@proof_required(checked_arithmetic)" {
            let src = "@proof_required(checked_arithmetic)\npackage P\n"
            Expect.equal (level src) ProofRequiredChecked "modifier"
        }

        test "@axiom is recognised" {
            let src = "@axiom\npackage P\n"
            Expect.equal (level src) Axiom "@axiom"
        }

        test "isProofRequired covers the three @proof_required forms" {
            Expect.isTrue (VerificationLevel.isProofRequired ProofRequired) "plain"
            Expect.isTrue (VerificationLevel.isProofRequired ProofRequiredUnsafe) "unsafe"
            Expect.isTrue (VerificationLevel.isProofRequired ProofRequiredChecked) "checked"
            Expect.isFalse (VerificationLevel.isProofRequired RuntimeChecked) "runtime"
            Expect.isFalse (VerificationLevel.isProofRequired Axiom) "axiom"
        }

        test "dominates: axiom > proof_required > runtime_checked" {
            // callee Axiom may be called by everyone
            Expect.isTrue (VerificationLevel.dominates Axiom RuntimeChecked) "axiom-runtime"
            Expect.isTrue (VerificationLevel.dominates Axiom ProofRequired) "axiom-proof"
            // proof_required can be called by proof_required and runtime_checked,
            // but proof_required calling runtime_checked is rejected.
            Expect.isTrue  (VerificationLevel.dominates ProofRequired ProofRequired) "p-p"
            Expect.isFalse (VerificationLevel.dominates RuntimeChecked ProofRequired) "rc-from-pr"
        }
    ]
