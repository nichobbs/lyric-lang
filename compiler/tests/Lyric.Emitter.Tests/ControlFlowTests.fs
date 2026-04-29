module Lyric.Emitter.Tests.ControlFlowTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

/// Build one test that compiles `source`, runs it, and asserts on
/// trimmed stdout. Each `mk` arg is a (label, source, expected)
/// triple — pre-extracted as a value to keep F#'s offside rule
/// happy with the multi-line triple-quoted strings.
let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected
            "stdout matches expected"

let private cases : (string * string * string) list = [
    "locals_val",
    """
package E3
func main(): Unit {
  val x = 1 + 2
  println(x)
}
""",
    "3"

    "locals_var",
    """
package E3
func main(): Unit {
  var y = 5
  println(y)
}
""",
    "5"

    "locals_let",
    """
package E3
func main(): Unit {
  let z = 7 * 6
  println(z)
}
""",
    "42"

    "locals_chained",
    """
package E3
func main(): Unit {
  val a = 10
  val b = a + 5
  val c = b * 2
  println(c)
}
""",
    "30"

    "assign_simple",
    """
package E3
func main(): Unit {
  var x = 1
  x = 99
  println(x)
}
""",
    "99"

    "assign_compound_plus",
    """
package E3
func main(): Unit {
  var x = 10
  x += 5
  println(x)
}
""",
    "15"

    "assign_compound_mul",
    """
package E3
func main(): Unit {
  var x = 3
  x *= 4
  println(x)
}
""",
    "12"

    "if_then_else_true",
    """
package E3
func main(): Unit {
  println(if true then 1 else 2)
}
""",
    "1"

    "if_then_else_false",
    """
package E3
func main(): Unit {
  println(if 1 < 2 then 100 else 200)
}
""",
    "100"

    "if_block_only",
    """
package E3
func main(): Unit {
  var x = 0
  if 1 < 2 {
    x = 42
  }
  println(x)
}
""",
    "42"

    "if_else_block",
    """
package E3
func main(): Unit {
  var x = 0
  if 1 > 2 {
    x = 1
  } else {
    x = 2
  }
  println(x)
}
""",
    "2"

    "while_count",
    """
package E3
func main(): Unit {
  var i = 0
  while i < 5 {
    i += 1
  }
  println(i)
}
""",
    "5"

    "while_sum",
    """
package E3
func main(): Unit {
  var i = 1
  var sum = 0
  while i <= 10 {
    sum += i
    i += 1
  }
  println(sum)
}
""",
    "55"

    "break_early",
    """
package E3
func main(): Unit {
  var i = 0
  while i < 100 {
    if i == 5 { break }
    i += 1
  }
  println(i)
}
""",
    "5"

    "continue_skip_evens",
    """
package E3
func main(): Unit {
  var i = 0
  var oddSum = 0
  while i < 10 {
    i += 1
    if i % 2 == 0 { continue }
    oddSum += i
  }
  println(oddSum)
}
""",
    "25"

    "nested_while",
    """
package E3
func main(): Unit {
  var i = 0
  var total = 0
  while i < 3 {
    var j = 0
    while j < 4 {
      total += 1
      j += 1
    }
    i += 1
  }
  println(total)
}
""",
    "12"
]

let tests =
    testSequenced
    <| testList "locals + control flow (E3)"
        (cases |> List.map mk)
