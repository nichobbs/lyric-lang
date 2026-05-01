/// End-to-end tests for reified generic records (Tier 2.2 /
/// D-progress-029).
///
/// `record Box[T] { value: T }` lowers to a real generic CLR class
/// with one type parameter.  Construction infers T from arg CLR
/// types via `peekExprType` + TyVar matching.  Field access on a
/// constructed receiver (e.g. `b.value` where `b: Box<int>`)
/// recovers T from the receiver's CLR generic args via
/// `TypeBuilder.GetField`.
module Lyric.Emitter.Tests.GenericRecordTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "generic_record_construct_int",
    """
package GR1
record Box[T] { value: T }

func main(): Unit {
  val b = Box(value = 42)
  println(b.value)
}
""",
    "42"

    "generic_record_construct_string",
    """
package GR2
record Box[T] { value: T }

func main(): Unit {
  val b = Box(value = "hello")
  println(b.value)
}
""",
    "hello"

    "generic_record_two_params",
    """
package GR3
record Pair[A, B] { left: A, right: B }

func main(): Unit {
  val p = Pair(left = 7, right = "world")
  println(p.left)
  println(p.right)
}
""",
    "7\nworld"

    "generic_record_field_access_returns_correct_type",
    """
package GR4
record Box[T] { value: T }

func main(): Unit {
  val b = Box(value = 10)
  // Field access yields Int (the substituted T), so arithmetic works.
  println(b.value + 5)
}
""",
    "15"

    "generic_record_in_record_field",
    """
package GR5
record Box[T] { value: T }
record Pair { a: Box[Int], b: Box[String] }

func main(): Unit {
  val p = Pair(a = Box(value = 10), b = Box(value = "hi"))
  println(p.a.value)
  println(p.b.value)
}
""",
    "10\nhi"
]

let tests =
    testSequenced
    <| testList "reified generic records (Tier 2.2 / D-progress-029)"
                (cases |> List.map mk)
