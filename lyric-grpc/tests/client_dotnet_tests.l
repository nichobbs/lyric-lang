//! tests/client_dotnet_tests.l — the gRPC client against a real server on
//! `--target dotnet` (#6592, #5409).
//!
//! Every test drives the public `Grpc.*` client API (`Grpc.Kernel.Net`'s
//! `Grpc.Net.Client` binding) over a loopback h2c connection to an in-process
//! gRPC server written here in pure Lyric on the stdlib's sans-IO HTTP/2
//! engine (`Std.HttpEngine.H2Conn`) and `Std.TcpHost`. The server is a test
//! peer, not a library feature: it speaks just enough of the gRPC wire format
//! (5-byte length-prefixed messages, `grpc-status`/`grpc-message` trailers) to
//! answer the methods below, so the client under test is the real
//! `Grpc.Net.Client` stack with no mock. Declaring `Task` externs in a test
//! file follows `tcp_host_tls_tests.l`: a documented test-only exception to
//! the `_kernel/`-only extern rule for driving the opposite side of a real
//! protocol.
//!
//! Methods of service `test.Echo`:
//!   Echo           unary, replies with the request message
//!   Trace          unary, replies with the request's `x-trace` metadata value
//!   Fail           unary, answers NOT_FOUND "nothing here"
//!   Slow           unary, replies after 1500 ms (deadline test)
//!   Count          server streaming, request byte n -> messages [0]..[n-1]
//!   CountThenFail  server streaming, two messages then INTERNAL "boom"
//!   (anything else)  UNIMPLEMENTED
@cfg(target = "dotnet")
@test_module
package Grpc.ClientDotnetTests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Testing
import Std.TcpHost
import Std.HttpEngine
import Std.HttpEngine.H2Conn as H2
import Grpc
import Grpc.Types

extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@externStatic
@externTarget("System.Threading.Thread.Sleep")
func sleepMs(ms: in Int): Unit = ()

// ─── gRPC wire framing ───────────────────────────────────────────────────────
func frameMessage(msg: in slice[Byte]): slice[Byte] {
  val acc: List[Byte] = newList()
  acc.add(0.toByte())
  acc.add(msg.length.shr(24).and(255).toByte())
  acc.add(msg.length.shr(16).and(255).toByte())
  acc.add(msg.length.shr(8).and(255).toByte())
  acc.add(msg.length.and(255).toByte())
  for b in msg {
    acc.add(b)
  }
  acc.toArray()
}

/// The payload of the first length-prefixed message in `body`.
func firstMessage(body: in slice[Byte]): slice[Byte] {
  val none: slice[Byte] = []
  if body.length < 5 {
    return none
  }
  val len = body[1].toInt().shl(24).or(body[2].toInt().shl(16)).or(body[3].toInt().shl(8)).or(body[4].toInt())
  if body.length < 5 + len {
    return none
  }
  body.slice(5, 5 + len)
}

// ─── Test server ─────────────────────────────────────────────────────────────
ref record Req {
  var path: String
  var trace: String
  var body: List[Byte]
}

func headerValue(headers: in List[HeaderField], name: in String): String {
  for h in headers {
    if h.name == name {
      return h.value
    }
  }
  ""
}

func writeOut(conn: in Conn, bytes: in slice[Byte]): Unit {
  if bytes.length > 0 {
    val _ = hostWrite(conn, bytes)
  }
}

func okHeaders(): List[HeaderField] {
  val hs: List[HeaderField] = newList()
  hs.add(HeaderField(name = ":status", value = "200"))
  hs.add(HeaderField(name = "content-type", value = "application/grpc"))
  hs
}

func sendInitial(conn: in Conn, h2: in H2.H2Connection, sid: in Int): Unit {
  match H2.encodeResponseHeaders(h2, sid, okHeaders(), false) {
    case Std.Core.Ok(bytes) -> writeOut(conn, bytes)
    case Std.Core.Err(_) -> ()
  }
}

