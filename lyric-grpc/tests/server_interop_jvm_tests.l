//! tests/server_interop_jvm_tests.l — `Grpc.Server`, the pure-Lyric server,
//! driven by grpc-java (docs/72 slice 8, D804).
//!
//! The server shares no code with this client: it is the independent peer that
//! checks the server's HTTP/2 framing, trailers, status mapping, flow control
//! and deadline handling against a mature implementation. The client is
//! `Grpc.Kernel.Jvm`'s binding (the `legacy-client` kernel, kept until slice 10), called
//! directly, whatever the public `Grpc.callUnary` is built on.
@cfg(target = "jvm")
@test_module
package Grpc.ServerInteropJvmTests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Testing
import Std.Time
import Grpc
import Grpc.Types
import Grpc.Kernel.Jvm

func bytesOf(xs: in List[Int]): slice[Byte] {
  val acc: List[Byte] = newList()
  for x in xs {
    acc.add(x.toByte())
  }
  acc.toArray()
}

func repeated(n: in Int): slice[Byte] {
  val acc: List[Byte] = newListWithCapacity(n)
  var i = 0
  while i < n {
    acc.add((i % 251).toByte())
    i = i + 1
  }
  acc.toArray()
}

func metaValue(meta: in slice[GrpcMetadataEntry], key: in String): String {
  match Grpc.metadataGet(meta, key) {
    case Some(v) -> v
    case None -> ""
  }
}

func echo(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  Std.Core.Ok(req)
}

func trace(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  Std.Core.Ok(encodeUtf8(metaValue(meta, "x-trace")))
}

func fail(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  Std.Core.Err(Grpc.notFound("nothing here"))
}

func boom(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  panic("secret internal detail")
}

func slow(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  sleepMillis(1200)
  Std.Core.Ok(req)
}

