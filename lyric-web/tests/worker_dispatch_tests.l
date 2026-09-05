//! tests/worker_dispatch_tests.l — end-to-end regression pin for
//! `Web.addWorker`'s background dispatch loop (#5359).
//!
//! Before this fix, `Web.addWorker` registered a `WorkerRegistration` that
//! `Web.serve`/`Web.serveStreaming`/`Web.serveTls` never read at all —
//! registered workers were never invoked. `Web.Worker` is now a real
//! interface (mirroring `Handler`/`Middleware`, #5363) fired on a genuine
//! background `Task.Run`-backed thread once the server starts
//! (`Web.Kernel.Runtime.startWorkerLoop`, `_kernel/net/web_kernel.l`).
//!
//! Drives a REAL `Web.serve` listener in-process, same background-`Task.Run`
//! + real Lyric `HttpClient` pattern `serve_tls_tests.l`/
//! `serve_crash_isolation_tests.l` use — the worker's own dispatch is a
//! SECOND, independent `Task.Run` started by `serve()` itself, so this
//! exercises two concurrently-running background tasks against each other.
@test_module
package Web.WorkerDispatchTests

import Std.Core
import Std.Http
import Std.Parse
import Web
import Std.Testing

// A worker that increments a shared counter on every tick. Reads/writes to
// a bare `Int` field are good enough for this test's purpose (proving the
// tick fired repeatedly over a bounded polling window) without a lock —
// this is not exercising the counter's precision, only its liveness.
record TickCounter {
  var n: Int
}

val tickCounter: TickCounter = TickCounter(n = 0)

record CountingWorker {
}

impl Worker for CountingWorker {
  func tick(): Unit {
    tickCounter.n = tickCounter.n + 1
  }
}

record TickCountHandler {
}

impl Web.Handler for TickCountHandler {
  func handle(req: in Web.Request): Web.Response {
    Web.text(200, tickCounter.n.toString())
  }
}

func workerRouter(): Web.Router {
  var r = Web.create()
  r = Web.addGet(r, "/ticks", TickCountHandler())
  r = Web.addWorker(r, "counter", 30, CountingWorker())
  r
}

// Same background-server-thread pattern as `serve_crash_isolation_tests.l`
// / `serve_tls_tests.l`: `Task.Run(Action)` gives real concurrency `spawn`
// cannot on this target (D119/D120).
extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@externStatic
@externTarget("System.Threading.Thread.Sleep")
func threadSleep(ms: in Int): Unit = ()

func runServeBg(r: in Web.Router, port: in Int): Unit {
  Web.serve(r, "127.0.0.1", port)
}

func getTickCount(client: in HttpClient, url: in String, maxAttempts: in Int): Int {
  var attempt = 0
  var value = -1
  var done = false
  while attempt < maxAttempts and not done {
    threadSleep(30)
    match await client.get(url) {
      case Ok(resp) -> {
        val body = match await HttpResponse.bodyText(resp) { case Ok(b) -> b; case Err(_) -> "" }
        value = unwrapOr(parseOptInt(body), -1)
        done = true
      }
      case Err(_) -> {
        attempt = attempt + 1
      }
    }
  }
  return value
}

test "addWorker's registered Worker actually fires on a real background loop" {
  val port = 18950
  val client = HttpClientBuilder.build(HttpClientBuilder.new())
  val _ = taskRun({ -> runServeBg(workerRouter(), port) })

  val ticksUrl = "http://127.0.0.1:" + port.toString() + "/ticks"

  // Wait for the server to come up, then read the tick count twice with a
  // gap in between — proving it INCREASES (the worker is actually firing
  // repeatedly), not merely that it starts at some nonzero value.
  val first = getTickCount(client, ticksUrl, 60)
  assertTrue(first >= 0, "server did not come up in time")

  threadSleep(200)
  val second = getTickCount(client, ticksUrl, 5)
  assertTrue(second >= 0, "second /ticks request failed")
  assertTrue(second > first, "tick count did not increase — the worker is not firing on a real loop (#5359)")
}
