//! stdlib/tests/tcp_host_tests.l - runtime tests for the plain-TCP half of
//! `Std.TcpHost` on `--target dotnet` and `--target jvm` (the JVM kernel,
//! `_kernel_jvm/tcp_host.l`, was missing before #9042, so any use failed with
//! `J002`). The server-side TLS half is `tcp_host_tls_tests.l`.
//!
//! Every peer is a `Std.TcpHost` connection on its own `Std.Task.scopeSpawn`
//! task (a pool task on dotnet, a virtual thread on the JVM), on an ephemeral
//! port read back with `hostLocalPort`, so the suite needs no fixed ports.
//!
//! Coverage: an echo round trip with `hostAlpn == ""`, the remote address, end
//! of stream as an empty read, a payload larger than one read, a refused
//! connection, `hostConnect` with a connect timeout (a live listener, and a
//! blackholed address that must end within a bound), `hostSetIoTimeout` ending
//! a read on a silent peer, and `hostStopListener` ending a blocked accept.
//!
//!   lyric test --target dotnet lyric-stdlib/tests/tcp_host_tests.l
//!   lyric test --target jvm lyric-stdlib/tests/tcp_host_tests.l
@test_module
package Std.TcpHost.Tests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.String
import Std.Task as Task
import Std.TcpHost
import Std.Testing
import Std.Time as Time

func listenLoopback(): Listener {
  match hostListen("127.0.0.1", 0) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
}

func connectTo(l: in Listener): Conn {
  match hostConnect("127.0.0.1", hostLocalPort(l), 5000) {
    case Ok(c) -> c
    case Err(e) -> panic("connect failed: " + TcpError.message(e))
  }
}

func background(work: in () -> Unit): Task.Scope {
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, work)
  sc
}

// Echo every chunk until the client closes its half.
func echoUntilEof(l: in Listener): Unit {
  match hostAccept(l) {
    case Err(_) -> ()
    case Ok(conn) -> {
      var open = true
      while open {
        match hostRead(conn, 65536) {
          case Err(_) -> {
            open = false
          }
          case Ok(chunk) -> if chunk.length == 0 {
            open = false
          } else {
            match hostWrite(conn, chunk) {
              case Ok(_) -> ()
              case Err(_) -> {
                open = false
              }
            }
          }
        }
      }
      hostClose(conn)
    }
  }
}

func readExactly(conn: in Conn, expected: in Int): String {
  var got = ""
  while got.length < expected {
    match hostRead(conn, 65536) {
      case Err(e) -> panic("read failed after " + got.length.toString() + " bytes: " + TcpError.message(e))
      case Ok(chunk) -> {
        if chunk.length == 0 {
          panic("end of stream after " + got.length.toString() + " of " + expected.toString() + " bytes")
        }
        match tryDecodeUtf8(chunk) {
          case Some(text) -> {
            got = got + text
          }
          case None -> panic("received bytes were not UTF-8")
        }
      }
    }
  }
  got
}

test "plain echo round trip: ALPN, remote address and end of stream" {
  val l = listenLoopback()
  assertTrue(hostLocalPort(l) > 0, "an ephemeral port was assigned")
  val server = background({ -> echoUntilEof(l) })
  val conn = connectTo(l)
  assertEqual(hostAlpn(conn), "", "a plain connection has no ALPN")
  assertTrue(hostRemoteAddress(conn).endsWith(":" + hostLocalPort(l).toString()), "remote address names the peer port")
  match hostWrite(conn, encodeUtf8("ping")) {
    case Ok(_) -> ()
    case Err(e) -> panic("write failed: " + TcpError.message(e))
  }
  assertEqual(readExactly(conn, 4), "ping", "the echo returns the sent bytes")
  hostClose(conn)
  val _ = await Task.awaitAll(server)
  hostStopListener(l)
}

test "a read returns an empty slice once the peer has closed" {
  val l = listenLoopback()
  val server = background({ -> match hostAccept(l) { case Ok(c) -> hostClose(c); case Err(_) -> () } })
  val conn = connectTo(l)
  match hostRead(conn, 1024) {
    case Ok(chunk) -> assertEqualInt(chunk.length, 0, "end of stream is an empty read")
    case Err(_) -> assertTrue(true, "a reset connection is also an end of the stream")
  }
  hostClose(conn)
  val _ = await Task.awaitAll(server)
  hostStopListener(l)
}

