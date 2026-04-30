/// Tests for reified generic records.  `record Box[T] { value: T }`
/// lowers to a real generic CLR class.  Construction infers T from
/// arg CLR types; field access recovers T from the receiver's CLR
/// generic args via `TypeBuilder.GetField`.
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

record Box[T] {
  value: T
}

func main(): Unit {
  val b = Box(value = 42)
  println(b.value)
}
""",
    "42"

    "generic_record_construct_string",
    """
package GR2

record Box[T] {
  value: T
}

func main(): Unit {
  val b = Box(value = "hello")
  println(b.value)
}
""",
    "hello"

    "generic_record_two_params",
    """
package GR3

record Pair[A, B] {
  first: A
  second: B
}

func main(): Unit {
  val p = Pair(first = 7, second = "ok")
  println(p.first)
  println(p.second)
}
""",
    "7\nok"

    "generic_record_passed_to_function",
    """
package GR4

record Box[T] {
  value: T
}

func unwrap[T](b: Box[T]): T = b.value

func main(): Unit {
  val b = Box(value = 99)
  println(unwrap(b))
}
""",
    "99"

    "generic_record_arithmetic_via_field",
    """
package GR5

record Box[T] {
  value: T
}

func main(): Unit {
  val a = Box(value = 10)
  val b = Box(value = 20)
  println(a.value + b.value)
}
""",
    "30"
]

let tests =
    testSequenced
    <| testList "generic records (reified)"
        (cases |> List.map mk)
