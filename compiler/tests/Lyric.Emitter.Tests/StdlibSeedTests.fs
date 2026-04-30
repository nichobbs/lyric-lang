/// Tests for the Lyric-side standard library at
/// `compiler/lyric/std/core.l`, exercised via `import Std.Core`.
///
/// Each test program uses `import Std.Core` and the emitter resolves
/// that import by locating `core.l`, parsing it, and merging its items
/// into the user package before type-checking.  This validates both the
/// stdlib functions themselves and the multi-package import machinery.
module Lyric.Emitter.Tests.StdlibSeedTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, driver: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode =
            compileAndRun label driver
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected
            "stdout matches expected"

let private cases : (string * string * string) list = [

    "option_unwrap_or",
    """
package StdTest_OptionUnwrapOr
import Std.Core
func main(): Unit {
  println(unwrapOr(Some(value = 42), 0))
  println(unwrapOr(None, 99))
}
""",
    "42\n99"

    "option_predicates",
    """
package StdTest_OptionPredicates
import Std.Core
func main(): Unit {
  println(isSome(Some(value = 1)))
  println(isSome(None))
  println(isNone(None))
}
""",
    "True\nFalse\nTrue"

    "result_basics",
    """
package StdTest_ResultBasics
import Std.Core
func main(): Unit {
  println(isOk(Ok(value = 7)))
  println(isOk(Err(code = 1)))
  println(unwrapResultOr(Ok(value = 7), 0))
  println(unwrapResultOr(Err(code = 1), 99))
  println(errCode(Err(code = 42)))
}
""",
    "True\nFalse\n7\n99\n42"

    "slice_helpers",
    """
package StdTest_SliceHelpers
import Std.Core
func main(): Unit {
  val xs = [3, 1, 4, 1, 5, 9, 2, 6]
  println(sumInts(xs))
  println(maxInt(xs))
  println(countEq(xs, 1))
}
""",
    "31\n9\n2"

    "mapOption",
    """
package StdTest_MapOption
import Std.Core
func main(): Unit {
  println(isSome(mapOption(Some(value = 3), { x: Int -> x * 2 })))
  println(unwrapOr(mapOption(Some(value = 3), { x: Int -> x * 2 }), 0))
  println(isSome(mapOption(None, { x: Int -> x * 2 })))
}
""",
    "True\n6\nFalse"

    "mapResult",
    """
package StdTest_MapResult
import Std.Core
func main(): Unit {
  println(isOk(mapResult(Ok(value = 5), { x: Int -> x + 1 })))
  println(unwrapResultOr(mapResult(Ok(value = 5), { x: Int -> x + 1 }), 0))
  println(isOk(mapResult(Err(code = 42), { x: Int -> x + 1 })))
}
""",
    "True\n6\nFalse"

    "filterOption",
    """
package StdTest_FilterOption
import Std.Core
func main(): Unit {
  println(isSome(filterOption(Some(value = 10), { x: Int -> x > 5 })))
  println(isSome(filterOption(Some(value = 3), { x: Int -> x > 5 })))
  println(isSome(filterOption(None, { x: Int -> x > 5 })))
}
""",
    "True\nFalse\nFalse"

    "countWhere",
    """
package StdTest_CountWhere
import Std.Core
func main(): Unit {
  val xs = [1, 2, 3, 4, 5, 6]
  println(countWhere(xs, { x: Int -> x > 3 }))
  println(countWhere(xs, { x: Int -> x == 2 }))
}
""",
    "3\n1"
]

/// Smoke test for string concatenation.
let private concatTests : Test list = [
    testCase "[string + string]" <| fun () ->
        let _, stdout, stderr, exitCode =
            compileAndRun "ConcatA" """
package ConcatA
func main(): Unit {
  println("hello, " + "world")
}
"""
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) "hello, world" "concat works"

    testCase "[string + int auto-boxes]" <| fun () ->
        let _, stdout, stderr, exitCode =
            compileAndRun "ConcatB" """
package ConcatB
func main(): Unit {
  println("count=" + 42)
}
"""
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) "count=42" "string + int"

    testCase "[int + string auto-boxes]" <| fun () ->
        let _, stdout, stderr, exitCode =
            compileAndRun "ConcatC" """
package ConcatC
func main(): Unit {
  println(42 + " is the answer")
}
"""
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) "42 is the answer" "int + string"
]

let tests =
    testSequenced
    <| testList "stdlib seed (S1 + S2)"
        (List.append
            (cases |> List.map mk)
            concatTests)
