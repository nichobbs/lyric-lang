/// Tests for reified generic unions.  `generic[T] union Box { case
/// Wrapped(value: T) | Empty }` lowers to a real generic CLR class
/// hierarchy.  Construction infers T from arg types; pattern match
/// recovers T from the scrutinee's CLR generic args.
module Lyric.Emitter.Tests.GenericUnionTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "generic_union_construct_int",
    """
package GU1

generic[T] union Box {
  case Wrapped(value: T)
  case Empty
}

func main(): Unit {
  val b = Wrapped(value = 42)
  match b {
    case Wrapped(v) -> println(v)
    case Empty      -> println(0)
  }
}
""",
    "42"

    "generic_union_construct_string",
    """
package GU2

generic[T] union Box {
  case Wrapped(value: T)
  case Empty
}

func main(): Unit {
  val b = Wrapped(value = "hello")
  match b {
    case Wrapped(s) -> println(s)
    case Empty      -> println("none")
  }
}
""",
    "hello"

    "generic_union_match_takes_wrapped",
    """
package GU3

generic[T] union Box {
  case Wrapped(value: T)
  case Empty
}

func main(): Unit {
  val a = Wrapped(value = 7)
  val b = Wrapped(value = 11)
  match a {
    case Wrapped(x) ->
      match b {
        case Wrapped(y) -> println(x + y)
        case Empty      -> println(0)
      }
    case Empty -> println(0)
  }
}
""",
    "18"
]

let tests =
    testSequenced
    <| testList "generic unions (reified)"
        (cases |> List.map mk)
