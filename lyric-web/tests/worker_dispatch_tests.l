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
import Std.Time as Time
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

// A worker whose first tick panics, then ticks normally — proves
// `startWorkerLoop`'s per-tick crash isolation (#6935): before that fix, an
// uncaught `Bug` from `tick()` silently and permanently stopped this
// worker's loop (the loop's `Task` is fire-and-forget and never observed),
// so `flakyCounter.n` would stay at 0 forever after the first tick.
record FlakyCounter {
  var n: Int
  var crashed: Bool
}

val flakyCounter: FlakyCounter = FlakyCounter(n = 0, crashed = false)

record FlakyWorker {
}

impl Worker for FlakyWorker {
  func tick(): Unit {
    if not flakyCounter.crashed {
      flakyCounter.crashed = true
      panic("intentional crash for the worker crash-isolation test (#6935)")
    }
    flakyCounter.n = flakyCounter.n + 1
  }
}

record FlakyTickCountHandler {
}

impl Web.Handler for FlakyTickCountHandler {
  func handle(req: in Web.Request): Web.Response {
    Web.text(200, flakyCounter.n.toString())
  }
}

func flakyWorkerRouter(): Web.Router {
  var r = Web.create()
  r = Web.addGet(r, "/flaky-ticks", FlakyTickCountHandler())
  r = Web.addWorker(r, "flaky", 30, FlakyWorker())
  r
}

// `Web.serve` blocks the calling thread forever once bound, on EITHER
// target — on `dotnet` in its own accept loop, on `jvm` behind
// `Web.Kernel.Runtime`'s `CountDownLatch.await()` (Undertow's own listener
// binds asynchronously via `server.start()`, but the wrapping kernel call
// still blocks so a real server process stays up) — so each target needs
// its own background-thread primitive: real concurrency `spawn` cannot give
// this on `dotnet` (degenerate-synchronous, D119/D120), and a Lyric closure
// cannot be handed to an arbitrary JDK functional interface on `jvm` (the
// strongly-typed-delegate FFI, docs/50, is scoped to `@externTarget`
// function parameters) — same reasoning as `Web.Kernel.Runtime`'s own
// `WorkerLoopRunnable` (`_kernel/jvm/web_kernel.l`).
@cfg(feature = "dotnet")
extern type Task = "System.Threading.Tasks.Task"

@cfg(feature = "dotnet")
@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@cfg(feature = "dotnet")
func startServerForTest(r: in Web.Router, port: in Int): Unit {
  val _ = taskRun({ -> Web.serve(r, "127.0.0.1", port) })
}

@cfg(feature = "jvm")
extern type JRunnable = "java.lang.Runnable"

@cfg(feature = "jvm")
extern type JExecutorService = "java.util.concurrent.ExecutorService"

@cfg(feature = "jvm")
@externStatic
@externTarget("java.util.concurrent.Executors.newVirtualThreadPerTaskExecutor")
func newVirtualThreadPerTaskExecutor(): JExecutorService = ()

@cfg(feature = "jvm")
val testServerExecutor: JExecutorService = newVirtualThreadPerTaskExecutor()

@cfg(feature = "jvm")
record TestServerRunnable {
  r: Web.Router
  port: Int
}

@cfg(feature = "jvm")
impl JRunnable for TestServerRunnable {
  func run(): Unit {
    Web.serve(self.r, "127.0.0.1", self.port)
  }
}

@cfg(feature = "jvm")
func startServerForTest(r: in Web.Router, port: in Int): Unit {
  val runnable: JRunnable = TestServerRunnable(r = r, port = port)
  val _ = testServerExecutor.submit(runnable)
}

func getTickCount(client: in HttpClient, url: in String, maxAttempts: in Int): Int {
  var attempt = 0
  var value = -1
  var done = false
  while attempt < maxAttempts and not done {
    Time.sleepMillis(30)
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
  startServerForTest(workerRouter(), port)

  val ticksUrl = "http://127.0.0.1:" + port.toString() + "/ticks"

  // Wait for the server to come up, then read the tick count twice with a
  // gap in between — proving it INCREASES (the worker is actually firing
  // repeatedly), not merely that it starts at some nonzero value.
  val first = getTickCount(client, ticksUrl, 60)
  assertTrue(first >= 0, "server did not come up in time")

  Time.sleepMillis(200)
  val second = getTickCount(client, ticksUrl, 5)
  assertTrue(second >= 0, "second /ticks request failed")
  assertTrue(second > first, "tick count did not increase — the worker is not firing on a real loop (#5359)")
}

test "a panicking tick is isolated: addWorker's loop survives a Bug and keeps ticking (#6935)" {
  val port = 18951
  val client = HttpClientBuilder.build(HttpClientBuilder.new())
  startServerForTest(flakyWorkerRouter(), port)

  val flakyUrl = "http://127.0.0.1:" + port.toString() + "/flaky-ticks"

  // The first tick panics and increments nothing, so this just proves the
  // server is up; the real assertion is that the count keeps rising after
  // that first, crashing tick.
  val first = getTickCount(client, flakyUrl, 60)
  assertTrue(first >= 0, "server did not come up in time")

  Time.sleepMillis(200)
  val second = getTickCount(client, flakyUrl, 5)
  assertTrue(second >= 0, "second /flaky-ticks request failed")
  assertTrue(second > first, "worker loop did not survive its first tick's panic and keep going (#6935)")
}
