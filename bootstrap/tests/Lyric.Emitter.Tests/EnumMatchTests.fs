module Lyric.Emitter.Tests.EnumMatchTests

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

    "enum_qualified_case",
    """
package E6
enum Color { case Red, case Green, case Blue }
func main(): Unit {
  match Color.Green {
    case Red   -> println("red")
    case Green -> println("green")
    case Blue  -> println("blue")
  }
}
""",
    "green"

    "enum_through_function",
    """
package E6
enum Color { case Red, case Green, case Blue }
func name(c: in Color): String {
  match c {
    case Red   -> "RED"
    case Green -> "GREEN"
    case Blue  -> "BLUE"
  }
}
func main(): Unit {
  println(name(Color.Blue))
}
""",
    "BLUE"

    "match_with_wildcard",
    """
package E6
enum Day { case Mon, case Tue, case Wed, case Thu, case Fri, case Sat, case Sun }
func main(): Unit {
  val d = Day.Wed
  val label = match d {
    case Sat -> "weekend"
    case Sun -> "weekend"
    case _   -> "weekday"
  }
  println(label)
}
""",
    "weekday"

    "match_on_int_literal",
    """
package E6
func describe(n: in Int): String {
  match n {
    case 0 -> "zero"
    case 1 -> "one"
    case _ -> "many"
  }
}
func main(): Unit {
  println(describe(0))
  println(describe(1))
  println(describe(7))
}
""",
    "zero\none\nmany"

    "match_binding_catchall",
    """
package E6
func describe(n: in Int): Int {
  match n {
    case 0 -> 100
    case x -> x * 2
  }
}
func main(): Unit {
  println(describe(0))
  println(describe(5))
}
""",
    "100\n10"
]

let tests =
    testSequenced
    <| testList "enums + match (E6)"
        (cases |> List.map mk)
