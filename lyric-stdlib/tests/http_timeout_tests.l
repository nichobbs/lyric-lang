//! Std.Http: a send that ends because its deadline passed is
//! `HttpError.Timeout`, on every target (#9067); every other failure stays
//! `ConnectionFailed`.
//!
//! The cases run against loopback `Std.TcpHost` peers that misbehave in one
//! way: a listener that accepts and never answers (100 sends, each with a 25 ms
//! deadline, which is the shape that exposed the JVM's early-fire race: the JDK
//! timer reported the timeout before the token's lazy `System.nanoTime()`
//! comparison turned true), one that sends headers and stalls in the body (the
//! JDK request timeout covers only the headers, so the body read needs its own
//! bound), and a closed port. Each timed-out send must also leave its token
//! cancelled.
//!
//!   lyric test --target dotnet lyric-stdlib/tests/http_timeout_tests.l
//!   lyric test --target jvm lyric-stdlib/tests/http_timeout_tests.l
@test_module
package Std.Http.TimeoutTests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Errors
import Std.Http
import Std.Task as Task
import Std.TcpHost as Tcp
import Std.Testing
import Std.Time as Time

func listenLoopback(): Tcp.Listener {
  match Tcp.hostListen("127.0.0.1", 0) {
    case Ok(l) -> l
    case Err(e) -> panic(Tcp.TcpError.message(e))
  }
}

func urlOf(l: in Tcp.Listener, path: in String): Url {
  match Url.tryFrom("http://127.0.0.1:" + Tcp.hostLocalPort(l).toString() + path) {
    case Ok(u) -> u
    case Err(e) -> panic(HttpError.message(e))
  }
}

func plainClient(): HttpClient {
  HttpClientBuilder.new().withNoRedirects().build()
}

func isTimeout(e: in HttpError): Bool {
  match e {
    case Timeout(_, _) -> true
    case _ -> false
  }
}

func isConnectionFailed(e: in HttpError): Bool {
  match e {
    case ConnectionFailed(_, _) -> true
    case _ -> false
  }
}

// Accepts connections and keeps them open without ever answering, until the
// listener is stopped.
func acceptAndHold(l: in Tcp.Listener, held: in List[Tcp.Conn]): Unit {
  var open = true
  while open {
    match Tcp.hostAccept(l) {
      case Ok(c) -> {
        held.add(c)
      }
      case Err(_) -> {
        open = false
      }
    }
  }
}

// Accepts one connection, reads the request, sends `head`, and holds the
// connection until the client hangs up.
func acceptSendAndStall(l: in Tcp.Listener, head: in String): Unit {
  match Tcp.hostAccept(l) {
    case Err(_) -> ()
    case Ok(c) -> {
      val _request = Tcp.hostRead(c, 8192)
      val _sent = Tcp.hostWrite(c, encodeUtf8(head))
      val _hangup = Tcp.hostRead(c, 8192)
      Tcp.hostClose(c)
    }
  }
}

func closeAll(held: in List[Tcp.Conn]): Unit {
  var i = 0
  while i < held.count {
    Tcp.hostClose(held[i])
    i = i + 1
  }
}

test "100 sends to a listener that never answers are all HttpError.Timeout with a cancelled token" {
  val l = listenLoopback()
  val held: List[Tcp.Conn] = newList()
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, { -> acceptAndHold(l, held) })
  val client = plainClient()
  val url = urlOf(l, "/silent")
  var timeouts = 0
  var tokenNotCancelled = 0
  var other = ""
  var i = 0
  while i < 100 {
    val src = Task.makeCancelSourceTimeout(25)
    val tok = Task.sourceToken(src)
    val r = await client.sendWithCancel(request(GET, url), tok)
    match r {
      case Ok(_) -> {
        other = "send " + i.toString() + " returned a response"
      }
      case Err(e) -> if isTimeout(e) {
        timeouts = timeouts + 1
      } else {
        other = "send " + i.toString() + ": " + HttpError.message(e)
      }
    }
    if not Task.isCancelled(tok) {
      tokenNotCancelled = tokenNotCancelled + 1
    }
    Task.disposeSource(src)
    i = i + 1
  }
  Tcp.hostStopListener(l)
  val _ = await Task.awaitAll(sc)
  closeAll(held)
  assertEqual(other, "", "every send timed out")
  assertEqualInt(timeouts, 100, "every send is HttpError.Timeout")
  assertEqualInt(tokenNotCancelled, 0, "the token reads as cancelled whenever a send reports a timeout")
}

test "headers followed by a stalled body end at the deadline as HttpError.Timeout" {
  val l = listenLoopback()
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, { -> acceptSendAndStall(l, "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial") })
  // The clock starts before the deadline timer does. The dotnet timer behind `makeCancelSourceTimeout`
  // (`CancellationTokenSource(int)`) runs on a millisecond tick clock and can fire up to a few ms
  // before the deadline against a high-resolution clock (#9419: 399 ms for a 400 ms deadline), so the
  // lower bound allows `timerSlackMs`; the JVM and native deadlines are checked on the measuring
  // clock and never fire early. The slack is far below the 400 ms deadline, so a send ended by
  // anything but the deadline still fails the bound.
  val timerSlackMs = 10i64
  val started = Time.monotonicNanos()
  val src = Task.makeCancelSourceTimeout(400)
  val tok = Task.sourceToken(src)
  val r = await plainClient().sendWithCancel(request(GET, urlOf(l, "/stalled-body")), tok)
  val elapsedMs = (Time.monotonicNanos() - started) / 1000000i64
  match r {
    case Ok(_) -> panic("expected the stalled body to end the send")
    case Err(e) -> assertTrue(isTimeout(e), "the error is HttpError.Timeout: " + HttpError.message(e))
  }
  assertTrue(Task.isCancelled(tok), "the token reads as cancelled")
  assertTrue(elapsedMs >= 400i64 - timerSlackMs, "not reported before the deadline: " + elapsedMs.toString() + " ms")
  assertTrue(
    elapsedMs < 4000i64,
    "reported at the deadline, not when the peer gives up: " + elapsedMs.toString() + " ms"
  )
  Tcp.hostStopListener(l)
  val _ = await Task.awaitAll(sc)
}

test "a refused connection under a deadline stays ConnectionFailed and the token is not cancelled" {
  val l = listenLoopback()
  val url = urlOf(l, "/refused")
  Tcp.hostStopListener(l)
  val src = Task.makeCancelSourceTimeout(5000)
  val tok = Task.sourceToken(src)
  val r = await plainClient().sendWithCancel(request(GET, url), tok)
  match r {
    case Ok(_) -> panic("expected the connection to be refused")
    case Err(e) -> {
      assertTrue(isConnectionFailed(e), "the error is ConnectionFailed: " + HttpError.message(e))
      assertFalse(isTimeout(e), "not a timeout")
    }
  }
  assertFalse(Task.isCancelled(tok), "the token is not cancelled")
  Task.disposeSource(src)
}
