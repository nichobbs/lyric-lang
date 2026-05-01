/// Tests for codegen-only builtins exposed via `codegenBuiltinType`:
/// `toString` (and a regression for `println` polymorphism).
///
/// `toString(x)` is polymorphic in its argument and returns String.
/// Codegen routes through `Lyric.Stdlib.Console::ToStr(obj)` with
/// auto-boxing for value types.
module Lyric.Emitter.Tests.BuiltinTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "toString_int",
    """
package TS1
func main(): Unit {
  println(toString(42))
}
""",
    "42"

    "toString_long",
    """
package TS2
import Std.Core
import Std.Parse
func main(): Unit {
  match tryParseLong("9000000000") {
    case Ok(v)  -> println(toString(v))
    case Err(_) -> println("err")
  }
}
""",
    "9000000000"

    "toString_bool",
    """
package TS3
func main(): Unit {
  println(toString(true))
  println(toString(false))
}
""",
    "True\nFalse"

    "toString_char",
    """
package TS4
func main(): Unit {
  println(toString('A'))
}
""",
    "A"

    "toString_string_passthrough",
    """
package TS5
func main(): Unit {
  println(toString("already a string"))
}
""",
    "already a string"

    "toString_concat",
    """
package TS6
func main(): Unit {
  val n = 7
  println("count: " + toString(n))
}
""",
    "count: 7"

    "toString_in_expression",
    """
package TS7
func describe(n: in Int): String {
  return "n=" + toString(n)
}
func main(): Unit {
  println(describe(3))
  println(describe(-1))
}
""",
    "n=3\nn=-1"

    "format1_int",
    """
package F1
func main(): Unit {
  println(format1("count: {0}", 42))
}
""",
    "count: 42"

    "format2_mixed_types",
    """
package F2
func main(): Unit {
  println(format2("{0} = {1}", "answer", 42))
}
""",
    "answer = 42"

    "format3_int_long_string",
    """
package F3
import Std.Core
import Std.Parse
func main(): Unit {
  match tryParseLong("100") {
    case Ok(big) -> println(format3("{0}/{1}/{2}", 1, big, "x"))
    case Err(_) -> println("err")
  }
}
""",
    "1/100/x"

    "format4_multi_placeholder",
    """
package F4
func main(): Unit {
  println(format4("[{0},{1},{2},{3}]", 1, 2, 3, 4))
}
""",
    "[1,2,3,4]"

    "format_repeat_placeholder",
    """
package F5
func main(): Unit {
  println(format1("{0} and {0} again", "echo"))
}
""",
    "echo and echo again"
]

let tests =
    testSequenced
    <| testList "codegen builtins (toString)" (cases |> List.map mk)
