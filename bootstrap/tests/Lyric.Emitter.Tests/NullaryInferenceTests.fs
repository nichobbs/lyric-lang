/// Tests for context-driven inference of nullary union cases.
/// Without a value to bind T from, codegen takes the type-args from
/// (in priority order):
///   1. `ctx.ExpectedType` — set by val annotations + call arg
///      positions
///   2. `ctx.ReturnType` — the enclosing function's result type
///   3. obj fallback (which usually means a runtime cast failure)
module Lyric.Emitter.Tests.NullaryInferenceTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    // (1) val annotation drives the inference.
    "val_annotation_drives_none",
    """
package NU1
import Std.Core
func main(): Unit {
  val o: Option[Int] = None
  println(unwrapOr(o, 99))
}
""",
    "99"

    // (2) Function-call arg position drives the inference.
    "call_arg_position_drives_none",
    """
package NU2
import Std.Core
func describe(o: Option[Int]): Int {
  match o {
    case Some(v) -> v
    case None    -> -1
  }
}
func main(): Unit {
  println(describe(None))
}
""",
    "-1"

    // (3) Function return type still works (regression coverage for
    //     the original ctx.ReturnType path).
    "return_type_drives_none",
    """
package NU3
import Std.Core
func empty(): Option[Int] = None
func main(): Unit {
  println(unwrapOr(empty(), 7))
}
""",
    "7"

    // (4) Local generic union, val-annotation flavour.
    "local_generic_val_drives_empty",
    """
package NU4
generic[T] union Box {
  case Wrapped(value: T)
  case Empty
}
func main(): Unit {
  val b: Box[Int] = Empty
  match b {
    case Wrapped(v) -> println(v)
    case Empty      -> println(99)
  }
}
""",
    "99"

    // (5) Imported generic Result with val annotation.
    "result_via_val_annotation",
    """
package NU5
import Std.Core
func main(): Unit {
  val r: Result[Int, String] = Ok(value = 12)
  match r {
    case Ok(v)  -> println(v)
    case Err(e) -> println(0)
  }
}
""",
    "12"
]

let tests =
    testSequenced
    <| testList "nullary case context-driven inference"
        (cases |> List.map mk)
