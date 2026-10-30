//! tests/client_jvm_tests.l — the gRPC client against a real server on
//! `--target jvm` (#8527, #5409).
//!
//! The JVM twin of `client_dotnet_tests.l`: every test drives the public
//! `Grpc.*` client API (`Grpc.Kernel.Jvm`'s grpc-java binding) over loopback
//! to an in-process grpc-java `Server` built here from the same grpc-java
//! classes the client uses, with a pass-through marshaller so the wire bytes
//! are exactly what the test sends. Declaring `extern`s in a test file follows
//! `jvm_server_smoke.l`: a documented test-only exception to the
//! `_kernel/`-only extern rule for driving the opposite side of a real
//! protocol.
//!
//! Methods of service `test.Echo` (the same table as the dotnet suite):
//!   Echo           unary, replies with the request message
//!   Trace          unary, replies with the request's `x-trace` metadata value
//!   Fail           unary, answers NOT_FOUND "nothing here"
//!   Slow           unary, replies after 1500 ms (deadline test)
//!   Count          server streaming, request byte n -> messages [0]..[n-1]
//!   CountThenFail  server streaming, two messages then INTERNAL "boom"
//!   (anything else)  UNIMPLEMENTED (grpc-java's own answer for an unknown method)
@cfg(target = "jvm")
@test_module
package Grpc.ClientJvmTests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Testing
import Grpc
import Grpc.Types

extern type JInputStream = "java.io.InputStream"

extern type JByteArrayInputStream = "java.io.ByteArrayInputStream"

extern type JObject = "java.lang.Object"

extern type JList = "java.util.List"

extern type JCollections = "java.util.Collections"

extern type JServer = "io.grpc.Server"

extern type JServerBuilder = "io.grpc.ServerBuilder"

extern type JServerServiceDefinition = "io.grpc.ServerServiceDefinition"

extern type JServiceBuilder = "io.grpc.ServerServiceDefinition$Builder"

extern type JServerCallHandler = "io.grpc.ServerCallHandler"

extern type JServerCalls = "io.grpc.stub.ServerCalls"

extern type JUnaryMethod = "io.grpc.stub.ServerCalls$UnaryMethod"

extern type JServerStreamingMethod = "io.grpc.stub.ServerCalls$ServerStreamingMethod"

extern type JStreamObserver = "io.grpc.stub.StreamObserver"

extern type JMethodDescriptor = "io.grpc.MethodDescriptor"

extern type JMethodDescriptorBuilder = "io.grpc.MethodDescriptor$Builder"

extern type JMarshaller = "io.grpc.MethodDescriptor$Marshaller"

extern type JMethodType = "io.grpc.MethodDescriptor$MethodType"

extern type JStatus = "io.grpc.Status"

extern type JStatusException = "io.grpc.StatusRuntimeException"

extern type JMetadata = "io.grpc.Metadata"

extern type JMetadataKey = "io.grpc.Metadata$Key"

extern type JServerInterceptor = "io.grpc.ServerInterceptor"

extern type JServerInterceptors = "io.grpc.ServerInterceptors"

extern type JServerCall = "io.grpc.ServerCall"

extern type JServerCallListener = "io.grpc.ServerCall$Listener"

@externStatic
@externTarget("java.lang.Thread.sleep")
func sleepMs(ms: in Long): Unit = ()

// ─── Pass-through marshaller (message type = the serialized stream) ──────────
func bytesToStream(bytes: in slice[Byte]): JInputStream {
  JByteArrayInputStream.new(bytes)
}

func streamToBytes(stream: in JInputStream): slice[Byte] {
  stream.readAllBytes()
}

func drainToStream(stream: in JInputStream): JInputStream {
  JByteArrayInputStream.new(stream.readAllBytes())
}

record StreamMarshaller {
  tag: Int
}

impl JMarshaller for StreamMarshaller {
  func stream(value: in JInputStream): JInputStream {
    value
  }

  func parse(stream: in JInputStream): JInputStream {
    drainToStream(stream)
  }
}

@externStatic
@externTarget("io.grpc.MethodDescriptor.newBuilder")
func methodDescriptorBuilder(req: in JMarshaller, resp: in JMarshaller): JMethodDescriptorBuilder = ()

func buildMethod(method: in String, kind: in JMethodType): JMethodDescriptor {
  val marshaller: JMarshaller = StreamMarshaller(tag = 0)
  val b = methodDescriptorBuilder(marshaller, marshaller)
  val _ = b.setType(kind)
  val _ = b.setFullMethodName(JMethodDescriptor.generateFullMethodName("test.Echo", method))
  b.build()
}

// ─── Handlers ────────────────────────────────────────────────────────────────
ref record TraceBox {
  var value: String
}

val traceBox: TraceBox = TraceBox(value = "")

func replyOnce(observer: in JStreamObserver, payload: in slice[Byte]): Unit {
  observer.onNext(bytesToStream(payload))
  observer.onCompleted()
}

func failWith(observer: in JStreamObserver, status: in JStatus, description: in String): Unit {
  observer.onError(status.withDescription(description).asRuntimeException())
}

