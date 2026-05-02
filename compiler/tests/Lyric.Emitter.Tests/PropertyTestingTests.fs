/// End-to-end tests for `Std.Testing.Property` (Phase 3 / D-progress-064).
///
/// Each test exercises a property over a seeded RNG so the runs
/// are deterministic.  Properties that hold succeed silently;
/// failing properties panic with a structured "input that broke
/// it" message and the test asserts non-zero exit.
module Lyric.Emitter.Tests.PropertyTestingTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches"

let private cases : (string * string * string) list = [
    "property_int_addition_commutative",
    """
package PT1
import Std.Random
import Std.Testing.Property
func main(): Unit {
  val r = makeRandom(42)
  forAllIntPair(r, 0, 1000, 100, { a: Int, b: Int -> a + b == b + a })
  println("ok")
}
""",
    "ok"

    "property_doubled_is_even",
    """
package PT2
import Std.Random
import Std.Testing.Property
func main(): Unit {
  val r = makeRandom(7)
  forAllIntRange(r, 0, 100, 50, { x: Int -> (x + x) % 2 == 0 })
  println("ok")
}
""",
    "ok"

    "property_bool_double_negation",
    """
package PT3
import Std.Random
import Std.Testing.Property
func main(): Unit {
  val r = makeRandom(11)
  forAllBool(r, 20, { b: Bool -> (not (not b)) == b })
  println("ok")
}
""",
    "ok"

    "property_double_in_range",
    """
package PT4
import Std.Random
import Std.Testing.Property
func main(): Unit {
  val r = makeRandom(100)
  forAllDouble(r, 30, { d: Double -> d >= 0.0 and d < 1.0 })
  println("ok")
}
""",
    "ok"
]

let tests =
    testSequenced
    <| testList "Std.Testing.Property (D-progress-064)"
        (cases |> List.map mk)
