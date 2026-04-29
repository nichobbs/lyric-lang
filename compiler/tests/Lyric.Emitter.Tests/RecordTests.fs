module Lyric.Emitter.Tests.RecordTests

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

    "ctor_and_field_read",
    """
package E5
record Point { x: Int, y: Int }
func main(): Unit {
  val p = Point(x = 3, y = 4)
  println(p.x + p.y)
}
""",
    "7"

    "positional_args",
    """
package E5
record Point { x: Int, y: Int }
func main(): Unit {
  val p = Point(10, 20)
  println(p.x)
  println(p.y)
}
""",
    "10\n20"

    "string_field",
    """
package E5
record Greeting { name: String, count: Int }
func main(): Unit {
  val g = Greeting(name = "world", count = 3)
  println(g.name)
  println(g.count)
}
""",
    "world\n3"

    "record_through_function",
    """
package E5
record Point { x: Int, y: Int }
func sum(p: in Point): Int { return p.x + p.y }
func main(): Unit {
  println(sum(Point(x = 100, y = 50)))
}
""",
    "150"

    "two_records",
    """
package E5
record A { v: Int }
record B { w: Int }
func main(): Unit {
  val a = A(v = 5)
  val b = B(w = 7)
  println(a.v * b.w)
}
""",
    "35"

    "field_assignment_through_var",
    """
package E5
record Point { x: Int, y: Int }
func main(): Unit {
  var p = Point(x = 1, y = 2)
  p = Point(x = 11, y = 22)
  println(p.x)
}
""",
    "11"
]

let tests =
    testSequenced
    <| testList "records (E5)"
        (cases |> List.map mk)
