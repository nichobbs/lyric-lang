module Lyric.Emitter.Tests.UnionTests

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

    "nullary_case_match",
    """
package E11
union Maybe { case Yes, case No }
func describe(m: in Maybe): String {
  match m {
    case Yes -> "yes"
    case No  -> "no"
  }
}
func main(): Unit {
  println(describe(Yes))
  println(describe(No))
}
""",
    "yes\nno"

    "case_with_payload",
    """
package E11
union Box { case Wrap(value: Int) }
func main(): Unit {
  match Wrap(value = 42) {
    case Wrap(x) -> println(x)
  }
}
""",
    "42"

    "option_like",
    """
package E11
union OptInt { case Some(value: Int), case None }
func unwrapOr(o: in OptInt, default: in Int): Int {
  match o {
    case Some(v) -> v
    case None    -> default
  }
}
func main(): Unit {
  println(unwrapOr(Some(value = 7), 0))
  println(unwrapOr(None, 99))
}
""",
    "7\n99"

    "result_like",
    """
package E11
union ParseRes { case Ok(value: Int), case Err(reason: String) }
func main(): Unit {
  match Ok(value = 10) {
    case Ok(v)    -> println(v)
    case Err(msg) -> println(msg)
  }
  match Err(reason = "boom") {
    case Ok(v)    -> println(v)
    case Err(msg) -> println(msg)
  }
}
""",
    "10\nboom"

    "two_field_payload",
    """
package E11
union Pair { case Both(a: Int, b: Int) }
func main(): Unit {
  match Both(a = 3, b = 4) {
    case Both(x, y) -> println(x + y)
  }
}
""",
    "7"

    "wildcard_after_constructor",
    """
package E11
union Day { case Workday, case Weekend }
func main(): Unit {
  val d = Weekend
  match d {
    case Workday -> println("hustle")
    case _       -> println("rest")
  }
}
""",
    "rest"
]

let tests =
    testSequenced
    <| testList "variant-bearing unions (E11)"
        (cases |> List.map mk)
