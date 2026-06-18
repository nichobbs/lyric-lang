module Lyric.Emitter.Tests.FunctionCallTests

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

    "call_simple",
    """
package E4
func add(x: in Int, y: in Int): Int { return x + y }
func main(): Unit { println(add(3, 4)) }
""",
    "7"

    "call_two_funcs",
    """
package E4
func square(n: in Int): Int { return n * n }
func cube(n: in Int): Int { return square(n) * n }
func main(): Unit { println(cube(3)) }
""",
    "27"

    "implicit_return",
    """
package E4
func double(n: in Int): Int { n * 2 }
func main(): Unit { println(double(21)) }
""",
    "42"

    "expr_body",
    """
package E4
func triple(n: in Int): Int = n * 3
func main(): Unit { println(triple(7)) }
""",
    "21"

    "recursion_factorial",
    """
package E4
func factorial(n: in Int): Int {
  if n <= 1 then 1 else n * factorial(n - 1)
}
func main(): Unit { println(factorial(6)) }
""",
    "720"

    "mutual_recursion_even_odd",
    """
package E4
func isEven(n: in Int): Bool {
  if n == 0 then true else isOdd(n - 1)
}
func isOdd(n: in Int): Bool {
  if n == 0 then false else isEven(n - 1)
}
func main(): Unit { println(isEven(10)) }
""",
    "True"

    "no_arg_func",
    """
package E4
func answer(): Int = 42
func main(): Unit { println(answer()) }
""",
    "42"

    "param_shadowed_by_local",
    """
package E4
func f(x: in Int): Int {
  val y = x + 100
  return y
}
func main(): Unit { println(f(5)) }
""",
    "105"

    "string_param",
    """
package E4
func greet(name: in String): Unit { println(name) }
func main(): Unit { greet("hello world") }
""",
    "hello world"

    "many_params",
    """
package E4
func sum4(a: in Int, b: in Int, c: in Int, d: in Int): Int { return a + b + c + d }
func main(): Unit { println(sum4(1, 2, 3, 4)) }
""",
    "10"

    // Overloading by arity — two functions with the same name but
    // different parameter counts must each emit a body and be callable.
    "arity_overload_two_and_three_params",
    """
package E4_OL
func add(x: in Int, y: in Int): Int = x + y
func add(x: in Int, y: in Int, z: in Int): Int = x + y + z
func main(): Unit {
  println(add(1, 2))
  println(add(1, 2, 3))
}
""",
    "3\n6"

    // One-arg overload alongside two-arg.
    "arity_overload_one_and_two_params",
    """
package E4_OL2
func negate(x: in Int): Int = 0 - x
func negate(x: in Int, scale: in Int): Int = 0 - (x * scale)
func main(): Unit {
  println(negate(5))
  println(negate(5, 3))
}
""",
    "-5\n-15"
]

let tests =
    testSequenced
    <| testList "functions + calls (E4)"
        (cases |> List.map mk)
