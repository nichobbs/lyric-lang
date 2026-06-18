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

    "non_generic_record_with_imported_union_field",
    // D-progress-045 codegen fix: non-generic record with a
    // generic-imported-union field correctly closes the union's
    // type parameter to the field's declared type.  Previously,
    // `Tag(label = None)` constructed `None<obj>` because
    // `ctx.ExpectedType` wasn't set during arg emit, and the
    // closed-generic `isinst None<string>` test then failed,
    // dropping match arms into the default fallthrough.
    """
package E5R
import Std.Core
record Wrap { value: Option[Int] }
func main(): Unit {
  val w1 = Wrap(value = Some(value = 7))
  val w2 = Wrap(value = None)
  println(match w1.value { case None -> "none"; case Some(n) -> toString(n) })
  println(match w2.value { case None -> "none"; case Some(n) -> toString(n) })
}
""",
    "7\nnone"
]

let tests =
    testSequenced
    <| testList "records (E5)"
        (cases |> List.map mk)
