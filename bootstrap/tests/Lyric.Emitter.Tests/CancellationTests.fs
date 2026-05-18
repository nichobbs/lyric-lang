/// End-to-end tests for `Std.Task` cancellation tokens (Phase C /
/// D-progress-068).  Cooperative cancellation: the awaitee accepts
/// a token, the caller flips the source, the awaitee throws
/// OperationCanceledException → caught on the Lyric side as
/// `Exception`.
module Lyric.Emitter.Tests.CancellationTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches"

let private cases : (string * string * string) list = [

    "cancel_token_none_isCancelled_is_false",
    """
package CT1
import Std.Task
func main(): Unit {
  val t = noCancellation()
  println(toString(isCancelled(t)))
}
""",
    "False"

    "cancel_source_make_then_cancel",
    """
package CT2
import Std.Task
func main(): Unit {
  val src = makeCancelSource()
  val tok = sourceToken(src)
  println(toString(isCancelled(tok)))
  cancelSource(src)
  println(toString(isCancelled(tok)))
  disposeSource(src)
}
""",
    "False\nTrue"

    "cancel_throwIfCancelled_propagates",
    """
package CT3
import Std.Task
func main(): Unit {
  val src = makeCancelSource()
  val tok = sourceToken(src)
  cancelSource(src)
  try {
    throwIfCancelled(tok)
    println("not thrown")
  } catch Exception as e {
    println("cancelled")
  }
  disposeSource(src)
}
""",
    "cancelled"

    "cancel_delay_cooperative",
    // The delay is given a long timeout but the source is
    // cancelled immediately; awaiting the cancellable delay
    // resumes with OperationCanceledException, which Lyric
    // catches as `Exception`.
    """
package CT4
import Std.Task
async func runner(token: in CancellationToken): Unit {
  try {
    await delayWithCancel(5000, token)
    println("completed")
  } catch Exception as e {
    println("cancelled-during-delay")
  }
}
func main(): Unit {
  val src = makeCancelSource()
  val tok = sourceToken(src)
  cancelSource(src)
  await runner(tok)
  disposeSource(src)
}
""",
    "cancelled-during-delay"

    "cancel_timeout_source",
    // makeCancelSourceTimeout(ms) auto-cancels after the
    // delay; the test cancels in 10 ms, then awaits a 200ms
    // delay which is interrupted.
    """
package CT5
import Std.Task
async func runner(token: in CancellationToken): Unit {
  try {
    await delayWithCancel(200, token)
    println("completed")
  } catch Exception as e {
    println("cancelled-by-timeout")
  }
}
func main(): Unit {
  val src = makeCancelSourceTimeout(10)
  val tok = sourceToken(src)
  await runner(tok)
  disposeSource(src)
}
""",
    "cancelled-by-timeout"

    "cancel_structured_via_defer",
    // The canonical structured-concurrency-via-defer pattern.
    // The defer ensures the source is cancelled + disposed on
    // scope exit so any in-flight async children are signalled
    // even when the surrounding code panics or returns early.
    // Reads like Phase 4's eventual `scope { ... }` block.
    """
package CT6
import Std.Task
async func work(token: in CancellationToken): Unit {
  try {
    await delayWithCancel(2000, token)
    println("work-completed")
  } catch Exception as e {
    println("work-cancelled")
  }
}
async func runner(): Unit {
  val src = makeCancelSource()
  defer {
    cancelSource(src)
    disposeSource(src)
  }
  val tok = sourceToken(src)
  cancelSource(src)
  await work(tok)
}
func main(): Unit {
  await runner()
  println("after-scope")
}
""",
    "work-cancelled\nafter-scope"
]

let tests =
    testSequenced
    <| testList "Std.Task cancellation (D-progress-068)"
        (cases |> List.map mk)
