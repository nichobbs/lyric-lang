//! stdlib/tests/http_server_stop_tests.l - the `stopListener` contract of the
//! shared HTTP server driver (docs/73 slice S3, D788, D780 decision 8) and the
//! regression map of docs/73 section 1.6, on real loopback sockets.
//!
//! The contract: `stopListener` marks the listener stopping, closes its socket,
//! shuts down every registered connection, completes every request still
//! queued and never pulled, wakes every puller parked in `nextContext` or
//! `tryNextContext`, and returns once the accept loop and every connection task
//! have finished, bounded by `LYRIC_HTTP_STOP_GRACE_MS`. A second call returns
//! at once. After it, `nextContext` panics and `tryNextContext` returns `None`,
//! and neither ever blocks.
//!
//! Each case names the race it pins (the issue numbers of the native kernel's
//! stop fixes, which this driver inherits for every target):
//!
//!   - an idle keep-alive connection must not hang the stop (#6791);
//!   - a connection that finishes before its registration is looked at must not
//!     leave an entry behind (#6792);
//!   - connections ending naturally while the stop walks the registry (#6795);
//!   - requests queued and never pulled, with their credits (#6796, #6803);
//!   - a puller parked in `nextContext` racing the stop (#6802);
//!   - a listener stopped before it ever served (#6806).
//!
//! The suite uses only `Std.HttpServerHost` (`startTask`, `Semaphore`,
//! `Mutex`) for its background threads and raw `Std.TcpHost` clients, so it
//! has no extern of its own and is written to run on any target whose
//! `Std.HttpServer` is the shared driver; it is wired for dotnet today (the
//! JVM and native kernels adopt the driver in S4 and S5).
//!
//!   lyric test --target dotnet lyric-stdlib/tests/http_server_stop_tests.l
@test_module
package Std.HttpServer.StopTests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Environment as Env
import Std.HttpServer
import Std.HttpServerHost
import Std.String
import Std.TcpHost
import Std.Testing
import Std.Time

// A counter several threads bump.
ref record Tally {
  guard: Mutex
  var n: Int
}

func newTally(): Tally {
  Tally(guard = newMutex(), n = 0)
}

func tallyAdd(t: in Tally, by: in Int): Unit {
  lock(t.guard)
  t.n = t.n + by
  unlock(t.guard)
}

func tallyGet(t: in Tally): Int {
  lock(t.guard)
  val n = t.n
  unlock(t.guard)
  n
}

func dial(port: in Int): Result[Conn, TcpError] {
  hostConnect("127.0.0.1", port, 2000)
}

// A client connection whose reads give up after `ms` instead of hanging a test.
func dialOrPanic(port: in Int, ms: in Int): Conn {
  match dial(port) {
    case Ok(c) -> {
      hostSetIoTimeout(c, ms)
      c
    }
    case Err(e) -> panic("connect to " + port.toString() + " failed: " + TcpError.message(e))
  }
}

// Whether reading `conn` ends (end of stream or an error) within its timeout,
// discarding what arrives first. A server that shut the connection down ends it
// at once; one that left it open would time out.
func readsEnd(conn: in Conn): Bool {
  var tries = 0
  var ended = false
  while tries < 50 and not ended {
    match hostRead(conn, 4096) {
      case Err(_) -> {
        ended = true
      }
      case Ok(bytes) -> {
        if bytes.length == 0 {
          ended = true
        }
      }
    }
    tries = tries + 1
  }
  ended
}

// Read until `marker` is seen or the connection ends.
func readsContain(conn: in Conn, marker: in String): Bool {
  var acc = ""
  var found = false
  var done = false
  while not found and not done {
    match hostRead(conn, 4096) {
      case Err(_) -> {
        done = true
      }
      case Ok(bytes) -> {
        if bytes.length == 0 {
          done = true
        } else {
          match tryDecodeUtf8(bytes) {
            case Some(s) -> {
              acc = acc + s
            }
            case None -> ()
          }
          found = acc.contains(marker)
        }
      }
    }
  }
  found
}

func getRequest(path: in String, keepAlive: in Bool): slice[Byte] {
  val connection = if keepAlive { "keep-alive" } else { "close" }
  encodeUtf8("GET " + path + " HTTP/1.1\r\nHost: x\r\nConnection: " + connection + "\r\n\r\n")
}

// A puller that answers every request until the listener is stopped, then
// posts to `ended`.
func servePuller(l: in HttpListener, served: in Tally, ended: in Semaphore): Unit {
  var running = true
  while running {
    match tryNextContext(l) {
      case Some(ctx) -> {
        respondText(ctx, 200, "ok " + requestPath(ctx))
        tallyAdd(served, 1)
      }
      case None -> {
        running = false
      }
    }
  }
  semPost(ended)
}

func elapsedMs(since: in Long): Long {
  nowEpochMillis() - since
}

