//! Std.TcpHost's bounded operations on `--target native` (#9090): a connect,
//! a client TLS handshake, a read and a write each take an absolute deadline
//! on the clock of `Std.Time.monotonicNanos()` and a wake pipe, and report
//! which of them ended the operation as a `BoundedError` case, never as a
//! message to compare.
//!
//!   lyric test --target native lyric-stdlib/tests/tcp_host_bounded_native_tests.l
@test_module
package Std.TcpHost.BoundedNativeTests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.String as Str
import Std.Task as Task
import Std.TcpHost
import Std.Testing
import Std.Time as Time
import Std.Tls as Tls

func listenLoopback(): Listener {
  match hostListen("127.0.0.1", 0) {
    case Ok(l) -> l
    case Err(e) -> panic(TcpError.message(e))
  }
}

func closeListener(l: in Listener): Unit {
  hostStopListener(l)
  hostCloseListener(l)
}

func deadlineIn(ms: in Int): Long {
  Time.monotonicNanos() + ms.toLong() * 1000000i64
}

func elapsedMsSince(started: in Long): Long {
  (Time.monotonicNanos() - started) / 1000000i64
}

// A connected pair over loopback: (client end, accepted end).
record Pair {
  client: Conn
  server: Conn
}

func connectedPair(l: in Listener): Pair {
  val client = match hostConnectBounded("127.0.0.1", hostLocalPort(l), deadlineIn(5000), 0 - 1) {
    case Ok(c) -> c
    case Err(e) -> panic(BoundedError.message(e))
  }
  val server = match hostAccept(l) { case Ok(c) -> c; case Err(e) -> panic(TcpError.message(e)) }
  Pair(client = client, server = server)
}

func outcomeName[T](r: in Result[T, BoundedError]): String {
  match r {
    case Ok(_) -> "Ok"
    case Err(e) -> match e {
      case BoundDeadlinePassed -> "BoundDeadlinePassed"
      case BoundInterrupted -> "BoundInterrupted"
      case BoundFailed(error) -> "BoundFailed: " + TcpError.message(error)
    }
  }
}

test "hostConnectBounded connects by address and by name, and the connection carries data" {
  val l = listenLoopback()
  val pair = connectedPair(l)
  assertTrue(
    isOk(hostWriteBounded(pair.client, encodeUtf8("ping"), deadlineIn(5000), 0 - 1)),
    "write within the deadline"
  )
  match hostReadBounded(pair.server, 16, deadlineIn(5000), 0 - 1) {
    case Ok(bytes) -> assertEqualInt(bytes.length, 4, "the four bytes arrive")
    case Err(e) -> assertTrue(false, BoundedError.message(e))
  }
  hostClose(pair.client)
  hostClose(pair.server)
  match hostConnectBounded("localhost", hostLocalPort(l), deadlineIn(5000), 0 - 1) {
    case Ok(c) -> hostClose(c)
    case Err(e) -> assertTrue(false, "localhost resolves and connects: " + BoundedError.message(e))
  }
  closeListener(l)
}

test "a refused connect is BoundFailed, a passed deadline is BoundDeadlinePassed" {
  val l = listenLoopback()
  val port = hostLocalPort(l)
  closeListener(l)
  val refused = hostConnectBounded("127.0.0.1", port, deadlineIn(5000), 0 - 1)
  assertTrue(Str.startsWith(outcomeName(refused), "BoundFailed"), "refused: " + outcomeName(refused))
  val late = hostConnectBounded("localhost", port, Time.monotonicNanos() - 1i64, 0 - 1)
  assertEqual(outcomeName(late), "BoundDeadlinePassed", "a deadline in the past")
}

