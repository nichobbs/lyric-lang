/// Tests for `try { ... } catch <Type> [as <bind>] { ... }` as a
/// statement form (D-progress-048).
///
/// Each catch's `<Type>` resolves via a small built-in mapping
/// (`Bug` / `Exception` / `Error` → `System.Exception`) with a
/// reflective fallback for fully qualified CLR exception names.
/// Awaits inside the try body fall back to the M1.4 blocking shim
/// (suspend-inside-try is Phase B+++ work).
module Lyric.Emitter.Tests.TryCatchTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "try_catch_no_throw",
    """
package T1
func main(): Unit {
  var r: Int = 0
  try {
    r = 7
  } catch Bug as b {
    r = -1
  }
  println(toString(r))
}
""",
    "7"

    "try_catch_panic_caught",
    """
package T2
func boom(): Int {
  panic("oh no")
}
func main(): Unit {
  var r: Int = 0
  try {
    r = boom()
  } catch Bug as b {
    r = -1
  }
  println(toString(r))
}
""",
    "-1"

    "try_catch_no_bind",
    // The `as` binding is optional; without it the exception is
    // popped off the stack and the handler sees no local.
    """
package T3
func boom(): Int { panic("nope") }
func main(): Unit {
  var r: Int = 0
  try {
    r = boom()
  } catch Bug {
    r = -2
  }
  println(toString(r))
}
""",
    "-2"

    "try_catch_with_async_await",
    // The await happens inside the try via the M1.4 blocking shim
    // (synchronously-completed Task → fast path).  Validates the
    // try/catch + EAwait combination compiles.
    """
package T4
async func mkInt(): Int = 99
func main(): Unit {
  var r: Int = 0
  try {
    r = await mkInt()
  } catch Bug as b {
    r = -1
  }
  println(toString(r))
}
""",
    "99"

    "try_as_expression_basic",
    // D-progress-049: `try { … } catch …` in expression position
    // (e.g. `return try { ... } catch ...`).  Each tail expression
    // (body's last stmt + each catch's last stmt) leaves its value
    // in a result local; the surrounding expression sees the
    // unified value after the protected region closes.
    """
package T5
func work(): Int {
  return try {
    21 + 21
  } catch Bug as b {
    -1
  }
}
func main(): Unit {
  println(toString(work()))
}
""",
    "42"

    "try_as_expression_catch_path",
    """
package T6
func boom(): Int { panic("nope") }
func work(): Int {
  return try {
    boom()
  } catch Bug as b {
    -7
  }
}
func main(): Unit {
  println(toString(work()))
}
""",
    "-7"

    "try_as_expression_with_await",
    // `return try { await … } catch …` — the canonical Std.Http
    // shape.  Synchronously-completing Task takes the fast path
    // through the M1.4 blocking shim; the exception flow runs
    // through the surrounding catch.
    """
package T7
async func mkInt(): Int = 55
async func doit(): Int {
  return try {
    await mkInt()
  } catch Bug as b {
    -1
  }
}
func main(): Unit {
  println(toString(await doit()))
}
""",
    "55"
]

let tests =
    testSequenced
    <| testList "try-catch (D-progress-048)"
        (cases |> List.map mk)
