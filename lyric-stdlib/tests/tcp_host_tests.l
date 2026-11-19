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
//! The server-readiness additions (D621, docs/73 slice S1): `hostShutdown`
//! ending a read, and a write blocked on a stalled peer, from another thread;
//! a write timeout on a stalled peer; `maxBytes` honoured by a read; thousands
//! of small reads; a multi-megabyte round trip; and concurrent connections.
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

// Echo every chunk of `conn` until the peer closes its half, then close it.
func echoConn(conn: in Conn): Unit {
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

// Accept one connection and echo every chunk until the client closes its half.
func echoUntilEof(l: in Listener): Unit {
  match hostAccept(l) {
    case Err(_) -> ()
    case Ok(conn) -> echoConn(conn)
  }
}

// Accept one connection and read nothing from it until `release` is non-empty,
// so the peer's writes fill the socket buffers and then block.
func stallUntilReleased(l: in Listener, release: in List[String]): Unit {
  match hostAccept(l) {
    case Err(_) -> ()
    case Ok(conn) -> {
      var waited = 0
      while release.count == 0 and waited < 400 {
        Time.sleepMillis(25)
        waited = waited + 1
      }
      hostClose(conn)
    }
  }
}

// Write 256 KiB chunks until a write fails (the peer is not reading, so the
// socket buffers fill and the write blocks until it is interrupted or times
// out); records `error:<message>` or `completed` in `outcome`.
func writeUntilFailure(conn: in Conn, outcome: in List[String]): Unit {
  val chunk = encodeUtf8(repeat("0123456789abcdef", 16384))
  var i = 0
  var failed = false
  while not failed and i < 4000 {
    match hostWrite(conn, chunk) {
      case Ok(_) -> ()
      case Err(e) -> {
        outcome.add("error:" + TcpError.message(e))
        failed = true
      }
    }
    i = i + 1
  }
  if not failed {
    outcome.add("completed")
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

test "hostShutdown ends a read blocked on a silent peer from another thread" {
  val l = listenLoopback()
  val server = background({ -> echoUntilEof(l) })
  val conn = connectTo(l)
  val outcome: List[String] = newList()
  val reader = background(
    { ->
      match hostRead(conn, 1024) {
        case Ok(chunk) -> outcome.add("read:" + chunk.length.toString())
        case Err(_) -> outcome.add("error")
      }
    }
  )
  Time.sleepMillis(300)
  assertEqualInt(outcome.count, 0, "the read is still blocked before the shutdown")
  val started = Time.monotonicNanos()
  hostShutdown(conn)
  val _ = await Task.awaitAll(reader)
  val elapsedMs = (Time.monotonicNanos() - started) / 1000000i64
  assertEqualInt(outcome.count, 1, "the blocked read returned")
  assertTrue(
    outcome[0] == "read:0" or outcome[0] == "error",
    "a shut-down read is end of stream or an error: " + outcome[0]
  )
  assertTrue(elapsedMs < 2000i64, "the read ended promptly after the shutdown: " + elapsedMs.toString() + " ms")
  hostClose(conn)
  val _2 = await Task.awaitAll(server)
  hostStopListener(l)
}

test "hostShutdown ends a write blocked on a stalled peer from another thread" {
  val l = listenLoopback()
  val release: List[String] = newList()
  val server = background({ -> stallUntilReleased(l, release) })
  val conn = connectTo(l)
  val outcome: List[String] = newList()
  val writer = background({ -> writeUntilFailure(conn, outcome) })
  Time.sleepMillis(1000)
  assertEqualInt(outcome.count, 0, "the write is blocked on the full socket buffers")
  val started = Time.monotonicNanos()
  hostShutdown(conn)
  val _ = await Task.awaitAll(writer)
  val elapsedMs = (Time.monotonicNanos() - started) / 1000000i64
  assertEqualInt(outcome.count, 1, "the blocked write returned")
  assertTrue(outcome[0].startsWith("error:"), "the interrupted write is an error: " + outcome[0])
  assertTrue(elapsedMs < 3000i64, "the write ended promptly after the shutdown: " + elapsedMs.toString() + " ms")
  hostClose(conn)
  release.add("go")
  val _2 = await Task.awaitAll(server)
  hostStopListener(l)
}

test "hostSetIoTimeout ends a write on a peer that accepts no data" {
  val l = listenLoopback()
  val release: List[String] = newList()
  val server = background({ -> stallUntilReleased(l, release) })
  val conn = connectTo(l)
  hostSetIoTimeout(conn, 400)
  val outcome: List[String] = newList()
  val started = Time.monotonicNanos()
  writeUntilFailure(conn, outcome)
  val elapsedMs = (Time.monotonicNanos() - started) / 1000000i64
  assertEqualInt(outcome.count, 1, "the write returned")
  assertTrue(outcome[0].startsWith("error:"), "the stalled write failed: " + outcome[0])
  assertTrue(elapsedMs >= 300i64, "the write waited for the limit: " + elapsedMs.toString() + " ms")
  assertTrue(
    elapsedMs < 10000i64,
    "the write ended at the limit, not at the peer's close: " + elapsedMs.toString() + " ms"
  )
  hostClose(conn)
  release.add("go")
  val _ = await Task.awaitAll(server)
  hostStopListener(l)
}

test "a write timeout does not end a write the peer keeps accepting" {
  val l = listenLoopback()
  val server = background({ -> echoUntilEof(l) })
  val conn = connectTo(l)
  hostSetIoTimeout(conn, 1000)
  val payload = repeat("0123456789abcdef", 65536)
  val received: List[String] = newList()
  val reader = background({ -> received.add(readExactly(conn, payload.length)) })
  match hostWrite(conn, encodeUtf8(payload)) {
    case Ok(_) -> ()
    case Err(e) -> panic("a write to a draining peer failed: " + TcpError.message(e))
  }
  val _ = await Task.awaitAll(reader)
  assertEqualInt(received.count, 1, "the echo was read")
  assertTrue(received[0] == payload, "the 1 MiB payload round-tripped under a write timeout")
  hostClose(conn)
  val _2 = await Task.awaitAll(server)
  hostStopListener(l)
}

test "a read returns at most maxBytes and the rest stays readable" {
  val l = listenLoopback()
  val server = background({ -> echoUntilEof(l) })
  val conn = connectTo(l)
  match hostWrite(conn, encodeUtf8("0123456789")) {
    case Ok(_) -> ()
    case Err(e) -> panic("write failed: " + TcpError.message(e))
  }
  Time.sleepMillis(300)
  val first = match hostRead(conn, 3) {
    case Ok(chunk) -> chunk
    case Err(e) -> panic("read failed: " + TcpError.message(e))
  }
  assertTrue(first.length >= 1 and first.length <= 3, "a read of at most 3 bytes returned " + first.length.toString())
  val head = match tryDecodeUtf8(first) { case Some(t) -> t; case None -> panic("not UTF-8") }
  assertEqual(head + readExactly(conn, 10 - first.length), "0123456789", "no byte is lost between reads")
  hostClose(conn)
  val _ = await Task.awaitAll(server)
  hostStopListener(l)
}

test "three thousand small messages echo in order" {
  val l = listenLoopback()
  val server = background({ -> echoUntilEof(l) })
  val conn = connectTo(l)
  var i = 0
  while i < 3000 {
    val text = "m" + i.toString()
    match hostWrite(conn, encodeUtf8(text)) {
      case Ok(_) -> ()
      case Err(e) -> panic("write " + i.toString() + " failed: " + TcpError.message(e))
    }
    assertEqual(readExactly(conn, text.length), text, "message " + i.toString() + " echoed")
    i = i + 1
  }
  hostClose(conn)
  val _ = await Task.awaitAll(server)
  hostStopListener(l)
}

test "a four megabyte payload round-trips intact while both sides stream" {
  val l = listenLoopback()
  val server = background({ -> echoUntilEof(l) })
  val conn = connectTo(l)
  val payload = repeat("0123456789abcdef", 262144)
  val writeOutcome: List[String] = newList()
  val writer = background(
    { ->
      match hostWrite(conn, encodeUtf8(payload)) {
        case Ok(_) -> writeOutcome.add("ok")
        case Err(e) -> writeOutcome.add("error:" + TcpError.message(e))
      }
    }
  )
  val echoed = readExactly(conn, payload.length)
  val _ = await Task.awaitAll(writer)
  assertEqualInt(writeOutcome.count, 1, "the writer finished")
  assertEqual(writeOutcome[0], "ok", "the large write succeeded")
  assertTrue(echoed == payload, "the 4 MiB echoed bytes equal the sent bytes")
  hostClose(conn)
  val _2 = await Task.awaitAll(server)
  hostStopListener(l)
}

// All the connections are dialled from the test thread before any server task
// runs (a dotnet connect completes on a pool thread, and the pool's few
// threads are all about to block in `hostAccept`/`hostRead`), then one thread
// drives them in lock step, so the server side serves them concurrently.
test "four concurrent connections each get their own bytes back" {
  val l = listenLoopback()
  val conns: List[Conn] = newList()
  var i = 0
  while i < 4 {
    conns.add(connectTo(l))
    i = i + 1
  }
  val servers: List[Task.Scope] = newList()
  i = 0
  while i < 4 {
    servers.add(background({ -> echoUntilEof(l) }))
    i = i + 1
  }
  val payloads: List[String] = newList()
  i = 0
  while i < 4 {
    val payload = repeat("c" + i.toString() + ";", 20000)
    payloads.add(payload)
    match hostWrite(conns[i], encodeUtf8(payload)) {
      case Ok(_) -> ()
      case Err(e) -> panic("write to connection " + i.toString() + " failed: " + TcpError.message(e))
    }
    i = i + 1
  }
  i = 0
  while i < 4 {
    assertTrue(
      readExactly(conns[i], payloads[i].length) == payloads[i],
      "connection " + i.toString() + " read back exactly its own payload"
    )
    i = i + 1
  }
  i = 0
  while i < 4 {
    hostClose(conns[i])
    i = i + 1
  }
  i = 0
  while i < 4 {
    val _ = await Task.awaitAll(servers[i])
    i = i + 1
  }
  hostStopListener(l)
}
