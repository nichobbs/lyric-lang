module Lyric.Cli.Tests.LintTests

open Expecto
open Lyric.Parser.Parser
open Lyric.Cli.Lint

let private lintSource (source: string) : LintDiagnostic list =
    let r = parse source
    (lint r.File).Diagnostics

let private codes (diags: LintDiagnostic list) : string list =
    diags |> List.map (fun d -> d.Code)

let tests =
    testList "Lyric.Cli.Lint" [

        testCase "no diagnostics for clean file" <| fun () ->
            let diags =
                lintSource """
package Clean

/// A well-documented function.
pub func computeSum(a: in Int, b: in Int): Int
  requires: a > 0
  ensures: result > a
{
  return a + b
}
"""
            Expect.isEmpty diags "clean file has no lint hits"

        testCase "L001 fires for lowercase type name" <| fun () ->
            let diags = lintSource "package P\npub record myRecord {\n  x: Int\n}"
            Expect.contains (codes diags) "L001" "L001 for lowercase record"

        testCase "L001 fires for lowercase union" <| fun () ->
            let diags = lintSource "package P\npub union myUnion {\n  case A\n  case B\n}"
            Expect.contains (codes diags) "L001" "L001 for lowercase union"

        testCase "L001 fires for lowercase enum" <| fun () ->
            let diags = lintSource "package P\npub enum myEnum {\n  case A\n}"
            Expect.contains (codes diags) "L001" "L001 for lowercase enum"

        testCase "L001 fires for lowercase distinct type" <| fun () ->
            let diags = lintSource "package P\npub distinct type myAge = Int"
            Expect.contains (codes diags) "L001" "L001 for lowercase distinct type"

        testCase "L001 does NOT fire for PascalCase type" <| fun () ->
            let diags = lintSource "package P\n/// Doc.\npub record MyRecord {\n  x: Int\n}"
            Expect.isEmpty (codes diags |> List.filter ((=) "L001")) "PascalCase record is clean"

        testCase "L002 fires for uppercase function name" <| fun () ->
            let diags = lintSource "package P\npub func MyFunc(): Unit {\n}"
            Expect.contains (codes diags) "L002" "L002 for uppercase func"

        testCase "L002 does NOT fire for camelCase func" <| fun () ->
            let diags = lintSource "package P\n/// Doc.\npub func myFunc(): Unit {\n  return ()\n}"
            Expect.isEmpty (codes diags |> List.filter ((=) "L002")) "camelCase func is clean"

        testCase "L003 fires for pub item without doc comment" <| fun () ->
            let diags = lintSource "package P\npub func noDoc(): Unit {\n}"
            Expect.contains (codes diags) "L003" "L003 for missing doc"

        testCase "L003 does NOT fire for package-private item" <| fun () ->
            let diags = lintSource "package P\nfunc noDoc(): Unit {\n}"
            Expect.isEmpty (codes diags |> List.filter ((=) "L003")) "private item no doc required"

        testCase "L003 does NOT fire when doc comment present" <| fun () ->
            let diags = lintSource "package P\n/// Has doc.\npub func withDoc(): Unit {\n}"
            Expect.isEmpty (codes diags |> List.filter ((=) "L003")) "doc present clears L003"

        testCase "L004 fires for TODO in doc comment" <| fun () ->
            let diags =
                lintSource "package P\n/// TODO: fix this later.\npub func pending(): Unit {\n}"
            Expect.contains (codes diags) "L004" "L004 for TODO in doc"

        testCase "L004 fires for FIXME in doc comment" <| fun () ->
            let diags =
                lintSource "package P\n/// FIXME: broken path.\npub func broken(): Unit {\n}"
            Expect.contains (codes diags) "L004" "L004 for FIXME in doc"

        testCase "L004 does NOT fire when no TODO/FIXME" <| fun () ->
            let diags = lintSource "package P\n/// Clean comment.\npub func ok(): Unit {\n}"
            Expect.isEmpty (codes diags |> List.filter ((=) "L004")) "no TODO = no L004"

        testCase "L005 fires for pub func with block body and no contracts" <| fun () ->
            let diags = lintSource "package P\n/// Doc.\npub func risky(x: in Int): Int {\n  return x\n}"
            Expect.contains (codes diags) "L005" "L005 for pub func without contracts"

        testCase "L005 does NOT fire for expression-body func" <| fun () ->
            let diags = lintSource "package P\n/// Doc.\npub func double(x: in Int): Int = x * 2"
            Expect.isEmpty (codes diags |> List.filter ((=) "L005")) "expr-body exempt from L005"

        testCase "L005 does NOT fire when requires present" <| fun () ->
            let diags =
                lintSource
                    "package P\n/// Doc.\npub func safe(x: in Int): Int\n  requires: x > 0\n{\n  return x\n}"
            Expect.isEmpty (codes diags |> List.filter ((=) "L005")) "has requires, no L005"

        testCase "L005 does NOT fire for package-private func" <| fun () ->
            let diags = lintSource "package P\nfunc internal(x: in Int): Int {\n  return x\n}"
            Expect.isEmpty (codes diags |> List.filter ((=) "L005")) "private func exempt from L005"

        testCase "multiple rules can fire on same item" <| fun () ->
            // uppercase name (L002) + no doc (L003) + no contracts (L005)
            let diags = lintSource "package P\npub func BadName(x: in Int): Int {\n  return x\n}"
            let cs = codes diags
            Expect.contains cs "L002" "L002"
            Expect.contains cs "L003" "L003"
            Expect.contains cs "L005" "L005"

        testCase "renderDiagnostic formats correctly" <| fun () ->
            let diags = lintSource "package P\npub func MyFunc(): Unit {\n}"
            let d = diags |> List.find (fun d -> d.Code = "L002")
            let rendered = renderDiagnostic d
            Expect.isTrue (rendered.StartsWith "L002") "starts with code"
            Expect.isTrue (rendered.Contains "error") "contains severity"
            Expect.isTrue (rendered.Contains "MyFunc") "contains the function name"

        testCase "L001 fires for lowercase type alias" <| fun () ->
            let diags = lintSource "package P\n/// Doc.\npub type myAlias = Int"
            Expect.contains (codes diags) "L001" "L001 for lowercase type alias"

        testCase "interface method name checked for L002" <| fun () ->
            let diags =
                lintSource
                    "package P\n/// An interface.\npub interface Foo {\n  func BadMethod(self: in Self): Unit\n}"
            Expect.contains (codes diags) "L002" "L002 for PascalCase interface method"
    ]