test "a payload larger than one read round-trips intact" {
  val l = listenLoopback()
  val server = background({ -> echoUntilEof(l) })
  val conn = connectTo(l)
  val payload = repeat("0123456789abcdef", 6400)
  match hostWrite(conn, encodeUtf8(payload)) {
    case Ok(_) -> ()
    case Err(e) -> panic("write failed: " + TcpError.message(e))
  }
  val echoed = readExactly(conn, payload.length)
  assertTrue(echoed == payload, "the 102400 echoed bytes equal the sent bytes")
  hostClose(conn)
  val _ = await Task.awaitAll(server)
  hostStopListener(l)
}

test "a refused connection is TransportFailed" {
  val l = listenLoopback()
  val port = hostLocalPort(l)
  hostStopListener(l)
  match hostConnect("127.0.0.1", port, 2000) {
    case Ok(_) -> panic("expected the connection to be refused")
    case Err(e) -> match e {
      case TransportFailed(_) -> assertTrue(true, "refused connect is TransportFailed")
      case _ -> panic("expected TransportFailed, got " + TcpError.message(e))
    }
  }
}

test "a connect timeout does not stop a connect that succeeds" {
  val l = listenLoopback()
  val server = background({ -> match hostAccept(l) { case Ok(c) -> hostClose(c); case Err(_) -> () } })
  val conn = match hostConnect("127.0.0.1", hostLocalPort(l), 3000) {
    case Ok(c) -> c
    case Err(e) -> panic("connect within a limit failed: " + TcpError.message(e))
  }
  hostClose(conn)
  val _ = await Task.awaitAll(server)
  hostStopListener(l)
}

// 10.255.255.1 is a private address that usually has no route or drops the
// SYN; either way the call must end within the bound and fail, never hang.
test "a connect to an address that does not answer ends within the limit" {
  val started = Time.monotonicNanos()
  val r = hostConnect("10.255.255.1", 81, 300)
  val elapsedMs = (Time.monotonicNanos() - started) / 1000000i64
  match r {
    case Ok(c) -> {
      hostClose(c)
      panic("expected the connect to fail")
    }
    case Err(e) -> match e {
      case TransportFailed(_) -> assertTrue(
        elapsedMs < 4000i64,
        "the connect ended after " + elapsedMs.toString() + " ms"
      )
      case _ -> panic("expected TransportFailed, got " + TcpError.message(e))
    }
  }
}

test "hostSetIoTimeout ends a read on a silent peer with TransportFailed" {
  val l = listenLoopback()
  val server = background(
    { ->
      match hostAccept(l) {
        case Ok(c) -> {
          Time.sleepMillis(1500)
          hostClose(c)
        }
        case Err(_) -> ()
      }
    }
  )
  val conn = connectTo(l)
  hostSetIoTimeout(conn, 200)
  val started = Time.monotonicNanos()
  val r = hostRead(conn, 1024)
  val elapsedMs = (Time.monotonicNanos() - started) / 1000000i64
  match r {
    case Ok(_) -> panic("expected the read to time out")
    case Err(e) -> match e {
      case TransportFailed(_) -> {
        assertTrue(elapsedMs >= 100i64, "the read waited for the limit: " + elapsedMs.toString() + " ms")
        assertTrue(
          elapsedMs < 1400i64,
          "the read ended at the limit, not at the peer's close: " + elapsedMs.toString() + " ms"
        )
      }
      case _ -> panic("expected TransportFailed, got " + TcpError.message(e))
    }
  }
  hostClose(conn)
  val _ = await Task.awaitAll(server)
  hostStopListener(l)
}

test "hostStopListener ends a blocked accept with an error" {
  val l = listenLoopback()
  val outcome: List[String] = newList()
  val server = background(
    { ->
      match hostAccept(l) {
        case Ok(c) -> {
          outcome.add("accepted")
          hostClose(c)
        }
        case Err(e) -> outcome.add("error:" + TcpError.message(e))
      }
    }
  )
  Time.sleepMillis(200)
  hostStopListener(l)
  val _ = await Task.awaitAll(server)
  assertEqualInt(outcome.count, 1, "the accept returned")
  assertTrue(outcome[0].startsWith("error:accept failed"), "the accept failed: " + outcome[0])
}
