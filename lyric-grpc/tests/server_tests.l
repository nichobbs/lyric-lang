//! tests/server_tests.l — `Grpc.startHandleAt` / `stop` against the library's
//! own client, on both targets (#8642, D287).
//!
//! Every test registers real handlers, starts a server on an ephemeral
//! loopback port, and calls it through `Grpc.callUnary` / `Grpc.openServerStream`.
//! The client under test is the platform's own gRPC stack (`Grpc.Net.Client` on
//! dotnet, grpc-java on the JVM), so this also checks the server against an
//! implementation it does not share code with on dotnet, where the server is
//! pure Lyric over `Std.HttpEngine.H2Conn`.
@test_module
package Grpc.ServerTests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Testing
import Std.Time
import Grpc
import Grpc.Types

func bytesOf(xs: in List[Int]): slice[Byte] {
  val acc: List[Byte] = newList()
  for x in xs {
    acc.add(x.toByte())
  }
  acc.toArray()
}

func metaValue(meta: in slice[GrpcMetadataEntry], key: in String): String {
  match Grpc.metadataGet(meta, key) {
    case Some(v) -> v
    case None -> ""
  }
}

func echoHandler(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  Std.Core.Ok(req)
}

func traceHandler(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  Std.Core.Ok(encodeUtf8(metaValue(meta, "x-trace")))
}

func failHandler(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  Std.Core.Err(Grpc.notFound("nothing here: é%"))
}

func panicHandler(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  panic("handler bug that must not reach the client")
}

func slowHandler(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  sleepMillis(1200)
  Std.Core.Ok(req)
}

func countHandler(
  req: in slice[Byte], meta: in slice[GrpcMetadataEntry], emit: in (slice[Byte]) -> Bool
): Result[Unit, GrpcStatus] {
  val n = req[0].toInt()
  var i = 0
  while i < n {
    if not emit(bytesOf([i])) {
      return Std.Core.Ok(())
    }
    i = i + 1
  }
  Std.Core.Ok(())
}

func countThenFailHandler(
  req: in slice[Byte], meta: in slice[GrpcMetadataEntry], emit: in (slice[Byte]) -> Bool
): Result[Unit, GrpcStatus] {
  val _ = emit(bytesOf([10]))
  val _ = emit(bytesOf([11]))
  Std.Core.Err(Grpc.grpcInternal("boom"))
}

func bigHandler(
  req: in slice[Byte], meta: in slice[GrpcMetadataEntry], emit: in (slice[Byte]) -> Bool
): Result[Unit, GrpcStatus] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < 300000 {
    acc.add((i % 251).toByte())
    i = i + 1
  }
  val _ = emit(acc.toArray())
  Std.Core.Ok(())
}

func buildRegistry(): ServiceRegistry {
  var r = Grpc.create()
  r = Grpc.addUnary(r, "test.Echo", "Echo", echoHandler)
  r = Grpc.addUnary(r, "test.Echo", "Trace", traceHandler)
  r = Grpc.addUnary(r, "test.Echo", "Fail", failHandler)
  r = Grpc.addUnary(r, "test.Echo", "Panic", panicHandler)
  r = Grpc.addUnary(r, "test.Echo", "Slow", slowHandler)
  r = Grpc.addServerStreaming(r, "test.Echo", "Count", countHandler)
  r = Grpc.addServerStreaming(r, "test.Echo", "CountThenFail", countThenFailHandler)
  r = Grpc.addServerStreaming(r, "test.Echo", "Big", bigHandler)
  r = Grpc.addUnary(r, "test.Other", "Echo", echoHandler)
  r
}

func startServer(): GrpcServerHandle {
  Grpc.startHandleAt(buildRegistry(), "127.0.0.1", 0)
}

func openTo(handle: in GrpcServerHandle): GrpcChannel {
  match Grpc.openChannel("http://127.0.0.1:" + Grpc.serverPort(handle).toString()) {
    case Std.Core.Ok(ch) -> ch
    case Std.Core.Err(m) -> panic("openChannel failed: " + m)
  }
}

test "startHandleAt binds an ephemeral port that serverPort reports" {
  val server = startServer()
  assertTrue(Grpc.serverPort(server) > 0, "a real port was assigned")
  Grpc.stop(server, 1000)
}

