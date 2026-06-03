/// Tests for compile-time feature gating per
/// `docs/24-build-features.md` (D045).
module Lyric.Emitter.Tests.CfgErasureTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Parser
open Lyric.Emitter.Cfg

let private parsedFile (src: string) =
    let p = parse src
    p.File, p.Diagnostics

let tests =
    testList "Lyric.Emitter.Cfg" [

        testCase "no @cfg → no erasure" <| fun () ->
            let sf, _ =
                parsedFile """package P
pub func f(): Int { 1 }
"""
            let result, diags = applyCfgErasure Set.empty Set.empty sf
            Expect.equal (List.length result.Items) 1 "item kept"
            Expect.isEmpty diags "no diagnostics"

        testCase "@cfg(feature = X) erases when X not in active set" <| fun () ->
            let sf, _ =
                parsedFile """package P
@cfg(feature = "logging")
pub func loggedOnly(): Int { 1 }
pub func always(): Int { 2 }
"""
            let result, diags = applyCfgErasure Set.empty Set.empty sf
            Expect.equal (List.length result.Items) 1 "logged item erased, always kept"
            Expect.isEmpty diags "no diagnostics"
            let kept = result.Items |> List.head
            match kept.Kind with
            | Lyric.Parser.Ast.IFunc fn ->
                Expect.equal fn.Name "always" "the surviving func is 'always'"
            | _ -> failtest "expected IFunc"

        testCase "@cfg(feature = X) keeps when X in active set" <| fun () ->
            let sf, _ =
                parsedFile """package P
@cfg(feature = "logging")
pub func loggedOnly(): Int { 1 }
"""
            let result, _ =
                applyCfgErasure (Set.singleton "logging") Set.empty sf
            Expect.equal (List.length result.Items) 1 "item kept"

        testCase "multiple @cfg AND together" <| fun () ->
            let sf, _ =
                parsedFile """package P
@cfg(feature = "logging")
@cfg(feature = "debug")
pub func bothNeeded(): Int { 1 }
"""
            let kept1, _ =
                applyCfgErasure
                    (Set.ofList ["logging"; "debug"]) Set.empty sf
            Expect.equal (List.length kept1.Items) 1 "kept when both active"

            let kept2, _ =
                applyCfgErasure (Set.singleton "logging") Set.empty sf
            Expect.equal (List.length kept2.Items) 0
                "erased when only one of the two predicates holds"

            let kept3, _ = applyCfgErasure Set.empty Set.empty sf
            Expect.equal (List.length kept3.Items) 0
                "erased when neither predicate holds"

        testCase "F0013 fires for feature not declared in manifest" <| fun () ->
            let sf, _ =
                parsedFile """package P
@cfg(feature = "tracinng")
pub func typo(): Int { 1 }
"""
            // Declared = ["tracing"; "logging"]; "tracinng" is a typo.
            let _, diags =
                applyCfgErasure
                    Set.empty (Set.ofList ["tracing"; "logging"]) sf
            let f0013 = diags |> List.filter (fun d -> d.Code = "F0013")
            Expect.equal (List.length f0013) 1
                "exactly one F0013 for the typoed feature"
            Expect.equal (List.head f0013).Severity DiagWarning
                "F0013 is a warning"

        testCase "F0013 suppressed when manifest declares no features" <| fun () ->
            // Empty `declared` set means "manifest has no [features] section";
            // we don't know what's a typo, so suppress F0013.
            let sf, _ =
                parsedFile """package P
@cfg(feature = "anything")
pub func a(): Int { 1 }
"""
            let _, diags = applyCfgErasure Set.empty Set.empty sf
            let f0013 = diags |> List.filter (fun d -> d.Code = "F0013")
            Expect.isEmpty f0013 "F0013 suppressed without a manifest declared set"

        testCase "F0012 fires for malformed @cfg" <| fun () ->
            let sf, _ =
                parsedFile """package P
@cfg(feature = "logging", flag = "extra")
pub func malformed(): Int { 1 }
"""
            let _, diags = applyCfgErasure Set.empty Set.empty sf
            let f0012 = diags |> List.filter (fun d -> d.Code = "F0012")
            Expect.equal (List.length f0012) 1 "F0012 emitted"
            Expect.equal (List.head f0012).Severity DiagError "F0012 is an error"

        testCase "@cfg on package erases entire file" <| fun () ->
            let sf, _ =
                parsedFile """@cfg(feature = "experimental")
package P
pub func f(): Int { 1 }
pub func g(): Int { 2 }
"""
            let result, _ = applyCfgErasure Set.empty Set.empty sf
            Expect.isEmpty result.Items "all items erased"
            Expect.isEmpty result.Imports "imports erased too"

        testCase "@cfg on package keeps when feature active" <| fun () ->
            let sf, _ =
                parsedFile """@cfg(feature = "experimental")
package P
pub func f(): Int { 1 }
"""
            let result, _ =
                applyCfgErasure
                    (Set.singleton "experimental") Set.empty sf
            Expect.equal (List.length result.Items) 1 "items kept"
    ]
