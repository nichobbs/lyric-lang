/// End-to-end tests for the embedded `Lyric.Contract` resource
/// (Tier 3 part 1 / D-progress-031).
///
/// Every emitted Lyric assembly carries a managed resource named
/// `Lyric.Contract` describing its `pub` surface; downstream tooling
/// (`lyric public-api-diff`, future package-manager wiring) reads it
/// via `ContractMeta.readFromAssembly`.
module Lyric.Emitter.Tests.ContractMetaTests

open Expecto
open Lyric.Emitter
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testSequenced
    <| testList "Lyric.Contract embedded resource (D-progress-031)" [

        testCase "[contract resource is embedded in every emitted DLL]" <| fun () ->
            let r, _, _, exitCode =
                compileAndRun "ContractA" """
package MyApp

@derive(Json)
pub record User { name: String, age: Int }

pub func greet(u: in User): String {
  "hello, " + u.name
}

func main(): Unit {
  println(greet(User(name = "Alice", age = 30)))
}
"""
            Expect.equal exitCode 0 "build + run"
            match r.OutputPath with
            | None -> failtest "no output path"
            | Some p ->
                match ContractMeta.readFromAssembly p with
                | None -> failtest "Lyric.Contract resource not embedded"
                | Some json ->
                    Expect.stringContains json "\"packageName\": \"MyApp\""
                        "package name in contract"
                    Expect.stringContains json "\"name\":\"User\""
                        "User record in contract"
                    Expect.stringContains json "\"name\":\"greet\""
                        "greet function in contract"
                    Expect.stringContains json "\"name\":\"User.toJson\""
                        "synthesised toJson appears as a pub func"

        testCase "[non-pub items are excluded]" <| fun () ->
            let r, _, _, _ =
                compileAndRun "ContractB" """
package Hidden

pub record Visible { x: Int }
record Internal { y: Int }

pub func shown(v: in Visible): Int { v.x }
func helper(i: in Internal): Int { i.y }

func main(): Unit { println(shown(Visible(x = 1))) }
"""
            match r.OutputPath with
            | None -> failtest "no output path"
            | Some p ->
                match ContractMeta.readFromAssembly p with
                | None -> failtest "Lyric.Contract resource not embedded"
                | Some json ->
                    Expect.stringContains json "Visible"
                        "pub record in contract"
                    Expect.stringContains json "shown"
                        "pub func in contract"
                    Expect.isFalse (json.Contains "Internal")
                        "package-private record absent"
                    Expect.isFalse (json.Contains "helper")
                        "package-private func absent"

        testCase "[parseFromJson round-trips toJson]" <| fun () ->
            let original =
                ContractMeta.Contract.legacy "Demo" "1.2.3"
                    [ ContractMeta.ContractDecl.basic "func"   "f" "(x: in Int): Int"
                      ContractMeta.ContractDecl.basic "record" "R" "{ a: Int, b: String }" ]
            let json = ContractMeta.toJson original
            match ContractMeta.parseFromJson json with
            | None -> failtest "parseFromJson should round-trip"
            | Some parsed ->
                Expect.equal parsed.PackageName "Demo" "packageName"
                Expect.equal parsed.Version "1.2.3" "version"
                Expect.equal parsed.Decls.Length 2 "decl count"
                Expect.equal parsed.Decls.[0].Name "f" "first decl name"
                Expect.equal parsed.Decls.[1].Kind "record" "second decl kind"

        testCase "[diffContracts detects added/removed/changed]" <| fun () ->
            let oldC =
                ContractMeta.Contract.legacy "Demo" "1.0.0"
                    [ ContractMeta.ContractDecl.basic "func" "keep"   "(x: in Int): Int"
                      ContractMeta.ContractDecl.basic "func" "modify" "(x: in Int): Int"
                      ContractMeta.ContractDecl.basic "func" "drop"   "(): Unit" ]
            let newC =
                ContractMeta.Contract.legacy "Demo" "1.1.0"
                    [ ContractMeta.ContractDecl.basic "func" "keep"   "(x: in Int): Int"
                      ContractMeta.ContractDecl.basic "func" "modify" "(x: in Long): Int"
                      ContractMeta.ContractDecl.basic "func" "added"  "(): Unit" ]
            let entries = ContractMeta.diffContracts oldC newC
            let kinds =
                entries
                |> List.map (function
                    | ContractMeta.DiffAdded d   -> "+ " + d.Name
                    | ContractMeta.DiffRemoved d -> "- " + d.Name
                    | ContractMeta.DiffChanged (o, _) -> "~ " + o.Name)
            Expect.equal kinds.Length 3 "added + removed + changed"
            Expect.contains kinds "+ added" "new func added"
            Expect.contains kinds "- drop" "old func removed"
            Expect.contains kinds "~ modify" "func signature changed"
            Expect.isTrue (ContractMeta.hasBreakingChanges entries)
                "removed/changed entries are breaking"

        testCase "[diffContracts identifies additive-only as non-breaking]" <| fun () ->
            let oldC =
                ContractMeta.Contract.legacy "Demo" "1.0.0"
                    [ ContractMeta.ContractDecl.basic "func" "f" "()" ]
            let newC =
                ContractMeta.Contract.legacy "Demo" "1.1.0"
                    [ ContractMeta.ContractDecl.basic "func" "f" "()"
                      ContractMeta.ContractDecl.basic "func" "g" "()" ]
            let entries = ContractMeta.diffContracts oldC newC
            Expect.equal entries.Length 1 "one added"
            Expect.isFalse (ContractMeta.hasBreakingChanges entries)
                "added-only is non-breaking"
    ]
