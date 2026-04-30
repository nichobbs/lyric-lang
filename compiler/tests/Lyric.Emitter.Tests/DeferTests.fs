/// Tests for `defer { ... }` blocks (language reference §4.3).
///
/// `defer` runs its body on scope exit — success or failure — and
/// lowers to a CLR `try/finally` wrapping the remainder of the
/// enclosing block.  Multiple defers in one scope nest LIFO so the
/// most recently registered cleanup runs first.
///
/// **v1 limitations** (tracked for follow-up):
/// 1. `return` from inside a defer-wrapped region currently emits
///    invalid IL — `return` uses `br` to the function exit label,
///    but ECMA-335 requires `leave` to cross a protected region.
///    Fixing this needs the codegen to track "am I inside a try?".
/// 2. Defers in expression-position blocks (non-void lambda bodies,
///    `if`-as-expression branches) hit `failwith` at codegen — the
///    value-on-stack discipline conflicts with `try/finally`'s
///    requirement that the protected region leave nothing on the
///    stack.  Workaround: store the value in a `val` first.
module Lyric.Emitter.Tests.DeferTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "defer_runs_on_scope_exit",
    """
package DeferA
func main(): Unit {
  defer { println("after") }
  println("before")
}
""",
    "before\nafter"

    "multiple_defers_run_LIFO",
    """
package DeferB
func main(): Unit {
  defer { println("first registered") }
  defer { println("second registered") }
  defer { println("third registered") }
  println("body")
}
""",
    "body\nthird registered\nsecond registered\nfirst registered"

    "defer_inside_if_branch",
    """
package DeferC
func main(): Unit {
  if true {
    defer { println("if-cleanup") }
    println("if-body")
  }
  println("after-if")
}
""",
    "if-body\nif-cleanup\nafter-if"

    "defer_with_local_capture",
    """
package DeferD
func main(): Unit {
  val name = "world"
  defer { println("bye " + name) }
  println("hi " + name)
}
""",
    "hi world\nbye world"

    "defer_inside_loop_runs_each_iteration",
    """
package DeferE
func main(): Unit {
  var i = 0
  while i < 3 {
    defer { println("clean") }
    println("iter " + i)
    i += 1
  }
}
""",
    "iter 0\nclean\niter 1\nclean\niter 2\nclean"

    "nested_blocks_each_run_their_defers",
    """
package DeferG
func main(): Unit {
  defer { println("outer-cleanup") }
  if true {
    defer { println("inner-cleanup") }
    println("inner-body")
  }
  println("outer-after")
}
""",
    "inner-body\ninner-cleanup\nouter-after\nouter-cleanup"
]

let tests =
    testSequenced
    <| testList "defer blocks" (cases |> List.map mk)
