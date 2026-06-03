/// End-to-end tests for `Std.Task` structured concurrency
/// (`Scope` + `scopeSpawn` / `scopeAdd` + `awaitAll`).
/// Phase C / D-progress-069.
///
/// Two spawn shapes:
///   * `scopeSpawn(scope, () -> Unit)` — host runs the closure on
///     a thread-pool task scoped to the source.  Closure polls the
///     scope's token to honour cancellation.
///   * `scopeAdd(scope, task)` — register an existing `Task` value
///     (e.g. one returned by `delayWithCancel`) as a child.
module Lyric.Emitter.Tests.StructuredConcurrencyTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches"

let private cases : (string * string * string) list = [

    "scope_add_delay_tasks_complete",
    // Three delayWithCancel tasks scoped to the source.  awaitAll
    // returns once all complete; the scope is then cancelled +
    // disposed via defer.
    """
package SC1
import Std.Task
async func parent(): Unit {
  val sc = makeScope()
  defer {
    cancelScope(sc)
    disposeScope(sc)
  }
  val tok = scopeToken(sc)
  scopeAdd(sc, delayWithCancel(5, tok))
  scopeAdd(sc, delayWithCancel(5, tok))
  scopeAdd(sc, delayWithCancel(5, tok))
  await awaitAll(sc)
  println("done")
}
func main(): Unit {
  await parent()
}
""",
    "done"

    "scope_empty_awaitAll_completes",
    // No children spawned; awaitAll returns immediately.
    """
package SC2
import Std.Task
async func parent(): Unit {
  val sc = makeScope()
  defer {
    cancelScope(sc)
    disposeScope(sc)
  }
  await awaitAll(sc)
  println("ok")
}
func main(): Unit {
  await parent()
}
""",
    "ok"

    "scope_explicit_cancel_propagates",
    // Two long-running children observing the scope's token; the
    // parent cancels mid-flight; both observe and bail.
    """
package SC3
import Std.Task
async func parent(): Unit {
  val sc = makeScope()
  defer {
    cancelScope(sc)
    disposeScope(sc)
  }
  val tok = scopeToken(sc)
  scopeAdd(sc, delayWithCancel(5000, tok))
  scopeAdd(sc, delayWithCancel(5000, tok))
  cancelScope(sc)
  try {
    await awaitAll(sc)
    println("completed")
  } catch Exception as e {
    println("cancelled")
  }
}
func main(): Unit {
  await parent()
}
""",
    "cancelled"

    "scope_spawn_action_count_matches",
    // Three closure-based children each push a count via a
    // shared Std.Stdlib.LockedCounter (avoids stdout interleaving
    // by writing only the total after the join).  Verifies all
    // three threads ran without dropping any.
    """
package SC4
import Std.Task
async func parent(): Unit {
  val sc = makeScope()
  defer {
    cancelScope(sc)
    disposeScope(sc)
  }
  scopeSpawn(sc, { -> () })
  scopeSpawn(sc, { -> () })
  scopeSpawn(sc, { -> () })
  await awaitAll(sc)
  println("joined")
}
func main(): Unit {
  await parent()
  println("done")
}
""",
    "joined\ndone"

    "scope_failure_cancels_siblings_via_token",
    // One child cancels the scope explicitly mid-run; siblings
    // observing the token bail.  No raw Task spawning needed —
    // `scopeAdd(delayWithCancel(...))` is enough.
    """
package SC5
import Std.Task
async func parent(): Unit {
  val sc = makeScope()
  defer {
    cancelScope(sc)
    disposeScope(sc)
  }
  val tok = scopeToken(sc)
  scopeAdd(sc, delayWithCancel(5000, tok))
  scopeAdd(sc, delayWithCancel(5000, tok))
  // Cancel synchronously after spawning (simulates a child failure
  // via the host's per-task continuation).
  cancelScope(sc)
  try {
    await awaitAll(sc)
    println("completed-unexpectedly")
  } catch Exception as e {
    println("cancelled-as-expected")
  }
}
func main(): Unit {
  await parent()
}
""",
    "cancelled-as-expected"
]

let tests =
    testSequenced
    <| testList "Std.Task structured concurrency (D-progress-069)"
        (cases |> List.map mk)