func sendMessage(conn: in Conn, h2: in H2.H2Connection, sid: in Int, payload: in slice[Byte]): Unit {
  match H2.sendData(h2, sid, frameMessage(payload), false) {
    case Std.Core.Ok(bytes) -> writeOut(conn, bytes)
    case Std.Core.Err(_) -> ()
  }
}

func statusTrailers(code: in Int, message: in String): List[HeaderField] {
  val hs: List[HeaderField] = newList()
  hs.add(HeaderField(name = "grpc-status", value = code.toString()))
  if message.length > 0 {
    hs.add(HeaderField(name = "grpc-message", value = message))
  }
  hs
}

func sendTrailers(conn: in Conn, h2: in H2.H2Connection, sid: in Int, code: in Int, message: in String): Unit {
  match H2.encodeResponseTrailers(h2, sid, statusTrailers(code, message)) {
    case Std.Core.Ok(bytes) -> writeOut(conn, bytes)
    case Std.Core.Err(_) -> ()
  }
}

/// A trailers-only response: one HEADERS block carrying the status.
func sendTrailersOnly(conn: in Conn, h2: in H2.H2Connection, sid: in Int, code: in Int, message: in String): Unit {
  val hs = okHeaders()
  for t in statusTrailers(code, message) {
    hs.add(t)
  }
  match H2.encodeResponseHeaders(h2, sid, hs, true) {
    case Std.Core.Ok(bytes) -> writeOut(conn, bytes)
    case Std.Core.Err(_) -> ()
  }
}

func respondUnary(conn: in Conn, h2: in H2.H2Connection, sid: in Int, payload: in slice[Byte]): Unit {
  sendInitial(conn, h2, sid)
  sendMessage(conn, h2, sid, payload)
  sendTrailers(conn, h2, sid, 0, "")
}

func respond(conn: in Conn, h2: in H2.H2Connection, sid: in Int, req: in Req): Unit {
  val body = req.body.toArray()
  match req.path {
    case "/test.Echo/Echo" -> respondUnary(conn, h2, sid, firstMessage(body))
    case "/test.Echo/Trace" -> respondUnary(conn, h2, sid, encodeUtf8(req.trace))
    case "/test.Echo/Fail" -> sendTrailersOnly(conn, h2, sid, 5, "nothing here")
    case "/test.Echo/Slow" -> {
      sleepMs(1500)
      respondUnary(conn, h2, sid, firstMessage(body))
    }
    case "/test.Echo/Count" -> {
      val n = firstMessage(body)[0].toInt()
      sendInitial(conn, h2, sid)
      var i = 0
      while i < n {
        val one: slice[Byte] = [i.toByte()]
        sendMessage(conn, h2, sid, one)
        i = i + 1
      }
      sendTrailers(conn, h2, sid, 0, "")
    }
    case "/test.Echo/CountThenFail" -> {
      sendInitial(conn, h2, sid)
      val a: slice[Byte] = [10.toByte()]
      val b: slice[Byte] = [11.toByte()]
      sendMessage(conn, h2, sid, a)
      sendMessage(conn, h2, sid, b)
      sendTrailers(conn, h2, sid, 13, "boom")
    }
    case _ -> sendTrailersOnly(conn, h2, sid, 12, "unknown method")
  }
}

func onEvent(conn: in Conn, h2: in H2.H2Connection, reqs: in Map[Int, Req], ev: in H2.H2Event): Unit {
  match ev {
    case H2.H2RequestHeaders(sid, headers, endStream) -> {
      val req = Req(path = headerValue(headers, ":path"), trace = headerValue(headers, "x-trace"), body = newList())
      reqs.add(sid, req)
      if endStream {
        respond(conn, h2, sid, req)
      }
    }
    case H2.H2RequestData(sid, data, endStream, _) -> {
      match mapGet(reqs, sid) {
        case Some(req) -> {
          for b in data {
            req.body.add(b)
          }
          if endStream {
            respond(conn, h2, sid, req)
          }
        }
        case None -> ()
      }
    }
    case _ -> ()
  }
}

