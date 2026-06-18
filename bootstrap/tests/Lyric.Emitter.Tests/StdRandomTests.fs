/// End-to-end tests for `Std.Random` (D-progress-055).
///
/// Wraps `System.Random` for pseudorandom number generation.
/// Tests use seeded RNGs so output is deterministic.
module Lyric.Emitter.Tests.StdRandomTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "random_seeded_int_range",
    """
package SR1
import Std.Random
func main(): Unit {
  val r = makeRandom(42)
  println(toString(nextIntRange(r, 0, 10)))
  println(toString(nextIntRange(r, 0, 10)))
  println(toString(nextIntRange(r, 0, 10)))
}
""",
    // System.Random with seed 42 produces deterministic output;
    // these specific values come from the .NET runtime's
    // implementation.  If the runtime changes its algorithm the
    // expected values would shift — this is a guard test.
    "6\n1\n1"

    "random_seeded_double_in_range",
    """
package SR2
import Std.Random
func main(): Unit {
  val r = makeRandom(123)
  val d = nextDouble(r)
  println(toString(d >= 0.0))
  println(toString(d < 1.0))
}
""",
    "True\nTrue"

    "random_next_bool",
    """
package SR3
import Std.Random
func main(): Unit {
  val r = makeRandom(42)
  // Just verify the call resolves and returns a Bool.
  val b: Bool = nextBool(r)
  if b or not b {
    println("ok")
  } else {
    println("?")
  }
}
""",
    "ok"
]

let tests =
    testSequenced
    <| testList "Std.Random (D-progress-055)"
        (cases |> List.map mk)
