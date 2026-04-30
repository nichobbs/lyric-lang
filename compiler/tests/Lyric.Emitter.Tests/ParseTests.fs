/// Tests for the host-routed numeric parsing builtins
/// (`hostParseIntIsValid`, `hostParseIntValue`, …) that
/// `compiler/lyric/std/parse.l` calls into.
///
/// These exercise the codegen wiring directly with minimal Lyric
/// source.  An `import Std.Parse` end-to-end test will land once the
/// stdlib import resolver is extended past `Std.Core` (currently only
/// `Std.Core` is wired through `resolveStdlibImports`).
module Lyric.Emitter.Tests.ParseTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

// ---- host-builtin smoke tests --------------------------------------------

let private hostBuiltinCases : (string * string * string) list = [

    "hostParseInt_valid_and_value",
    """
package PB1
func main(): Unit {
  println(hostParseIntIsValid("42"))
  println(hostParseIntValue("42"))
  println(hostParseIntIsValid("-7"))
  println(hostParseIntValue("-7"))
}
""",
    "True\n42\nTrue\n-7"

    "hostParseInt_invalid",
    """
package PB2
func main(): Unit {
  println(hostParseIntIsValid("nope"))
  println(hostParseIntValue("nope"))
  println(hostParseIntIsValid(""))
}
""",
    "False\n0\nFalse"

    "hostParseLong_roundtrip",
    """
package PB3
func main(): Unit {
  println(hostParseLongIsValid("9000000000"))
  println(hostParseLongValue("9000000000"))
  println(hostParseLongIsValid("not-a-long"))
}
""",
    "True\n9000000000\nFalse"

    "hostParseDouble_roundtrip",
    """
package PB4
func main(): Unit {
  println(hostParseDoubleIsValid("3.14"))
  println(hostParseDoubleValue("3.14"))
  println(hostParseDoubleIsValid("nope"))
}
""",
    "True\n3.14\nFalse"
]

let tests =
    testSequenced
    <| testList "Std.Parse host wiring" (hostBuiltinCases |> List.map mk)