func serveConnection(conn: in Conn): Unit {
  val h2 = H2.newServerConnection(H2.h2DefaultServerSettings())
  writeOut(conn, H2.serverInitialFrame(h2))
  val reqs: Map[Int, Req] = newMap()
  var open = true
  while open and not H2.isFailed(h2) {
    match hostRead(conn, 65536) {
      case Std.Core.Err(_) -> {
        open = false
      }
      case Std.Core.Ok(bytes) -> {
        if bytes.length == 0 {
          open = false
        } else {
          val r = H2.feed(h2, bytes)
          writeOut(conn, r.outbound)
          for ev in r.events {
            onEvent(conn, h2, reqs, ev)
          }
        }
      }
    }
  }
  hostClose(conn)
}

func acceptLoop(listener: in Listener): Unit {
  var running = true
  while running {
    match hostAccept(listener) {
      case Std.Core.Err(_) -> {
        running = false
      }
      case Std.Core.Ok(conn) -> {
        val _ = taskRun({ -> serveConnection(conn) })
      }
    }
  }
}

/// Listen on an ephemeral loopback port; `hostLocalPort` reports which.
func startServer(): Listener {
  match hostListen("127.0.0.1", 0) {
    case Std.Core.Ok(l) -> {
      val _ = taskRun({ -> acceptLoop(l) })
      l
    }
    case Std.Core.Err(e) -> panic("test server could not listen: " + TcpError.message(e))
  }
}

/// A port nothing listens on: bind an ephemeral port, then release it.
func unusedPort(): Int {
  match hostListen("127.0.0.1", 0) {
    case Std.Core.Ok(l) -> {
      val port = hostLocalPort(l)
      hostStopListener(l)
      port
    }
    case Std.Core.Err(e) -> panic("could not reserve a port: " + TcpError.message(e))
  }
}

func openOrFail(port: in Int): GrpcChannel {
  match Grpc.openChannel("http://127.0.0.1:" + port.toString()) {
    case Std.Core.Ok(ch) -> ch
    case Std.Core.Err(m) -> panic("openChannel failed: " + m)
  }
}

func bytesOf(xs: in List[Int]): slice[Byte] {
  val acc: List[Byte] = newList()
  for x in xs {
    acc.add(x.toByte())
  }
  acc.toArray()
}

// ─── Unary ───────────────────────────────────────────────────────────────────
test "callUnary: a request message is echoed back byte for byte" {
  val server = startServer()
  val ch = openOrFail(hostLocalPort(server))
  val payload = bytesOf([0, 1, 2, 250, 255, 7])
  match Grpc.callUnary(ch, "test.Echo", "Echo", payload, Grpc.defaultOptions()) {
    case Std.Core.Ok(resp) -> {
      assertEqualInt(resp.length, 6, "response length")
      assertEqualInt(resp[0].toInt(), 0, "byte 0")
      assertEqualInt(resp[3].toInt(), 250, "byte 3 (high bit set)")
      assertEqualInt(resp[4].toInt(), 255, "byte 4")
    }
    case Std.Core.Err(st) -> panic("unary failed: " + st.message)
  }
  Grpc.closeChannel(ch)
  hostStopListener(server)
}

test "callUnary: an empty request message round-trips" {
  val server = startServer()
  val ch = openOrFail(hostLocalPort(server))
  val empty: slice[Byte] = []
  match Grpc.callUnary(ch, "test.Echo", "Echo", empty, Grpc.defaultOptions()) {
    case Std.Core.Ok(resp) -> assertEqualInt(resp.length, 0, "empty response")
    case Std.Core.Err(st) -> panic("unary failed: " + st.message)
  }
  Grpc.closeChannel(ch)
  hostStopListener(server)
}

