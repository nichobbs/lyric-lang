//! tests/concurrent_dispatch_tests.l — regression pin for #7997: the dotnet
//! accept loops (`Web.serve`, `Web.serveStreaming`) used to run each handler
//! inline, so one slow or streaming request stalled every other request.
//!
//! A `/slow` handler blocks until the test releases it. While it is blocked, a
//! request to `/fast` must still complete; the slow request is only released
//! afterwards, so a sequential server never answers `/fast` and the test fails
//! instead of passing by timing luck. `jvm` is excluded: Undertow already
//! dispatches on its own worker threads.
@test_module
package Web.ConcurrentDispatchTests

import Std.Core
import Std.Http
import Std.Time as Time
import Web
import Std.Testing

record Gate {
  var released: Bool
  var slowEntered: Bool
  var slowDone: Bool
}

val gate: Gate = Gate(released = false, slowEntered = false, slowDone = false)

record FastHandler {
}

impl Web.Handler for FastHandler {
  func handle(req: in Web.Request): Web.Response {
    Web.text(200, "fast")
  }
}

record SlowHandler {
}

impl Web.Handler for SlowHandler {
  func handle(req: in Web.Request): Web.Response {
    gate.slowEntered = true
    var waited = 0
    while not gate.released and waited < 10000 {
      Time.sleepMillis(20)
      waited = waited + 20
    }
    gate.slowDone = true
    Web.text(200, "slow")
  }
}

func concurrentRouter(): Web.Router {
  var r = Web.create()
  r = Web.addGet(r, "/fast", FastHandler())
  r = Web.addGet(r, "/slow", SlowHandler())
  r
}

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

@cfg(feature = "dotnet")
func pollStatus(client: in HttpClient, url: in String, maxAttempts: in Int): Int {
  var attempt = 0
  var status = 0
  var done = false
  while attempt < maxAttempts and not done {
    Time.sleepMillis(50)
    match await client.get(url) {
      case Ok(resp) -> {
        status = HttpResponse.statusCode(resp)
        done = true
      }
      case Err(_) -> {
        attempt = attempt + 1
      }
    }
  }
  return status
}

@cfg(feature = "dotnet")
func fetchSlow(url: in String): Unit {
  val client = HttpClientBuilder.build(HttpClientBuilder.new())
  match await client.get(url) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

@cfg(feature = "dotnet")
test "a blocked handler does not stall other requests (#7997)" {
  val port = 18941
  val client = HttpClientBuilder.build(HttpClientBuilder.new())
  startServerForTest(concurrentRouter(), port)

  val base = "http://127.0.0.1:" + port.toString()
  assertEqualInt(pollStatus(client, base + "/fast", 40), 200, "server is up")

  val slowUrl = base + "/slow"
  val _ = taskRun({ -> fetchSlow(slowUrl) })

  var waited = 0
  while not gate.slowEntered and waited < 5000 {
    Time.sleepMillis(20)
    waited = waited + 20
  }
  assertTrue(gate.slowEntered, "the slow handler is running")

  assertEqualInt(
    pollStatus(client, base + "/fast", 40),
    200,
    "/fast is served while /slow is still blocked in its handler"
  )
  assertTrue(not gate.slowDone, "/slow was still in flight when /fast completed")

  gate.released = true
}