test "hostReadBounded ends at its deadline on a silent peer, and not before" {
  val l = listenLoopback()
  val pair = connectedPair(l)
  val deadline = deadlineIn(300)
  val started = Time.monotonicNanos()
  val r = hostReadBounded(pair.server, 16, deadline, 0 - 1)
  assertEqual(outcomeName(r), "BoundDeadlinePassed", "the read's outcome")
  assertTrue(Time.monotonicNanos() >= deadline, "the clock has reached the deadline")
  assertTrue(elapsedMsSince(started) < 3000i64, "and the read did not wait much longer")
  hostClose(pair.client)
  hostClose(pair.server)
  closeListener(l)
}

test "a wake pipe signalled from another thread interrupts a bounded read" {
  val l = listenLoopback()
  val pair = connectedPair(l)
  val pipe = match hostWakePipeNew() { case Ok(p) -> p; case Err(e) -> panic(TcpError.message(e)) }
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, { -> Time.sleepMillis(200); hostWakePipeSignal(pipe) })
  val started = Time.monotonicNanos()
  val r = hostReadBounded(pair.server, 16, deadlineIn(10000), hostWakePipeReadFd(pipe))
  assertEqual(outcomeName(r), "BoundInterrupted", "the read's outcome")
  assertTrue(elapsedMsSince(started) < 3000i64, "it ended when signalled, not at the deadline")
  val _ = Task.awaitAll(sc)
  // The pipe stays signalled: every later operation that watches it stops too.
  assertEqual(
    outcomeName(hostReadBounded(pair.server, 16, 0i64, hostWakePipeReadFd(pipe))),
    "BoundInterrupted",
    "a second read"
  )
  hostWakePipeClose(pipe)
  hostClose(pair.client)
  hostClose(pair.server)
  closeListener(l)
}

test "hostReadBounded returns an empty slice at the end of the stream" {
  val l = listenLoopback()
  val pair = connectedPair(l)
  hostClose(pair.client)
  match hostReadBounded(pair.server, 16, deadlineIn(5000), 0 - 1) {
    case Ok(bytes) -> assertEqualInt(bytes.length, 0, "end of stream")
    case Err(e) -> assertTrue(false, BoundedError.message(e))
  }
  hostClose(pair.server)
  closeListener(l)
}

test "hostWriteBounded ends at its deadline when the peer stops reading" {
  val l = listenLoopback()
  val pair = connectedPair(l)
  val chunk: List[Byte] = newList()
  var i = 0
  while i < 1048576 {
    chunk.add(120.toByte())
    i = i + 1
  }
  val block = chunk.toArray()
  val deadline = deadlineIn(500)
  var outcome = "Ok"
  var writes = 0
  // The socket buffers take a few megabytes; then the write has to wait.
  while outcome == "Ok" and writes < 256 {
    outcome = outcomeName(hostWriteBounded(pair.client, block, deadline, 0 - 1))
    writes = writes + 1
  }
  assertEqual(outcome, "BoundDeadlinePassed", "the write that could not finish")
  assertTrue(Time.monotonicNanos() >= deadline, "the clock has reached the deadline")
  hostClose(pair.client)
  hostClose(pair.server)
  closeListener(l)
}

test "hostUpgradeClientTlsBounded ends at its deadline when the peer never answers the ClientHello" {
  val l = listenLoopback()
  val pair = connectedPair(l)
  val deadline = deadlineIn(300)
  val started = Time.monotonicNanos()
  val r = hostUpgradeClientTlsBounded(
    pair.client,
    "localhost",
    TlsTrustSystemDefault,
    None,
    Tls.TlsVersion.Tls12,
    "",
    deadline,
    0 - 1
  )
  assertEqual(outcomeName(r), "BoundDeadlinePassed", "the handshake's outcome")
  assertTrue(Time.monotonicNanos() >= deadline, "the clock has reached the deadline")
  assertTrue(elapsedMsSince(started) < 3000i64, "and the handshake did not wait much longer")
  // The failed upgrade closed the client socket: the server end sees the end of the stream.
  match hostRead(pair.server, 4096) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  hostClose(pair.server)
  closeListener(l)
}
