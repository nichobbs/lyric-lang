//! stdlib/tests/http_async_concurrency_tests.l - the public async Std.Http
//! client surface is truly asynchronous on `--target dotnet` (#5608).
//!
//! Before the fix every kernel await in `Std.HttpHost` (`clientGetAsync`,
//! `contentReadAsString`, ...) was a blocking `Task.get_Result` inside the
//! extern wrapper, so an `async func` state machine never suspended on I/O:
//! `client.get(url)` blocked its caller until the response headers arrived and
//! two requests issued from one thread ran back to back.
//!
//! The server side runs on `Task.Run` threads (the handlers sleep, so the
//! server itself is concurrent: #6107). The client side is a single thread
//! that starts both requests before awaiting either, so the elapsed time
//! tells the two apart: overlapping requests take about one handler delay,
//! serialized ones take two.
//!
//! dotnet only: the JVM and native clients are covered by their own suites.
@test_module
package Std.Http.AsyncConcurrencyTests

import Std.Core
import Std.Collections
import Std.String
import Std.Http
import Std.HttpServer
import Std.Testing
import Std.Time

extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func taskWait(t: in Task): Unit = ()

@externStatic
@externTarget("System.Threading.Thread.Sleep")
func threadSleep(ms: in Int): Unit = ()

val handlerDelayMs: Int = 1500

func handleSlow(ctx: in HttpContext): Unit {
  threadSleep(handlerDelayMs)
  respondText(ctx, 200, "slow " + requestPath(ctx))
}

// Serve `n` requests, each on its own thread so they can overlap.
func serveConcurrently(l: in HttpListener, n: in Int): Unit {
  val handlers: List[Task] = newList()
  var i = 0
  while i < n {
    val ctx = nextContext(l)
    handlers.add(taskRun({ -> handleSlow(ctx) }))
    i = i + 1
  }
  var j = 0
  while j < handlers.count {
    taskWait(handlers[j])
    j = j + 1
  }
}

func elapsedMs(startNanos: in Long): Int {
  ((monotonicNanos() - startNanos) / 1000000i64).toInt()
}

async func fetchBody(client: in HttpClient, url: in String): String {
  match await client.get(url) {
    case Err(e) -> return "error " + HttpError.message(e)
    case Ok(r) -> match await r.bodyText() {
      case Ok(t) -> return t
      case Err(_) -> return "body-error"
    }
  }
}

test "two slow requests issued from one thread overlap (#5608)" {
  val listener = startListener("http://127.0.0.1:19451/")
  val server = taskRun({ -> serveConcurrently(listener, 2) })
  threadSleep(100)
  val client = defaultClient()
  val start = monotonicNanos()
  var a = ""
  var b = ""
  scope {
    val ta = spawn fetchBody(client, "http://127.0.0.1:19451/a")
    val tb = spawn fetchBody(client, "http://127.0.0.1:19451/b")
    a = await ta
    b = await tb
  }
  val totalMs = elapsedMs(start)
  taskWait(server)
  stopListener(listener)
  assertEqual(a, "slow /a", "first response body")
  assertEqual(b, "slow /b", "second response body")
  assertTrue(totalMs >= handlerDelayMs, "each request really was slow (" + toString(totalMs) + " ms)")
  assertTrue(
    totalMs < handlerDelayMs * 2 - 200,
    "the two requests overlapped instead of running back to back (" + toString(totalMs) + " ms)"
  )
}
