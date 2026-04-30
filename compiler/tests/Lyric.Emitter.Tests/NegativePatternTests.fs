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

    // The earlier "Long pattern matching is broken" turned out to
    // be a wrong-syntax issue (`100L` isn't a valid Lyric integer
    // literal — the spec uses `100i64`).  Patterns of either suffix
    // dispatch correctly against a `Long` scrutinee.
    "long_literal_pattern_with_i64_suffix",
    """
package NP_LongI64
func describe(n: in Long): String {
  match n {
    case 100i64  -> "hundred"
    case -100i64 -> "minus-hundred"
    case 0i64    -> "zero"
    case _       -> "other"
  }
}
func main(): Unit {
  println(describe(100i64))
  println(describe(-100i64))
  println(describe(0i64))
  println(describe(7i64))
}
""",
    "hundred\nminus-hundred\nzero\nother"

    "int_literal_pattern_on_long_scrutinee",
    """
package NP_IntOnLong
// An unsuffixed Int literal in a pattern still matches against a
// Long scrutinee — the JIT widens Ldc.I4 so the Ceq pair lines up.
func describe(n: in Long): String {
  match n {
    case 100 -> "hundred"
    case 0   -> "zero"
    case _   -> "other"
  }
}
func main(): Unit {
  println(describe(100i64))
  println(describe(0i64))
  println(describe(42i64))
}
""",
    "hundred\nzero\nother"

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
