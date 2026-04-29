module Lyric.Emitter.Tests.ContractTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mkOk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s ok]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected
            "stdout matches expected"

let private mkThrows (label: string, source: string, msgFragment: string) : Test =
    testCase (sprintf "[%s throws]" label) <| fun () ->
        let _, _, stderr, exitCode = compileAndRun label source
        Expect.notEqual exitCode 0
            "non-zero exit on contract violation"
        Expect.stringContains stderr msgFragment
            "stderr names the failing contract"

let private okCases : (string * string * string) list = [

    "requires_holds",
    """
package E15
func half(n: in Int): Int
  requires: n >= 0
{
  return n / 2
}
func main(): Unit { println(half(10)) }
""",
    "5"

    "ensures_holds",
    """
package E15
func double(n: in Int): Int
  ensures: result >= n
{
  return n + n
}
func main(): Unit { println(double(7)) }
""",
    "14"

    "both_holds",
    """
package E15
func add1(n: in Int): Int
  requires: n >= 0
  ensures:  result == n + 1
{
  return n + 1
}
func main(): Unit { println(add1(41)) }
""",
    "42"
]

let private failCases : (string * string * string) list = [

    "requires_fails",
    """
package E15
func half(n: in Int): Int
  requires: n >= 0
{
  return n / 2
}
func main(): Unit { println(half(-1)) }
""",
    "requires failed"

    "ensures_fails",
    """
package E15
func bogus(n: in Int): Int
  ensures: result > 0
{
  return -n
}
func main(): Unit { println(bogus(5)) }
""",
    "ensures failed"
]

let tests =
    testSequenced
    <| testList "@runtime_checked contracts (E15)"
        (List.append
            (okCases   |> List.map mkOk)
            (failCases |> List.map mkThrows))
