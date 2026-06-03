/// Tests for cross-assembly generic types: user code references
/// `Std.Core`'s `Option[T]` / `Result[T,E]` and the precompiled
/// stdlib's generic methods (`unwrapOr`, `mapOption`, …) without
/// either side resorting to obj erasure at the call boundary.
module Lyric.Emitter.Tests.CrossAssemblyGenericTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "imported_generic_union_int",
    """
package XGU1
import Std.Core

func main(): Unit {
  val o = Some(value = 42)
  println(unwrapOr(o, 0))
}
""",
    "42"

    "imported_generic_union_string",
    """
package XGU2
import Std.Core

func main(): Unit {
  val o = Some(value = "hi")
  println(unwrapOr(o, "missing"))
}
""",
    "hi"

    "imported_generic_result",
    """
package XGU3
import Std.Core

func main(): Unit {
  val ok: Result[Int, String] = Ok(value = 7)
  val err: Result[Int, String] = Err(error = "bad")
  println(unwrapResultOr(ok, 0))
  println(unwrapResultOr(err, 0))
}
""",
    "7\n0"

    "imported_higher_order_mapOption",
    """
package XGU4
import Std.Core

func main(): Unit {
  val r = mapOption(Some(value = 5), { x: Int -> x * 3 })
  println(unwrapOr(r, 0))
}
""",
    "15"

    "imported_match_on_generic_option",
    """
package XGU5
import Std.Core

func describe(o: Option[Int]): Int {
  match o {
    case Some(v) -> v + 100
    case None    -> -1
  }
}

func main(): Unit {
  println(describe(Some(value = 42)))
  // `None` in arg position now infers T from the param type via
  // ctx.ExpectedType, so this works without a typed helper.
  println(describe(None))
}
""",
    "142\n-1"
]

let tests =
    testSequenced
    <| testList "cross-assembly generic types"
        (cases |> List.map mk)