test "callUnary: call metadata reaches the server as request headers" {
  val server = startServer()
  val ch = openOrFail(hostLocalPort(server))
  val opts = Grpc.withMetadata(Grpc.defaultOptions(), "x-trace", "req-42")
  val empty: slice[Byte] = []
  match Grpc.callUnary(ch, "test.Echo", "Trace", empty, opts) {
    case Std.Core.Ok(resp) -> {
      match tryDecodeUtf8(resp) {
        case Some(s) -> assertEqual(s, "req-42", "server saw the x-trace header")
        case None -> panic("response was not UTF-8")
      }
    }
    case Std.Core.Err(st) -> panic("unary failed: " + st.message)
  }
  Grpc.closeChannel(ch)
  hostStopListener(server)
}

test "callUnary: a server error status maps to its GrpcStatusCode and message" {
  val server = startServer()
  val ch = openOrFail(hostLocalPort(server))
  val empty: slice[Byte] = []
  match Grpc.callUnary(ch, "test.Echo", "Fail", empty, Grpc.defaultOptions()) {
    case Std.Core.Ok(_) -> panic("expected the NOT_FOUND status")
    case Std.Core.Err(st) -> {
      assertTrue(st.code == GrpcStatusCode.NotFound, "code is NotFound")
      assertEqual(st.message, "nothing here", "message from grpc-message")
    }
  }
  Grpc.closeChannel(ch)
  hostStopListener(server)
}

test "callUnary: an unknown method is UNIMPLEMENTED" {
  val server = startServer()
  val ch = openOrFail(hostLocalPort(server))
  val empty: slice[Byte] = []
  match Grpc.callUnary(ch, "test.Echo", "NoSuchMethod", empty, Grpc.defaultOptions()) {
    case Std.Core.Ok(_) -> panic("expected UNIMPLEMENTED")
    case Std.Core.Err(st) -> assertTrue(st.code == GrpcStatusCode.Unimplemented, "code is Unimplemented")
  }
  Grpc.closeChannel(ch)
  hostStopListener(server)
}

test "callUnary: a deadline shorter than the server's reply is DEADLINE_EXCEEDED" {
  val server = startServer()
  val ch = openOrFail(hostLocalPort(server))
  val opts = Grpc.withTimeout(Grpc.defaultOptions(), 300)
  val empty: slice[Byte] = []
  match Grpc.callUnary(ch, "test.Echo", "Slow", empty, opts) {
    case Std.Core.Ok(_) -> panic("expected the deadline to expire")
    case Std.Core.Err(st) -> assertTrue(st.code == GrpcStatusCode.DeadlineExceeded, "code is DeadlineExceeded")
  }
  Grpc.closeChannel(ch)
  hostStopListener(server)
}

test "callUnary: no server listening is UNAVAILABLE" {
  val ch = openOrFail(unusedPort())
  val empty: slice[Byte] = []
  match Grpc.callUnary(ch, "test.Echo", "Echo", empty, Grpc.defaultOptions()) {
    case Std.Core.Ok(_) -> panic("expected UNAVAILABLE")
    case Std.Core.Err(st) -> assertTrue(st.code == GrpcStatusCode.Unavailable, "code is Unavailable")
  }
  Grpc.closeChannel(ch)
}

test "callUnary: a call on a closed channel is FAILED_PRECONDITION, not a crash" {
  val ch = openOrFail(unusedPort())
  Grpc.closeChannel(ch)
  val empty: slice[Byte] = []
  match Grpc.callUnary(ch, "test.Echo", "Echo", empty, Grpc.defaultOptions()) {
    case Std.Core.Ok(_) -> panic("expected an error on a closed channel")
    case Std.Core.Err(st) -> assertTrue(st.code == GrpcStatusCode.FailedPrecondition, "code is FailedPrecondition")
  }
}

