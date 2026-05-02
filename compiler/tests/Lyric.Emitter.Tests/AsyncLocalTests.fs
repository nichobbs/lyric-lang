/// End-to-end tests for AsyncLocal-backed ambient cancellation
/// (`Std.Task.currentToken` + `installToken` + `restoreToken`).
/// Phase C follow-up / D-progress-071.
///
/// The ambient slot flows naturally across `await` boundaries via
/// .NET's AsyncLocal<T>, so async children inherit the parent
/// scope's token without threading it through every signature.
module Lyric.Emitter.Tests.AsyncLocalTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches"

let private cases : (string * string * string) list = [

    "ambient_default_is_no_cancellation",
    """
package AL1
import Std.Core
import Std.Task
func main(): Unit {
  println(toString(hasAmbient()))
  val t = currentToken()
  println(toString(isCancelled(t)))
}
""",
    "False\nFalse"

    "ambient_install_then_restore",
    // Install a token, observe via currentToken / hasAmbient,
    // restore, verify the slot is back to default.
    """
package AL2
import Std.Core
import Std.Task
func main(): Unit {
  val src = makeCancelSource()
  val previous = installToken(sourceToken(src))
  println(toString(hasAmbient()))
  cancelSource(src)
  println(toString(isCancelled(currentToken())))
  restoreToken(previous)
  println(toString(hasAmbient()))
  disposeSource(src)
}
""",
    "True\nTrue\nFalse"

    "ambient_flows_across_await",
    // Install a token in main, read it from inside an async
    // child after an await.  AsyncLocal<T> guarantees the value
    // flows across the suspension.
    """
package AL3
import Std.Core
import Std.Task
async func child(): String {
  await delay(2)
  if hasAmbient() {
    "child-saw-ambient"
  } else {
    "child-saw-default"
  }
}
func main(): Unit {
  val src = makeCancelSource()
  val previous = installToken(sourceToken(src))
  defer {
    restoreToken(previous)
    disposeSource(src)
  }
  println(await child())
}
""",
    "child-saw-ambient"

    "ambient_propagates_cancellation",
    // The parent installs a token, cancels it, and the child
    // observes via the ambient slot — no token argument was
    // threaded through the call.
    """
package AL4
import Std.Core
import Std.Task
async func child(): String {
  val tok = currentToken()
  if isCancelled(tok) {
    "child-saw-cancelled"
  } else {
    "child-saw-active"
  }
}
func main(): Unit {
  val src = makeCancelSource()
  cancelSource(src)
  val previous = installToken(sourceToken(src))
  defer {
    restoreToken(previous)
    disposeSource(src)
  }
  println(await child())
}
""",
    "child-saw-cancelled"
]

let tests =
    testSequenced
    <| testList "Std.Task ambient cancellation (D-progress-071)"
        (cases |> List.map mk)