record EchoHandler {
  tag: Int
}

impl JUnaryMethod for EchoHandler {
  func invoke(request: in JInputStream, observer: in JStreamObserver): Unit {
    replyOnce(observer, streamToBytes(request))
  }
}

record TraceHandler {
  tag: Int
}

impl JUnaryMethod for TraceHandler {
  func invoke(request: in JInputStream, observer: in JStreamObserver): Unit {
    replyOnce(observer, encodeUtf8(traceValue()))
  }
}

func traceValue(): String {
  traceBox.value
}

record FailHandler {
  tag: Int
}

impl JUnaryMethod for FailHandler {
  func invoke(request: in JInputStream, observer: in JStreamObserver): Unit {
    failWith(observer, JStatus.NOT_FOUND, "nothing here")
  }
}

record SlowHandler {
  tag: Int
}

impl JUnaryMethod for SlowHandler {
  func invoke(request: in JInputStream, observer: in JStreamObserver): Unit {
    sleepMs(1500i64)
    replyOnce(observer, streamToBytes(request))
  }
}

func countMessages(request: in JInputStream, observer: in JStreamObserver): Unit {
  val n = streamToBytes(request)[0].toInt()
  var i = 0
  while i < n {
    val one: slice[Byte] = [i.toByte()]
    observer.onNext(bytesToStream(one))
    i = i + 1
  }
  observer.onCompleted()
}

record CountHandler {
  tag: Int
}

impl JServerStreamingMethod for CountHandler {
  func invoke(request: in JInputStream, observer: in JStreamObserver): Unit {
    countMessages(request, observer)
  }
}

func countThenFail(observer: in JStreamObserver): Unit {
  val a: slice[Byte] = [10.toByte()]
  val b: slice[Byte] = [11.toByte()]
  observer.onNext(bytesToStream(a))
  observer.onNext(bytesToStream(b))
  failWith(observer, JStatus.INTERNAL, "boom")
}

record CountThenFailHandler {
  tag: Int
}

impl JServerStreamingMethod for CountThenFailHandler {
  func invoke(request: in JInputStream, observer: in JStreamObserver): Unit {
    countThenFail(observer)
  }
}

// ─── Metadata capture ────────────────────────────────────────────────────────
func recordTrace(headers: in JMetadata): Unit {
  val key = JMetadataKey.of("x-trace", JMetadata.ASCII_STRING_MARSHALLER)
  if headers.containsKey(key) {
    val value: JObject = headers.get(key)
    traceBox.value = value.toString()
  }
}

record TraceCapture {
  tag: Int
}

impl JServerInterceptor for TraceCapture {
  func interceptCall(call: in JServerCall, headers: in JMetadata, next: in JServerCallHandler): JServerCallListener {
    recordTrace(headers)
    next.startCall(call, headers)
  }
}

// ─── Server assembly ─────────────────────────────────────────────────────────
@externStatic
@externTarget("io.grpc.stub.ServerCalls.asyncUnaryCall")
func unaryHandler(m: in JUnaryMethod): JServerCallHandler = ()

@externStatic
@externTarget("io.grpc.stub.ServerCalls.asyncServerStreamingCall")
func streamingHandler(m: in JServerStreamingMethod): JServerCallHandler = ()

func unary(b: in JServiceBuilder, name: in String, m: in JUnaryMethod): Unit {
  val _ = b.addMethod(buildMethod(name, JMethodType.UNARY), unaryHandler(m))
}

func streaming(b: in JServiceBuilder, name: in String, m: in JServerStreamingMethod): Unit {
  val _ = b.addMethod(buildMethod(name, JMethodType.SERVER_STREAMING), streamingHandler(m))
}

func buildService(): JServerServiceDefinition {
  val b = JServerServiceDefinition.builder("test.Echo")
  val echo: JUnaryMethod = EchoHandler(tag = 0)
  val trace: JUnaryMethod = TraceHandler(tag = 0)
  val fail: JUnaryMethod = FailHandler(tag = 0)
  val slow: JUnaryMethod = SlowHandler(tag = 0)
  val count: JServerStreamingMethod = CountHandler(tag = 0)
  val countFail: JServerStreamingMethod = CountThenFailHandler(tag = 0)
  unary(b, "Echo", echo)
  unary(b, "Trace", trace)
  unary(b, "Fail", fail)
  unary(b, "Slow", slow)
  streaming(b, "Count", count)
  streaming(b, "CountThenFail", countFail)
  b.build()
}

@externStatic
@externTarget("io.grpc.ServerInterceptors.intercept")
func interceptService(s: in JServerServiceDefinition, interceptors: in JList): JServerServiceDefinition = ()

func startServer(): JServer {
  val capture: JServerInterceptor = TraceCapture(tag = 0)
  val server = JServerBuilder.forPort(0).addService(interceptService(buildService(), JCollections.singletonList(capture))).build()
  val _ = server.start()
  server
}

func stopServer(server: in JServer): Unit {
  val _ = server.shutdownNow()
}

