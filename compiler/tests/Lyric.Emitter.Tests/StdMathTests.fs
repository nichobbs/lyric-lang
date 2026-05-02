/// End-to-end tests for `Std.Math` (D-progress-054).
///
/// Routes Lyric calls through `@externTarget` to `System.Math` /
/// `System.Double` BCL statics.  Each helper has the same shape:
/// thin Lyric wrapper, BCL semantics.  Round() uses banker's
/// (default) rounding so the test below picks values that aren't
/// at the .5 boundary.
module Lyric.Emitter.Tests.StdMathTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "math_abs_int",
    """
package SM1
import Std.Math
func main(): Unit {
  println(toString(absInt(-7)))
  println(toString(absInt(7)))
}
""",
    "7\n7"

    "math_pair_min_max",
    """
package SM2
import Std.Math
func main(): Unit {
  println(toString(minPairInt(3, 9)))
  println(toString(maxPairInt(3, 9)))
}
""",
    "3\n9"

    "math_floor_ceil",
    """
package SM3
import Std.Math
func main(): Unit {
  println(toString(floor(2.7)))
  println(toString(ceiling(2.3)))
}
""",
    "2\n3"

    "math_sqrt",
    """
package SM4
import Std.Math
func main(): Unit {
  println(toString(sqrt(16.0)))
}
""",
    "4"

    "math_sign",
    """
package SM5
import Std.Math
func main(): Unit {
  println(toString(signInt(-3)))
  println(toString(signInt(0)))
  println(toString(signInt(5)))
}
""",
    "-1\n0\n1"

    "math_isNaN_isFinite",
    """
package SM6
import Std.Math
func main(): Unit {
  println(toString(isNaN(0.0)))
  println(toString(isFinite(1.0)))
}
""",
    "False\nTrue"
]

let tests =
    testSequenced
    <| testList "Std.Math (D-progress-054)"
        (cases |> List.map mk)
