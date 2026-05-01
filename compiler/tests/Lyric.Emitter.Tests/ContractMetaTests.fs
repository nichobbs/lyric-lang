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
    ]