func openOrFail(server: in JServer): GrpcChannel {
  match Grpc.openChannel("http://127.0.0.1:" + server.getPort().toString()) {
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
  val ch = openOrFail(server)
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
  stopServer(server)
}

test "callUnary: an empty request message round-trips" {
  val server = startServer()
  val ch = openOrFail(server)
  val empty: slice[Byte] = []
  match Grpc.callUnary(ch, "test.Echo", "Echo", empty, Grpc.defaultOptions()) {
    case Std.Core.Ok(resp) -> assertEqualInt(resp.length, 0, "empty response")
    case Std.Core.Err(st) -> panic("unary failed: " + st.message)
  }
  Grpc.closeChannel(ch)
  stopServer(server)
}

test "callUnary: call metadata reaches the server as request headers" {
  val server = startServer()
  val ch = openOrFail(server)
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
  stopServer(server)
}

test "callUnary: a server error status maps to its GrpcStatusCode and message" {
  val server = startServer()
  val ch = openOrFail(server)
  val empty: slice[Byte] = []
  match Grpc.callUnary(ch, "test.Echo", "Fail", empty, Grpc.defaultOptions()) {
    case Std.Core.Ok(_) -> panic("expected the NOT_FOUND status")
    case Std.Core.Err(st) -> {
      assertTrue(st.code == GrpcStatusCode.NotFound, "code is NotFound")
      assertEqual(st.message, "nothing here", "message from the status description")
    }
  }
  Grpc.closeChannel(ch)
  stopServer(server)
}

test "callUnary: an unknown method is UNIMPLEMENTED" {
  val server = startServer()
  val ch = openOrFail(server)
  val empty: slice[Byte] = []
  match Grpc.callUnary(ch, "test.Echo", "NoSuchMethod", empty, Grpc.defaultOptions()) {
    case Std.Core.Ok(_) -> panic("expected UNIMPLEMENTED")
    case Std.Core.Err(st) -> assertTrue(st.code == GrpcStatusCode.Unimplemented, "code is Unimplemented")
  }
  Grpc.closeChannel(ch)
  stopServer(server)
}

test "callUnary: a deadline shorter than the server's reply is DEADLINE_EXCEEDED" {
  val server = startServer()
  val ch = openOrFail(server)
  val opts = Grpc.withTimeout(Grpc.defaultOptions(), 300)
  val empty: slice[Byte] = []
  match Grpc.callUnary(ch, "test.Echo", "Slow", empty, opts) {
    case Std.Core.Ok(_) -> panic("expected the deadline to expire")
    case Std.Core.Err(st) -> assertTrue(st.code == GrpcStatusCode.DeadlineExceeded, "code is DeadlineExceeded")
  }
  Grpc.closeChannel(ch)
  stopServer(server)
}

test "callUnary: no server listening is UNAVAILABLE" {
  match Grpc.openChannel("http://127.0.0.1:1") {
    case Std.Core.Err(m) -> panic("openChannel failed: " + m)
    case Std.Core.Ok(ch) -> {
      val empty: slice[Byte] = []
      match Grpc.callUnary(ch, "test.Echo", "Echo", empty, Grpc.defaultOptions()) {
        case Std.Core.Ok(_) -> panic("expected UNAVAILABLE")
        case Std.Core.Err(st) -> assertTrue(st.code == GrpcStatusCode.Unavailable, "code is Unavailable")
      }
      Grpc.closeChannel(ch)
    }
  }
}

test "callUnary: a call on a closed channel is FAILED_PRECONDITION, not a crash" {
  match Grpc.openChannel("http://127.0.0.1:1") {
    case Std.Core.Err(m) -> panic("openChannel failed: " + m)
    case Std.Core.Ok(ch) -> {
      Grpc.closeChannel(ch)
      val empty: slice[Byte] = []
      match Grpc.callUnary(ch, "test.Echo", "Echo", empty, Grpc.defaultOptions()) {
        case Std.Core.Ok(_) -> panic("expected an error on a closed channel")
        case Std.Core.Err(st) -> assertTrue(st.code == GrpcStatusCode.FailedPrecondition, "code is FailedPrecondition")
      }
    }
  }
}

// ─── Server streaming ────────────────────────────────────────────────────────
test "openServerStream: messages arrive in order, then end of stream" {
  val server = startServer()
  val ch = openOrFail(server)
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
  stopServer(server)
}

test "openServerStream: a failure after some messages surfaces as Err from nextMessage" {
  val server = startServer()
  val ch = openOrFail(server)
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
          assertEqual(st.message, "boom", "message from the status description")
        }
        case _ -> panic("expected the INTERNAL status")
      }
      Grpc.closeStream(stream)
    }
  }
  Grpc.closeChannel(ch)
  stopServer(server)
}

test "closeStream: closing early cancels the call, a second close and later reads are safe" {
  val server = startServer()
  val ch = openOrFail(server)
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
  stopServer(server)
}

test "openServerStream: no server listening is UNAVAILABLE on the first read" {
  match Grpc.openChannel("http://127.0.0.1:1") {
    case Std.Core.Err(m) -> panic("openChannel failed: " + m)
    case Std.Core.Ok(ch) -> {
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
  }
}
