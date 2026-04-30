/// Tests for BCL method/property dispatch on built-in CLR types.
///
/// Lyric source uses camelCase (`s.length`, `s.trim()`) and the
/// emitter falls back to PascalCase reflection lookup on receivers
/// whose CLR type lives under `System.*` (or is a primitive).
/// Overloads are resolved by argument type so `s.contains(string)`
/// picks `String.Contains(String)` rather than `Contains(Char)`.
module Lyric.Emitter.Tests.BclDispatchTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "string_length_property",
    """
package BCL1
func main(): Unit {
  println("hello".length)
  println("".length)
}
""",
    "5\n0"

    "string_trim_chained",
    """
package BCL2
func main(): Unit {
  val s = "   padded   "
  println(s.trim())
  println(s.trim().length)
}
""",
    "padded\n6"

    "string_starts_ends_contains",
    """
package BCL3
func main(): Unit {
  println("hello".startsWith("hel"))
  println("hello".endsWith("lo"))
  println("hello".contains("ll"))
  println("hello".startsWith("zzz"))
}
""",
    "True\nTrue\nTrue\nFalse"

    "string_to_upper_lower",
    """
package BCL4
func main(): Unit {
  println("Hello".toUpper())
  println("HELLO".toLower())
}
""",
    "HELLO\nhello"

    "string_indexOf",
    """
package BCL5
func main(): Unit {
  println("hello".indexOf("ll"))
  println("hello".indexOf("zzz"))
}
""",
    "2\n-1"
]

let tests =
    testSequenced
    <| testList "BCL method/property dispatch"
        (cases |> List.map mk)
