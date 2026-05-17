/// Smoke tests for the relaxed-syntax improvements:
///   1. `Name[T]` after a declaration name introduces generic
///      parameters — the legacy `generic[T]` prefix still works.
///   2. Parameter mode keywords (`in`, `out`, `inout`) are optional;
///      omitting one defaults to `in`.
module Lyric.Emitter.Tests.SyntaxSimplificationTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    // Bare-bracket generic-parameter syntax on a function declaration.
    "func_brackets_generic_int",
    """
package SS1
func id[T](x: T): T = x
func main(): Unit { println(id(42)) }
""",
    "42"

    // Parameter mode `in` is optional and the default.
    "func_default_in_mode",
    """
package SS2
func add(a: Int, b: Int): Int = a + b
func main(): Unit { println(add(2, 3)) }
""",
    "5"

    // Both improvements together.
    "func_brackets_and_default_mode",
    """
package SS3
func first[A, B](a: A, b: B): A = a
func main(): Unit {
  println(first(7, "ignored"))
  println(first("kept", 99))
}
""",
    "7\nkept"

    // Legacy `generic[T]` form keeps working.
    "func_legacy_generic_keyword",
    """
package SS4
generic[T] func id(x: in T): T = x
func main(): Unit { println(id(11)) }
""",
    "11"

    // Mixing default + explicit modes within one parameter list.
    "func_mixed_mode_explicit_in",
    """
package SS5
func combine(a: Int, b: in Int): Int = a + b
func main(): Unit { println(combine(40, 2)) }
""",
    "42"

    // `result` is a contextual keyword — reserved in `ensures:` clauses
    // but usable as an ordinary local-variable name everywhere else.
    "result_as_local_variable",
    """
package SS6
func join(a: in String, b: in String): String {
  var result = a + "-" + b
  return result
}
func main(): Unit {
  println(join("foo", "bar"))
}
""",
    "foo-bar"

    // `result` is a valid function-parameter name.
    "result_as_param_name",
    """
package SS7
func echo(result: in String): String = result
func main(): Unit { println(echo("ok")) }
""",
    "ok"
]

let tests =
    testSequenced
    <| testList "syntax simplification"
        (cases |> List.map mk)