test "stopListener ends an idle keep-alive connection and returns (#6791)" {
  val l = startListener("http://127.0.0.1:19601/")
  val served = newTally()
  val ended = newSem(0)
  startTask({ -> servePuller(l, served, ended) })
  val c = dialOrPanic(19601, 5000)
  val _ = hostWrite(c, getRequest("/a", true))
  assertTrue(readsContain(c, "ok /a"), "the first request is answered")
  // The connection is now idle keep-alive: its task is parked in a read.
  val t0 = nowEpochMillis()
  stopListener(l)
  assertTrue(elapsedMs(t0) < 3000i64, "stop returned without waiting for the idle connection to time out")
  assertTrue(readsEnd(c), "the client sees the connection end")
  hostClose(c)
  semWait(ended)
  assertEqualInt(tallyGet(served), 1, "exactly the one request was served")
}

test "many connections that open and drop leave the listener serving and stoppable (#6792)" {
  val l = startListener("http://127.0.0.1:19602/")
  val served = newTally()
  val ended = newSem(0)
  startTask({ -> servePuller(l, served, ended) })
  var i = 0
  while i < 200 {
    val c = dialOrPanic(19602, 5000)
    hostClose(c)
    i = i + 1
  }
  val real = dialOrPanic(19602, 5000)
  val _ = hostWrite(real, getRequest("/real", false))
  assertTrue(readsContain(real, "ok /real"), "a real request is served after the churn")
  hostClose(real)
  stopListener(l)
  semWait(ended)
  assertEqualInt(tallyGet(served), 1, "only the real request reached the puller")
}

// One client: connection-per-request GETs until a request fails.
func hammer(port: in Int, ok: in Tally, finished: in Semaphore): Unit {
  var running = true
  while running {
    match dial(port) {
      case Err(_) -> {
        running = false
      }
      case Ok(c) -> {
        hostSetIoTimeout(c, 3000)
        match hostWrite(c, getRequest("/h", false)) {
          case Err(_) -> {
            running = false
          }
          case Ok(_) -> {
            if readsContain(c, "ok /h") {
              tallyAdd(ok, 1)
            } else {
              running = false
            }
          }
        }
        hostClose(c)
      }
    }
  }
  semPost(finished)
}

test "a stop while twenty clients are mid-flight returns and ends them (#6795)" {
  val l = startListener("http://127.0.0.1:19603/")
  val served = newTally()
  val ended = newSem(0)
  startTask({ -> servePuller(l, served, ended) })
  val ok = newTally()
  val finished = newSem(0)
  var i = 0
  while i < 20 {
    startTask({ -> hammer(19603, ok, finished) })
    i = i + 1
  }
  sleepMillis(300)
  val t0 = nowEpochMillis()
  stopListener(l)
  assertTrue(elapsedMs(t0) < 4000i64, "stop returned while clients were mid-flight")
  var j = 0
  while j < 20 {
    semWait(finished)
    j = j + 1
  }
  semWait(ended)
  assertTrue(tallyGet(ok) > 0, "requests were being served before the stop")
}

// One client that sends a request and waits for the connection to end.
func sendAndWaitForEnd(port: in Int, ended: in Tally, finished: in Semaphore): Unit {
  val c = dialOrPanic(port, 5000)
  val _ = hostWrite(c, getRequest("/q", true))
  if readsEnd(c) {
    tallyAdd(ended, 1)
  }
  hostClose(c)
  semPost(finished)
}

test "requests queued and never pulled are completed at stop and their connections end (#6796, #6803)" {
  val l = startListener("http://127.0.0.1:19604/")
  val ended = newTally()
  val finished = newSem(0)
  var i = 0
  while i < 20 {
    startTask({ -> sendAndWaitForEnd(19604, ended, finished) })
    i = i + 1
  }
  // No puller: the requests pile up in the queue.
  sleepMillis(500)
  val t0 = nowEpochMillis()
  stopListener(l)
  assertTrue(elapsedMs(t0) < 4000i64, "stop returned although no request was ever pulled")
  var j = 0
  while j < 20 {
    semWait(finished)
    j = j + 1
  }
  assertEqualInt(tallyGet(ended), 20, "every client saw its connection end")
}

func pullOnce(l: in HttpListener, code: in Tally, ended: in Semaphore): Unit {
  match tryNextContext(l) {
    case Some(_) -> tallyAdd(code, 1)
    case None -> tallyAdd(code, 100)
  }
  semPost(ended)
}

test "a puller parked in tryNextContext is woken by stop (#6802)" {
  var round = 0
  while round < 15 {
    val l = startListener("http://127.0.0.1:19605/")
    val code = newTally()
    val ended = newSem(0)
    startTask({ -> pullOnce(l, code, ended) })
    if round % 2 == 0 {
      sleepMillis(20)
    }
    stopListener(l)
    semWait(ended)
    assertEqualInt(tallyGet(code), 100, "the parked puller got None")
    round = round + 1
  }
}

test "several parked pullers are all woken by one stop" {
  val l = startListener("http://127.0.0.1:19606/")
  val code = newTally()
  val ended = newSem(0)
  var i = 0
  while i < 8 {
    startTask({ -> pullOnce(l, code, ended) })
    i = i + 1
  }
  sleepMillis(100)
  stopListener(l)
  var j = 0
  while j < 8 {
    semWait(ended)
    j = j + 1
  }
  assertEqualInt(tallyGet(code), 800, "all eight pullers got None")
}

