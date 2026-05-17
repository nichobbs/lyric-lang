/// Unit tests for the self-hosted `lyric doc` bridge (F6 follow-up).
/// Exercises `SelfHostedDoc.generate` against known fixture inputs and
/// asserts expected Markdown fragments in the output.
module Lyric.Cli.Tests.DocTests

open Expecto
open Lyric.Cli.SelfHostedDoc

let tests =
    testList "Lyric.Cli.Doc (self-hosted bridge)" [

        testCase "doc: pub func appears in markdown output" <| fun () ->
            let src = """
package DocFixture

/// Returns the sum of two integers.
pub func add(a: in Int, b: in Int): Int { a + b }

func main(): Unit { () }
"""
            let md = generate src
            Expect.stringContains md "add"
                "pub func name appears in doc output"
            Expect.stringContains md "Int"
                "param types appear in doc output"

        testCase "doc: pub record appears in markdown output" <| fun () ->
            let src = """
package DocFixture2

/// A named point in 2D space.
pub record Point { x: Int, y: Int }

func main(): Unit { () }
"""
            let md = generate src
            Expect.stringContains md "Point"
                "pub record name in doc output"
            Expect.stringContains md "x"
                "record field x in doc output"
            Expect.stringContains md "y"
                "record field y in doc output"

        testCase "doc: non-pub items are excluded" <| fun () ->
            let src = """
package DocFixture3

pub func shown(x: in Int): Int { x }
func hidden(x: in Int): Int { x }

func main(): Unit { () }
"""
            let md = generate src
            Expect.stringContains md "shown"
                "pub func is present"
            Expect.isFalse (md.Contains "hidden")
                "package-private func is absent from doc output"
    ]
