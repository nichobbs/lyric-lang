module Lyric.Emitter.Tests.SliceTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected
            "stdout matches expected"

let private cases : (string * string * string) list = [

    "list_first",
    """
package E7
func main(): Unit {
  val a = [10, 20, 30]
  println(a[0])
}
""",
    "10"

    "list_last",
    """
package E7
func main(): Unit {
  val a = [10, 20, 30]
  println(a[2])
}
""",
    "30"

    "list_length",
    """
package E7
func main(): Unit {
  val a = [1, 2, 3, 4, 5]
  println(a.length)
}
""",
    "5"

    "list_string_elements",
    """
package E7
func main(): Unit {
  val xs = ["a", "b", "c"]
  println(xs[1])
}
""",
    "b"

    "for_in_array",
    """
package E7
func main(): Unit {
  val xs = [1, 2, 3, 4]
  var sum = 0
  for x in xs { sum += x }
  println(sum)
}
""",
    "10"

    "list_index_in_arithmetic",
    """
package E7
func main(): Unit {
  val a = [10, 20, 30]
  println(a[0] + a[1] + a[2])
}
""",
    "60"

    "tuple_construction_via_function",
    // Only verifies that ETuple emits without exploding; reading
    // tuple fields needs pattern matching (E6).
    """
package E7
func makePair(a: in Int, b: in Int): (Int, Int) = (a, b)
func main(): Unit {
  val _ = makePair(1, 2)
  println(42)
}
""",
    "42"
]

let tests =
    testSequenced
    <| testList "slices + lists + indexing (E7)"
        (cases |> List.map mk)