test "after stop nextContext panics, tryNextContext returns None, and neither blocks" {
  val l = startListener("http://127.0.0.1:19607/")
  stopListener(l)
  assertPanicsWith("nextContext after stop", "was stopped", { -> val _ = nextContext(l); () })
  match tryNextContext(l) {
    case Some(_) -> assertTrue(false, "a stopped listener has no context")
    case None -> assertTrue(true, "None")
  }
  match tryNextContext(l) {
    case Some(_) -> assertTrue(false, "still no context")
    case None -> assertTrue(true, "None again: the wake is not consumed")
  }
}

test "stopListener is idempotent" {
  val l = startListener("http://127.0.0.1:19608/")
  stopListener(l)
  val t0 = nowEpochMillis()
  stopListener(l)
  stopListener(l)
  assertTrue(elapsedMs(t0) < 500i64, "the repeated stops returned at once")
}

test "a listener stopped at once after start releases its port every time (#6806)" {
  var i = 0
  while i < 10 {
    val l = startListener("http://127.0.0.1:19609/")
    stopListener(l)
    i = i + 1
  }
  val l2 = startListener("http://127.0.0.1:19609/")
  val served = newTally()
  val ended = newSem(0)
  startTask({ -> servePuller(l2, served, ended) })
  val c = dialOrPanic(19609, 5000)
  val _ = hostWrite(c, getRequest("/again", false))
  assertTrue(readsContain(c, "ok /again"), "the port serves again after ten start-stop cycles")
  hostClose(c)
  stopListener(l2)
  semWait(ended)
}

test "no connection is accepted after stop" {
  val l = startListener("http://127.0.0.1:19610/")
  stopListener(l)
  match dial(19610) {
    case Ok(c) -> {
      // A kernel that still holds the listening socket's backlog may complete
      // the connect; nothing may ever serve it.
      hostSetIoTimeout(c, 500)
      val _ = hostWrite(c, getRequest("/late", false))
      assertTrue(not readsContain(c, "ok /late"), "a connection after stop is never answered")
      hostClose(c)
    }
    case Err(_) -> assertTrue(true, "the connect was refused")
  }
}

// Pulls one request and holds it unanswered until `release` is posted.
func holdOne(l: in HttpListener, held: in Semaphore, release: in Semaphore, done: in Semaphore): Unit {
  match tryNextContext(l) {
    case Some(ctx) -> {
      semPost(held)
      semWait(release)
      respondText(ctx, 200, "late")
    }
    case None -> ()
  }
  semPost(done)
}

test "a context the caller still holds delays stop by the grace period only" {
  Env.setVar("LYRIC_HTTP_STOP_GRACE_MS", "400")
  val l = startListener("http://127.0.0.1:19611/")
  Env.setVar("LYRIC_HTTP_STOP_GRACE_MS", "5000")
  val held = newSem(0)
  val release = newSem(0)
  val done = newSem(0)
  startTask({ -> holdOne(l, held, release, done) })
  val c = dialOrPanic(19611, 5000)
  val _ = hostWrite(c, getRequest("/held", false))
  semWait(held)
  val t0 = nowEpochMillis()
  stopListener(l)
  val took = elapsedMs(t0)
  assertTrue(took >= 300i64, "stop waited for the outstanding context (took " + took.toString() + " ms)")
  assertTrue(took < 3000i64, "stop gave up after the grace period (took " + took.toString() + " ms)")
  semPost(release)
  semWait(done)
  hostClose(c)
}

test "resolveStopGraceMs reads LYRIC_HTTP_STOP_GRACE_MS and falls back on a bad value" {
  Env.setVar("LYRIC_HTTP_STOP_GRACE_MS", "250")
  assertEqualInt(resolveStopGraceMs(), 250, "an integer in range is used")
  Env.setVar("LYRIC_HTTP_STOP_GRACE_MS", "0")
  assertEqualInt(resolveStopGraceMs(), 5000, "zero falls back")
  Env.setVar("LYRIC_HTTP_STOP_GRACE_MS", "soon")
  assertEqualInt(resolveStopGraceMs(), 5000, "a non-number falls back")
  Env.setVar("LYRIC_HTTP_STOP_GRACE_MS", "5000")
  assertEqualInt(resolveStopGraceMs(), 5000, "the default")
}

test "the connection cap defaults to the target's own and LYRIC_HTTP_MAX_CONNECTIONS overrides it" {
  assertEqualInt(resolveMaxConcurrentConnections(), defaultMaxConnections(), "no override: the target default")
  Env.setVar("LYRIC_HTTP_MAX_CONNECTIONS", "7")
  assertEqualInt(resolveMaxConcurrentConnections(), 7, "an override is used")
  Env.setVar("LYRIC_HTTP_MAX_CONNECTIONS", "0")
  assertEqualInt(resolveMaxConcurrentConnections(), defaultMaxConnections(), "zero falls back")
  Env.setVar("LYRIC_HTTP_MAX_CONNECTIONS", "")
}