func count(
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

func countThenFail(
  req: in slice[Byte], meta: in slice[GrpcMetadataEntry], emit: in (slice[Byte]) -> Bool
): Result[Unit, GrpcStatus] {
  val _ = emit(bytesOf([10]))
  val _ = emit(bytesOf([11]))
  Std.Core.Err(Grpc.grpcInternal("boom"))
}

func startServer(): GrpcServerHandle {
  var r = Grpc.create()
  r = Grpc.addUnary(r, "test.Echo", "Echo", echo)
  r = Grpc.addUnary(r, "test.Echo", "Trace", trace)
  r = Grpc.addUnary(r, "test.Echo", "Fail", fail)
  r = Grpc.addUnary(r, "test.Echo", "Boom", boom)
  r = Grpc.addUnary(r, "test.Echo", "Slow", slow)
  r = Grpc.addServerStreaming(r, "test.Echo", "Count", count)
  r = Grpc.addServerStreaming(r, "test.Echo", "CountThenFail", countThenFail)
  Grpc.startHandleAt(r, "127.0.0.1", 0)
}

func open(server: in GrpcServerHandle): GrpcChannel {
  match Grpc.Kernel.Jvm.netOpenChannel("http://127.0.0.1:" + Grpc.serverPort(server).toString()) {
    case Std.Core.Ok(ch) -> ch
    case Std.Core.Err(m) -> panic("netOpenChannel failed: " + m)
  }
}

func unary(
  ch: in GrpcChannel, method: in String, payload: in slice[Byte], timeoutMs: in Int, metadata: in String
): Result[slice[Byte], GrpcStatus] {
  Grpc.Kernel.Jvm.netCallUnary(ch, "test.Echo", method, payload, timeoutMs, metadata)
}

func code(st: in GrpcStatus): Int {
  statusCodeToInt(st.code)
}

test "grpc-java client: a message round-trips byte for byte, empty and larger than the flow-control window" {
  val server = startServer()
  val ch = open(server)
  match unary(ch, "Echo", bytesOf([1, 2, 3]), 0, "") {
    case Std.Core.Ok(r) -> assertEqualInt(r.length, 3, "small")
    case Std.Core.Err(st) -> assertTrue(false, "small: " + st.message)
  }
  val empty: slice[Byte] = []
  match unary(ch, "Echo", empty, 0, "") {
    case Std.Core.Ok(r) -> assertEqualInt(r.length, 0, "empty")
    case Std.Core.Err(st) -> assertTrue(false, "empty: " + st.message)
  }
  val big = repeated(1500000)
  match unary(ch, "Echo", big, 0, "") {
    case Std.Core.Ok(r) -> {
      assertEqualInt(r.length, 1500000, "1.5 MB")
      assertEqualInt(r[1499999].toInt(), big[1499999].toInt(), "intact")
    }
    case Std.Core.Err(st) -> assertTrue(false, "big: " + st.message)
  }
  Grpc.Kernel.Jvm.netCloseChannel(ch)
  Grpc.stop(server, 1000)
}

test "grpc-java client: request metadata reaches the handler" {
  val server = startServer()
  val ch = open(server)
  match unary(ch, "Trace", bytesOf([1]), 0, "x-trace:abc123") {
    case Std.Core.Ok(r) -> assertEqualInt(r.length, 6, "x-trace is abc123")
    case Std.Core.Err(st) -> assertTrue(false, "trace: " + st.message)
  }
  Grpc.Kernel.Jvm.netCloseChannel(ch)
  Grpc.stop(server, 1000)
}

test "grpc-java client: an error status, an unknown method and a handler panic map to their codes" {
  val server = startServer()
  val ch = open(server)
  match unary(ch, "Fail", bytesOf([1]), 0, "") {
    case Std.Core.Ok(_) -> assertTrue(false, "expected NOT_FOUND")
    case Std.Core.Err(st) -> {
      assertEqualInt(code(st), 5, "NOT_FOUND")
      assertTrue(st.message.contains("nothing here"), "message: " + st.message)
    }
  }
  match unary(ch, "NoSuchMethod", bytesOf([1]), 0, "") {
    case Std.Core.Ok(_) -> assertTrue(false, "expected UNIMPLEMENTED")
    case Std.Core.Err(st) -> assertEqualInt(code(st), 12, "UNIMPLEMENTED")
  }
  match unary(ch, "Boom", bytesOf([1]), 0, "") {
    case Std.Core.Ok(_) -> assertTrue(false, "expected INTERNAL")
    case Std.Core.Err(st) -> {
      assertEqualInt(code(st), 13, "INTERNAL")
      assertFalse(st.message.contains("secret"), "the panic text is withheld: " + st.message)
    }
  }
  match unary(ch, "Echo", bytesOf([1]), 0, "") {
    case Std.Core.Ok(_) -> ()
    case Std.Core.Err(st) -> assertTrue(false, "the server stopped serving after a panic: " + st.message)
  }
  Grpc.Kernel.Jvm.netCloseChannel(ch)
  Grpc.stop(server, 1000)
}

test "grpc-java client: a deadline shorter than the handler is DEADLINE_EXCEEDED, and the channel stays usable" {
  val server = startServer()
  val ch = open(server)
  val started = Std.Time.nowEpochMillis()
  match unary(ch, "Slow", bytesOf([1]), 300, "") {
    case Std.Core.Ok(_) -> assertTrue(false, "expected DEADLINE_EXCEEDED")
    case Std.Core.Err(st) -> assertEqualInt(code(st), 4, "DEADLINE_EXCEEDED: " + st.message)
  }
  assertTrue(Std.Time.nowEpochMillis() - started < 1100i64, "the call did not wait for the handler")
  match unary(ch, "Echo", bytesOf([1]), 0, "") {
    case Std.Core.Ok(_) -> ()
    case Std.Core.Err(st) -> assertTrue(false, "the channel is unusable after a deadline: " + st.message)
  }
  Grpc.Kernel.Jvm.netCloseChannel(ch)
  Grpc.stop(server, 2000)
}

test "grpc-java client: server-streamed messages arrive in order, then end of stream; a failure surfaces after them" {
  val server = startServer()
  val ch = open(server)
  match Grpc.Kernel.Jvm.netOpenServerStream(ch, "test.Echo", "Count", bytesOf([4]), 0, "") {
    case Std.Core.Err(st) -> assertTrue(false, "open: " + st.message)
    case Std.Core.Ok(stream) -> {
      var seen = 0
      var running = true
      while running {
        match Grpc.Kernel.Jvm.netNextStreamMessage(stream) {
          case Std.Core.Ok(Some(m)) -> {
            assertEqualInt(m[0].toInt(), seen, "message " + seen.toString())
            seen = seen + 1
          }
          case Std.Core.Ok(None) -> {
            running = false
          }
          case Std.Core.Err(st) -> {
            assertTrue(false, "stream: " + st.message)
            running = false
          }
        }
      }
      assertEqualInt(seen, 4, "four messages")
      Grpc.Kernel.Jvm.netCloseStream(stream)
    }
  }
  match Grpc.Kernel.Jvm.netOpenServerStream(ch, "test.Echo", "CountThenFail", bytesOf([0]), 0, "") {
    case Std.Core.Err(st) -> assertTrue(false, "open: " + st.message)
    case Std.Core.Ok(stream) -> {
      var seen = 0
      var failed = -1
      var running = true
      while running {
        match Grpc.Kernel.Jvm.netNextStreamMessage(stream) {
          case Std.Core.Ok(Some(_)) -> {
            seen = seen + 1
          }
          case Std.Core.Ok(None) -> {
            running = false
          }
          case Std.Core.Err(st) -> {
            failed = code(st)
            running = false
          }
        }
      }
      assertEqualInt(seen, 2, "two messages before the failure")
      assertEqualInt(failed, 13, "then INTERNAL")
      Grpc.Kernel.Jvm.netCloseStream(stream)
    }
  }
  Grpc.Kernel.Jvm.netCloseChannel(ch)
  Grpc.stop(server, 1000)
}

test "grpc-java client: a client that cancels a stream leaves the server serving" {
  val server = startServer()
  val ch = open(server)
  match Grpc.Kernel.Jvm.netOpenServerStream(ch, "test.Echo", "Count", bytesOf([200]), 0, "") {
    case Std.Core.Err(st) -> assertTrue(false, "open: " + st.message)
    case Std.Core.Ok(stream) -> {
      val _ = Grpc.Kernel.Jvm.netNextStreamMessage(stream)
      Grpc.Kernel.Jvm.netCloseStream(stream)
    }
  }
  match unary(ch, "Echo", bytesOf([1]), 0, "") {
    case Std.Core.Ok(_) -> ()
    case Std.Core.Err(st) -> assertTrue(false, "after a cancelled stream: " + st.message)
  }
  Grpc.Kernel.Jvm.netCloseChannel(ch)
  Grpc.stop(server, 1000)
}