// ─── Server streaming ────────────────────────────────────────────────────────
test "openServerStream: messages arrive in order, then end of stream" {
  val server = startServer()
  val ch = openOrFail(hostLocalPort(server))
  match Grpc.openServerStream(ch, "test.Echo", "Count", bytesOf([3]), Grpc.defaultOptions()) {
    case Std.Core.Err(st) -> panic("open failed: " + st.message)
    case Std.Core.Ok(stream) -> {
      var seen = 0
      var reading = true
      while reading {
        match Grpc.nextMessage(stream) {
          case Std.Core.Err(st) -> panic("read failed: " + st.message)
          case Std.Core.Ok(Some(msg)) -> {
            assertEqualInt(msg.length, 1, "one byte per message")
            assertEqualInt(msg[0].toInt(), seen, "messages are in server order")
            seen = seen + 1
          }
          case Std.Core.Ok(None) -> {
            reading = false
          }
        }
      }
      assertEqualInt(seen, 3, "three messages before the end")
      Grpc.closeStream(stream)
    }
  }
  Grpc.closeChannel(ch)
  hostStopListener(server)
}

test "openServerStream: a failure after some messages surfaces as Err from nextMessage" {
  val server = startServer()
  val ch = openOrFail(hostLocalPort(server))
  val empty: slice[Byte] = []
  match Grpc.openServerStream(ch, "test.Echo", "CountThenFail", empty, Grpc.defaultOptions()) {
    case Std.Core.Err(st) -> panic("open failed: " + st.message)
    case Std.Core.Ok(stream) -> {
      match Grpc.nextMessage(stream) {
        case Std.Core.Ok(Some(m)) -> assertEqualInt(m[0].toInt(), 10, "first message")
        case _ -> panic("expected the first message")
      }
      match Grpc.nextMessage(stream) {
        case Std.Core.Ok(Some(m)) -> assertEqualInt(m[0].toInt(), 11, "second message")
        case _ -> panic("expected the second message")
      }
      match Grpc.nextMessage(stream) {
        case Std.Core.Err(st) -> {
          assertTrue(st.code == GrpcStatusCode.Internal, "code is Internal")
          assertEqual(st.message, "boom", "message from grpc-message")
        }
        case _ -> panic("expected the INTERNAL status")
      }
      Grpc.closeStream(stream)
    }
  }
  Grpc.closeChannel(ch)
  hostStopListener(server)
}

test "closeStream: closing early cancels the call, a second close and later reads are safe" {
  val server = startServer()
  val ch = openOrFail(hostLocalPort(server))
  match Grpc.openServerStream(ch, "test.Echo", "Count", bytesOf([200]), Grpc.defaultOptions()) {
    case Std.Core.Err(st) -> panic("open failed: " + st.message)
    case Std.Core.Ok(stream) -> {
      match Grpc.nextMessage(stream) {
        case Std.Core.Ok(Some(_)) -> ()
        case _ -> panic("expected a first message")
      }
      Grpc.closeStream(stream)
      Grpc.closeStream(stream)
      match Grpc.nextMessage(stream) {
        case Std.Core.Ok(None) -> assertTrue(true, "a closed stream reads as end of stream")
        case _ -> panic("expected end of stream after close")
      }
    }
  }
  Grpc.closeChannel(ch)
  hostStopListener(server)
}

test "openServerStream: no server listening is UNAVAILABLE on the first read" {
  val ch = openOrFail(unusedPort())
  val empty: slice[Byte] = []
  match Grpc.openServerStream(ch, "test.Echo", "Count", empty, Grpc.defaultOptions()) {
    case Std.Core.Err(st) -> assertTrue(st.code == GrpcStatusCode.Unavailable, "open reported Unavailable")
    case Std.Core.Ok(stream) -> {
      match Grpc.nextMessage(stream) {
        case Std.Core.Err(st) -> assertTrue(st.code == GrpcStatusCode.Unavailable, "read reported Unavailable")
        case _ -> panic("expected UNAVAILABLE")
      }
      Grpc.closeStream(stream)
    }
  }
  Grpc.closeChannel(ch)
}
