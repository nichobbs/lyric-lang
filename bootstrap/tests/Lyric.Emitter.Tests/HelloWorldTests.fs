module Lyric.Emitter.Tests.HelloWorldTests

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

/// E1 hard requirement: `func main(): Unit { println("hello") }`
/// compiles, runs, and prints `hello\n`. Plus the expression-bodied
/// shape `func main(): Unit = println(...)`.
let tests =
    testSequenced
    <| testList "hello-world (E1)" [

        test "main calling println('hello') runs and prints hello" {
            let r, stdout, stderr, exitCode =
                compileAndRun "Hello"
                    """
package Hello
func main(): Unit { println("hello") }
"""
            Expect.isEmpty
                (r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "E"))
                "no emitter-side diagnostics"
            Expect.isSome r.OutputPath "produced an output path"
            Expect.equal exitCode 0
                (sprintf "exit 0 (stderr was: %s)" stderr)
            Expect.stringContains stdout "hello"
                "stdout contains the printed line"
        }

        test "expression-bodied main with println also runs" {
            let r, stdout, stderr, exitCode =
                compileAndRun "HelloExpr"
                    """
package HelloExpr
func main(): Unit = println("from expr body")
"""
            Expect.isSome r.OutputPath "produced an output path"
            Expect.equal exitCode 0
                (sprintf "exit 0 (stderr was: %s)" stderr)
            Expect.stringContains stdout "from expr body"
                "expr-bodied main runs"
        }
    ]