test "unary: a request message is echoed back byte for byte" {
  val server = startServer()
  val ch = openTo(server)
  match Grpc.callUnary(ch, "test.Echo", "Echo", bytesOf([0, 1, 2, 250, 255, 7]), Grpc.defaultOptions()) {
    case Std.Core.Ok(resp) -> {
      assertEqualInt(resp.length, 6, "response length")
      assertEqualInt(resp[3].toInt(), 250, "byte 3 (high bit set)")
      assertEqualInt(resp[4].toInt(), 255, "byte 4")
    }
    case Std.Core.Err(st) -> panic("unary failed: " + st.message)
  }
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

test "unary: an empty message and a large message (flow control) round-trip" {
  val server = startServer()
  val ch = openTo(server)
  val empty: slice[Byte] = []
  match Grpc.callUnary(ch, "test.Echo", "Echo", empty, Grpc.defaultOptions()) {
    case Std.Core.Ok(resp) -> assertEqualInt(resp.length, 0, "empty response")
    case Std.Core.Err(st) -> panic("empty unary failed: " + st.message)
  }
  val big: List[Byte] = newList()
  var i = 0
  while i < 200000 {
    big.add((i % 253).toByte())
    i = i + 1
  }
  match Grpc.callUnary(ch, "test.Echo", "Echo", big.toArray(), Grpc.defaultOptions()) {
    case Std.Core.Ok(resp) -> {
      assertEqualInt(resp.length, 200000, "the whole message came back")
      assertEqualInt(resp[199999].toInt(), 199999 % 253, "and its last byte is intact")
    }
    case Std.Core.Err(st) -> panic("large unary failed: " + st.message)
  }
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

test "unary: request metadata reaches the handler" {
  val server = startServer()
  val ch = openTo(server)
  val opts = Grpc.withMetadata(Grpc.defaultOptions(), "x-trace", "req-42")
  val empty: slice[Byte] = []
  match Grpc.callUnary(ch, "test.Echo", "Trace", empty, opts) {
    case Std.Core.Ok(resp) -> {
      match tryDecodeUtf8(resp) {
        case Some(s) -> assertEqual(s, "req-42", "the handler saw the x-trace header")
        case None -> panic("response was not UTF-8")
      }
    }
    case Std.Core.Err(st) -> panic("unary failed: " + st.message)
  }
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

test "unary: a handler's error status reaches the client with its code and message" {
  val server = startServer()
  val ch = openTo(server)
  val empty: slice[Byte] = []
  match Grpc.callUnary(ch, "test.Echo", "Fail", empty, Grpc.defaultOptions()) {
    case Std.Core.Ok(_) -> panic("expected NOT_FOUND")
    case Std.Core.Err(st) -> {
      assertTrue(st.code == GrpcStatusCode.NotFound, "code is NotFound")
      assertEqual(st.message, "nothing here: é%", "non-ASCII and % survive the grpc-message encoding")
    }
  }
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

test "unary: a panicking handler fails its call with Internal and the server keeps serving" {
  val server = startServer()
  val ch = openTo(server)
  val empty: slice[Byte] = []
  match Grpc.callUnary(ch, "test.Echo", "Panic", empty, Grpc.defaultOptions()) {
    case Std.Core.Ok(_) -> panic("expected INTERNAL")
    case Std.Core.Err(st) -> {
      assertTrue(st.code == GrpcStatusCode.Internal, "code is Internal")
      assertFalse(st.message.contains("must not reach"), "the panic text is not leaked to the client")
    }
  }
  match Grpc.callUnary(ch, "test.Echo", "Echo", bytesOf([5]), Grpc.defaultOptions()) {
    case Std.Core.Ok(resp) -> assertEqualInt(resp.length, 1, "the next call is served")
    case Std.Core.Err(st) -> panic("server stopped serving after a handler panic: " + st.message)
  }
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

test "unary: an unknown method is UNIMPLEMENTED, and routes are per service" {
  val server = startServer()
  val ch = openTo(server)
  val empty: slice[Byte] = []
  match Grpc.callUnary(ch, "test.Echo", "NoSuchMethod", empty, Grpc.defaultOptions()) {
    case Std.Core.Ok(_) -> panic("expected UNIMPLEMENTED")
    case Std.Core.Err(st) -> assertTrue(st.code == GrpcStatusCode.Unimplemented, "unknown method")
  }
  match Grpc.callUnary(ch, "test.Nope", "Echo", empty, Grpc.defaultOptions()) {
    case Std.Core.Ok(_) -> panic("expected UNIMPLEMENTED")
    case Std.Core.Err(st) -> assertTrue(st.code == GrpcStatusCode.Unimplemented, "unknown service")
  }
  match Grpc.callUnary(ch, "test.Other", "Echo", bytesOf([9]), Grpc.defaultOptions()) {
    case Std.Core.Ok(resp) -> assertEqualInt(resp[0].toInt(), 9, "a second service on the same server")
    case Std.Core.Err(st) -> panic("second service failed: " + st.message)
  }
  match Grpc.callUnary(ch, "test.Echo", "Slow", empty, Grpc.withTimeout(Grpc.defaultOptions(), 300)) {
    case Std.Core.Ok(_) -> panic("expected the client deadline to expire")
    case Std.Core.Err(st) -> assertTrue(
      st.code == GrpcStatusCode.DeadlineExceeded,
      "a slow handler hits the client's deadline"
    )
  }
  Grpc.closeChannel(ch)
  Grpc.stop(server, 3000)
}

test "streaming: handler messages arrive in order, then end of stream" {
  val server = startServer()
  val ch = openTo(server)
  match Grpc.openServerStream(ch, "test.Echo", "Count", bytesOf([4]), Grpc.defaultOptions()) {
    case Std.Core.Err(st) -> panic("open failed: " + st.message)
    case Std.Core.Ok(stream) -> {
      var seen = 0
      var reading = true
      while reading {
        match Grpc.nextMessage(stream) {
          case Std.Core.Err(st) -> panic("read failed: " + st.message)
          case Std.Core.Ok(Some(msg)) -> {
            assertEqualInt(msg[0].toInt(), seen, "messages are in handler order")
            seen = seen + 1
          }
          case Std.Core.Ok(None) -> {
            reading = false
          }
        }
      }
      assertEqualInt(seen, 4, "four messages before the end")
      Grpc.closeStream(stream)
    }
  }
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

test "streaming: a handler error after some messages surfaces from nextMessage" {
  val server = startServer()
  val ch = openTo(server)
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
          assertEqual(st.message, "boom", "message from the handler's status")
        }
        case _ -> panic("expected the INTERNAL status")
      }
      Grpc.closeStream(stream)
    }
  }
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

test "streaming: a message larger than the HTTP/2 window is delivered whole" {
  val server = startServer()
  val ch = openTo(server)
  val empty: slice[Byte] = []
  match Grpc.openServerStream(ch, "test.Echo", "Big", empty, Grpc.defaultOptions()) {
    case Std.Core.Err(st) -> panic("open failed: " + st.message)
    case Std.Core.Ok(stream) -> {
      match Grpc.nextMessage(stream) {
        case Std.Core.Ok(Some(m)) -> {
          assertEqualInt(m.length, 300000, "all 300000 bytes")
          assertEqualInt(m[299999].toInt(), 299999 % 251, "last byte intact")
        }
        case Std.Core.Ok(None) -> panic("stream ended without the message")
        case Std.Core.Err(st) -> panic("read failed: " + st.message)
      }
      Grpc.closeStream(stream)
    }
  }
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

test "stop: calls after a stop are UNAVAILABLE, and a second stop is a no-op" {
  val server = startServer()
  val ch = openTo(server)
  match Grpc.callUnary(ch, "test.Echo", "Echo", bytesOf([1]), Grpc.defaultOptions()) {
    case Std.Core.Ok(_) -> ()
    case Std.Core.Err(st) -> panic("call before stop failed: " + st.message)
  }
  Grpc.stop(server, 1000)
  Grpc.stop(server, 1000)
  match Grpc.callUnary(ch, "test.Echo", "Echo", bytesOf([1]), Grpc.defaultOptions()) {
    case Std.Core.Ok(_) -> panic("expected the stopped server to refuse the call")
    case Std.Core.Err(st) -> assertTrue(st.code == GrpcStatusCode.Unavailable, "code is Unavailable")
  }
  Grpc.closeChannel(ch)
}

test "startHandleAt: an address that is already bound panics rather than returning a dead handle" {
  val first = startServer()
  var raised = false
  try {
    val second = Grpc.startHandleAt(buildRegistry(), "127.0.0.1", Grpc.serverPort(first))
    Grpc.stop(second, 100)
  } catch Bug as _ {
    raised = true
  }
  assertTrue(raised, "binding a taken port is reported")
  Grpc.stop(first, 1000)
}

test "addUnary: registering the same method twice violates its contract" {
  var raised = false
  try {
    var r = Grpc.create()
    r = Grpc.addUnary(r, "test.Echo", "Echo", echoHandler)
    r = Grpc.addUnary(r, "test.Echo", "Echo", echoHandler)
  } catch Bug as _ {
    raised = true
  }
  assertTrue(raised, "a duplicate route is refused")
}
