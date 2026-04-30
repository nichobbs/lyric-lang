/// Tests for negative literal patterns in `match` arms.
///
/// `case -1 -> …` was previously rejected by the parser (P0073).
/// The parser now encodes `-N` as the two's-complement of `N` in
/// a uint64 and stores it as a plain `LInt` pattern; the existing
/// codegen emits the matching wrapping-cast Ldc.* opcode.
module Lyric.Emitter.Tests.NegativePatternTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "negative_int_literal_pattern",
    """
package NP1
func describe(n: in Int): String {
  match n {
    case -1 -> "minus-one"
    case 0  -> "zero"
    case 1  -> "one"
    case _  -> "other"
  }
}
func main(): Unit {
  println(describe(-1))
  println(describe(0))
  println(describe(1))
  println(describe(42))
}
""",
    "minus-one\nzero\none\nother"

    // (Long literal patterns like `case 100L` have a separate
    // codegen issue today where the Ldc.I4-vs-Ldc.I8 stack discipline
    // doesn't match cleanly — tracked outside negative-pattern scope.)

    "negative_float_literal_pattern",
    """
package NP3
func describe(f: in Double): String {
  match f {
    case -1.5 -> "negish"
    case 0.0  -> "zero"
    case _    -> "other"
  }
}
func main(): Unit {
  println(describe(-1.5))
  println(describe(0.0))
  println(describe(3.14))
}
""",
    "negish\nzero\nother"

    "negative_int_pattern_in_chained_match",
    """
package NP4
func sign(n: in Int): Int {
  match n {
    case -1 -> -1
    case 0  -> 0
    case _  -> 1
  }
}
func main(): Unit {
  println(sign(-1))
  println(sign(0))
  println(sign(99))
}
""",
    "-1\n0\n1"
]

let tests =
    testSequenced
    <| testList "negative literal patterns" (cases |> List.map mk)
