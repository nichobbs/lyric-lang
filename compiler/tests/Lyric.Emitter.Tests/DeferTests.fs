/// Tests for `defer { ... }` blocks (language reference §4.3).
///
/// `defer` runs its body on scope exit — success or failure — and
/// lowers to a CLR `try/finally` wrapping the remainder of the
/// enclosing block.  Multiple defers in one scope nest LIFO so the
/// most recently registered cleanup runs first.  Inside a defer-
/// wrapped region, `return` / `break` / `continue` route through
/// `leave` instead of `br` so the JIT verifier accepts the cross-
/// protected-region branch.
///
/// **Remaining limitation** (tracked for follow-up):
/// Defers in expression-position blocks (non-void lambda bodies,
/// `if`-as-expression branches) hit `failwith` at codegen — the
/// value-on-stack discipline conflicts with `try/finally`'s
/// requirement that the protected region leave nothing on the
/// stack.  Workaround: store the value in a `val` first.
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

    "defer_runs_on_early_return_void",
    """
package DeferRet1
func work(panic: in Bool): Unit {
  defer { println("cleanup") }
  if panic {
    println("early")
    return
  }
  println("normal")
}
func main(): Unit {
  work(false)
  work(true)
}
""",
    "normal\ncleanup\nearly\ncleanup"

    "defer_runs_on_early_return_with_value",
    """
package DeferRet2
func work(panic: in Bool): Int {
  defer { println("cleanup") }
  if panic {
    return -1
  }
  return 42
}
func main(): Unit {
  println(work(false))
  println(work(true))
}
""",
    "cleanup\n42\ncleanup\n-1"

    "defer_runs_on_break_out_of_loop",
    """
package DeferBreak
func main(): Unit {
  var i = 0
  while i < 5 {
    defer { println("clean") }
    if i == 2 {
      println("break")
      break
    }
    i += 1
  }
  println("after-loop")
}
""",
    "clean\nclean\nbreak\nclean\nafter-loop"

    "defer_runs_on_continue_in_loop",
    """
package DeferCont
func main(): Unit {
  var i = 0
  while i < 3 {
    defer { println("clean") }
    if i == 1 {
      i += 1
      continue
    }
    println("iter")
    i += 1
  }
}
""",
    "iter\nclean\nclean\niter\nclean"

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
