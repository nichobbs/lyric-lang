//! Grpc.Kernel.Jvm — JVM extern boundary for the gRPC client (grpc-java).
//!
//! Mirrors `Grpc.Kernel.Net`: a pass-through `byte[]` marshaller over
//! `io.grpc.MethodDescriptor`, `io.grpc.stub.ClientCalls` for unary and
//! server-streaming calls, and an `io.grpc.ManagedChannel` registry keyed by
//! the `Int` handle the platform-neutral `GrpcChannel` wraps. Every binding is
//! an `extern type` plus JVM auto-FFI (descriptors resolved from the grpc-java
//! JARs at compile time); there is no `extern package` block here — that form
//! has no lowering on any target (decision D281).
//!
//! Server hosting (`serve` / `netStartHandle` / `netStopHandle`) is a grpc-java
//! `Server` whose routes are `impl`s of `ServerCalls.UnaryMethod` /
//! `ServerStreamingMethod` over the same pass-through marshaller; request
//! metadata reaches handlers through a gRPC `Context` value (D284).
//! `checkRateLimit` is the pure-Lyric token bucket from `Lyric.Resilience`
//! (the same algorithm `Web.Kernel.Runtime` uses on this target).
//!
//! Only active when compiled with feature = "jvm".
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "jvm")
@io
package Grpc.Kernel.Jvm

import Grpc.Types
import Std.Core
import Std.Collections
import Std.String as Str
import Std.Time
import Std.Encoding
import Resilience

// ─── Opaque JVM types ─────────────────────────────────────────────────────────
extern type JObject = "java.lang.Object"

extern type JInputStream = "java.io.InputStream"

extern type JManagedChannel = "io.grpc.ManagedChannel"

extern type JManagedChannelBuilder = "io.grpc.ManagedChannelBuilder"

extern type JMethodDescriptor = "io.grpc.MethodDescriptor"

extern type JMethodDescriptorBuilder = "io.grpc.MethodDescriptor$Builder"

extern type JMarshaller = "io.grpc.MethodDescriptor$Marshaller"

extern type JMethodType = "io.grpc.MethodDescriptor$MethodType"

extern type JClientCalls = "io.grpc.stub.ClientCalls"

extern type JClientCall = "io.grpc.ClientCall"

extern type JCallOptions = "io.grpc.CallOptions"

extern type JTimeUnit = "java.util.concurrent.TimeUnit"

extern type JIterator = "java.util.Iterator"

extern type JMetadata = "io.grpc.Metadata"

extern type JMetadataKey = "io.grpc.Metadata$Key"

extern type JClientInterceptor = "io.grpc.ClientInterceptor"

extern type JMetadataUtils = "io.grpc.stub.MetadataUtils"

extern type JChannel = "io.grpc.Channel"

extern type JList = "java.util.List"

extern type JThrowable = "java.lang.Throwable"

extern type JCollections = "java.util.Collections"

// ─── Pass-through marshaller ─────────────────────────────────────────────────
// `MethodDescriptor.Marshaller<InputStream>`: the message type is the
// serialized stream itself, so the marshaller moves no bytes. The library
// hands callers raw protobuf bytes (compose with `lyric-proto`); the
// bytes-to-stream and stream-to-bytes conversions happen in ordinary
// functions below, because an `impl` method whose own parameter is a
// `slice[Byte]` is lowered against the real `byte[]` while the rest of the
// backend treats a slice as `Object[]`. `Marshaller<T>` erases `T` to
// `Object`, so these methods rely on the synthetic bridge the JVM backend
// emits for an extern-interface impl.
extern type JByteArrayInputStream = "java.io.ByteArrayInputStream"

func bytesToStream(bytes: in slice[Byte]): JInputStream {
  JByteArrayInputStream.new(bytes)
}

func streamToBytes(stream: in JInputStream): slice[Byte] {
  stream.readAllBytes()
}

/// A response stream is only valid while `parse` runs, so it is drained into
/// a fresh stream the caller reads afterwards.
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

// ─── Registries ───────────────────────────────────────────────────────────────
// `JvmConcurrentDict`, not `ConcurrentDict`: this file and `net/grpc_kernel.l`
// are alternative sources for one package, and a same-named `extern type`
// bound to different host classes in each leaks across (#5443).
extern type JvmConcurrentDict[K, V] = "java.util.concurrent.ConcurrentHashMap"

@externTarget("java.util.concurrent.ConcurrentHashMap.<init>")
func newConcurrentDict[K, V](): JvmConcurrentDict[K, V] = ()

func cdTryGetValue[K, V](dict: in JvmConcurrentDict[K, V], key: in K, value: out V): Bool {
  value = dict.get(key)
  dict.containsKey(key)
}

func cdPut[K, V](dict: in JvmConcurrentDict[K, V], key: in K, value: in V): Unit {
  val _ = dict.put(key, value)
}

/// Claim and remove `key`'s entry. `ConcurrentHashMap.remove` returns null for
/// a missing key and Lyric has no null test for an extern value, so the
/// membership check and the removal share one lock: of two threads closing the
/// same handle, exactly one claims the entry.
func cdRemove[K, V](dict: in JvmConcurrentDict[K, V], key: in K, value: out V): Bool {
  registryLock.lock()
  defer {
    registryLock.unlock()
  }
  if dict.containsKey(key) {
    value = dict.remove(key)
    true
  } else {
    false
  }
}

extern type JLock = "java.util.concurrent.locks.ReentrantLock"

@externTarget("java.util.concurrent.locks.ReentrantLock.<init>")
func newLock(): JLock = ()

val registryLock: JLock = newLock()

extern type JAtomicInteger = "java.util.concurrent.atomic.AtomicInteger"

val handleCounter: JAtomicInteger = JAtomicInteger.new(0)

func nextHandleId(): Int {
  handleCounter.incrementAndGet()
}

val channelRegistry: JvmConcurrentDict[String, JManagedChannel] = newConcurrentDict[String, JManagedChannel]()

/// A live server-streaming call: the `ClientCall` (to cancel it) and the
/// blocking iterator over its responses.
ref record StreamState {
  call: JClientCall
  responses: JIterator
}

val streamRegistry: JvmConcurrentDict[String, StreamState] = newConcurrentDict[String, StreamState]()

// ─── Client: channel lifecycle ────────────────────────────────────────────────
@externStatic
@externTarget("io.grpc.ManagedChannelBuilder.forTarget")
func channelBuilderForTarget(target: in String): JManagedChannelBuilder = ()

/// Open a channel to `address` (`http://host:port` = plaintext,
/// `https://host:port` = TLS). Like `GrpcChannel.ForAddress` on .NET this is
/// lazy: the connection is made by the first RPC, so only a malformed address
/// fails here.
pub func netOpenChannel(address: in String): Result[GrpcChannel, String] {
  match Types.parseAddress(address) {
    case Err(msg) -> Err(msg)
    case Ok(parsed) -> {
      try {
        val builder = channelBuilderForTarget(parsed.authority)
        if not parsed.secure {
          val _ = builder.usePlaintext()
        }
        val ch = builder.build()
        val id = nextHandleId()
        cdPut(channelRegistry, id.toString(), ch)
        Std.Core.Ok(Types.wrapChannelHandle(id))
      } catch Bug as b {
        Err(b.message)
      }
    }
  }
}

/// Shut the channel down. A double close, or a handle from another run, is a
/// no-op (the registry lookup misses).
pub func netCloseChannel(channel: in GrpcChannel): Unit {
  var ch: JManagedChannel = default()
  if cdRemove(channelRegistry, Types.channelHandleId(channel).toString(), ch) {
    val _ = ch.shutdownNow()
  }
}

func tryLookupChannel(channel: in GrpcChannel, ch: out JManagedChannel): Bool {
  cdTryGetValue(channelRegistry, Types.channelHandleId(channel).toString(), ch)
}

// ─── Call plumbing ────────────────────────────────────────────────────────────
@externStatic
@externTarget("io.grpc.MethodDescriptor.newBuilder")
func methodDescriptorBuilder(req: in JMarshaller, resp: in JMarshaller): JMethodDescriptorBuilder = ()

@externStatic
@externTarget("io.grpc.MethodDescriptor.generateFullMethodName")
func fullMethodName(service: in String, method: in String): String = ()

func buildMethod(service: in String, method: in String, kind: in JMethodType): JMethodDescriptor {
  val marshaller: JMarshaller = StreamMarshaller(tag = 0)
  val b = methodDescriptorBuilder(marshaller, marshaller)
  val _ = b.setType(kind)
  val _ = b.setFullMethodName(fullMethodName(service, method))
  b.build()
}

func callOptionsFor(timeoutMs: in Int): JCallOptions {
  if timeoutMs > 0 {
    JCallOptions.DEFAULT.withDeadlineAfter(timeoutMs.toLong(), JTimeUnit.MILLISECONDS)
  } else {
    JCallOptions.DEFAULT
  }
}

@externStatic
@externTarget("io.grpc.ClientInterceptors.intercept")
func interceptChannel(ch: in JManagedChannel, interceptors: in JList): JChannel = ()

func attachMetadata(channel: in JManagedChannel, metadata: in String): JChannel {
  val entries = Types.decodeMetadata(metadata)
  if entries.count == 0 {
    return interceptChannel(channel, JCollections.emptyList())
  }
  val md = JMetadata.new()
  for e in entries {
    if Str.endsWith(e.key, "-bin") {
      val key = JMetadataKey.of(e.key, JMetadata.BINARY_BYTE_MARSHALLER)
      md.put(key, encodeUtf8(e.value))
    } else {
      val key = JMetadataKey.of(e.key, JMetadata.ASCII_STRING_MARSHALLER)
      md.put(key, e.value)
    }
  }
  val interceptor = JMetadataUtils.newAttachHeadersInterceptor(md)
  interceptChannel(channel, JCollections.singletonList(interceptor))
}

func blockingUnaryCall(ch: in JChannel, m: in JMethodDescriptor, o: in JCallOptions, req: in JInputStream): JInputStream {
  JClientCalls.blockingUnaryCall(ch, m, o, req)
}

func blockingServerStreamingCall(call: in JClientCall, req: in JInputStream): JIterator {
  JClientCalls.blockingServerStreamingCall(call, req)
}

/// Unary RPC. `service`/`method` are the proto names (`pkg.Service`,
/// `Method`); a `timeoutMs` of 0 means no deadline.
pub func netCallUnary(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  timeoutMs: in Int,
  metadata: in String,
): Result[slice[Byte], GrpcStatus] {
  var ch: JManagedChannel = default()
  if not tryLookupChannel(channel, ch) {
    return Err(GrpcStatus(code = GrpcStatusCode.FailedPrecondition, message = "gRPC channel is closed"))
  }
  try {
    val m = buildMethod(service, method, JMethodType.UNARY)
    Std.Core.Ok(
      streamToBytes(blockingUnaryCall(attachMetadata(ch, metadata), m, callOptionsFor(timeoutMs), bytesToStream(payload)))
    )
  } catch Bug as b {
    Err(statusFromException(b.typeName, b.message))
  }
}

// ─── Client: server-streaming calls ───────────────────────────────────────────
pub func netOpenServerStream(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  timeoutMs: in Int,
  metadata: in String,
): Result[GrpcStream, GrpcStatus] {
  var ch: JManagedChannel = default()
  if not tryLookupChannel(channel, ch) {
    return Err(GrpcStatus(code = GrpcStatusCode.FailedPrecondition, message = "gRPC channel is closed"))
  }
  try {
    val m = buildMethod(service, method, JMethodType.SERVER_STREAMING)
    val call = attachMetadata(ch, metadata).newCall(m, callOptionsFor(timeoutMs))
    val responses = blockingServerStreamingCall(call, bytesToStream(payload))
    val id = nextHandleId()
    cdPut(streamRegistry, id.toString(), StreamState(call = call, responses = responses))
    Std.Core.Ok(Types.wrapStreamHandle(id))
  } catch Bug as b {
    Err(statusFromException(b.typeName, b.message))
  }
}

/// Next message: `Ok(Some(bytes))`, `Ok(None)` at end of stream, `Err(status)`
/// when the call failed. A closed or unknown stream reads as end of stream.
pub func netNextStreamMessage(stream: in GrpcStream): Result[Option[slice[Byte]], GrpcStatus] {
  var state: StreamState = default()
  if not cdTryGetValue(streamRegistry, Types.streamHandleId(stream).toString(), state) {
    return Std.Core.Ok(None)
  }
  try {
    if state.responses.hasNext() {
      Std.Core.Ok(Some(value = streamToBytes(nextMessage(state.responses))))
    } else {
      Std.Core.Ok(None)
    }
  } catch Bug as b {
    Err(statusFromException(b.typeName, b.message))
  }
}

func nextMessage(it: in JIterator): JInputStream {
  it.next()
}

/// Cancel the call if it is still running and drop it. Closing twice, or a
/// stream from another run, is a no-op.
pub func netCloseStream(stream: in GrpcStream): Unit {
  var state: StreamState = default()
  if cdRemove(streamRegistry, Types.streamHandleId(stream).toString(), state) {
    val noCause: JThrowable = default()
    state.call.cancel("stream closed by client", noCause)
  }
}

// ─── Server: hosting ────────────────────────────────────────────────────────────
// A grpc-java `Server` (Netty transport, plaintext) serving the registry's
// routes. Handlers run on grpc-java's call executor, one call per thread.
extern type JServer = "io.grpc.Server"

extern type JNettyServerBuilder = "io.grpc.netty.shaded.io.grpc.netty.NettyServerBuilder"

extern type JInetSocketAddress = "java.net.InetSocketAddress"

extern type JServerServiceDefinition = "io.grpc.ServerServiceDefinition"

extern type JServiceBuilder = "io.grpc.ServerServiceDefinition$Builder"

extern type JServerCallHandler = "io.grpc.ServerCallHandler"

extern type JUnaryMethod = "io.grpc.stub.ServerCalls$UnaryMethod"

extern type JServerStreamingMethod = "io.grpc.stub.ServerCalls$ServerStreamingMethod"

extern type JStreamObserver = "io.grpc.stub.StreamObserver"

extern type JStatus = "io.grpc.Status"

extern type JServerInterceptor = "io.grpc.ServerInterceptor"

extern type JServerInterceptors = "io.grpc.ServerInterceptors"

extern type JServerCall = "io.grpc.ServerCall"

extern type JServerCallListener = "io.grpc.ServerCall$Listener"

extern type JContext = "io.grpc.Context"

extern type JContextKey = "io.grpc.Context$Key"

extern type JContexts = "io.grpc.Contexts"

extern type JSet = "java.util.Set"

// The request metadata, encoded as `Types.encodeMetadata` does, travels from
// the interceptor to the handler in a gRPC `Context` value: a handler runs on
// an executor thread, not the interceptor's.
val metadataContextKey: JContextKey = JContext.key("lyric.grpc.metadata")

func isReservedHeader(name: in String): Bool {
  name == "content-type" or name == "te" or name == "user-agent" or Str.startsWith(name, "grpc-") or
    Str.endsWith(name, "-bin")
}

func encodeHeaders(headers: in JMetadata): String {
  val entries: List[GrpcMetadataEntry] = newList()
  val it = headers.keys().iterator()
  while it.hasNext() {
    val raw: JObject = it.next()
    val name = raw.toString()
    if not isReservedHeader(name) {
      val key = JMetadataKey.of(name, JMetadata.ASCII_STRING_MARSHALLER)
      val value: JObject = headers.get(key)
      entries.add(GrpcMetadataEntry(key = name, value = value.toString()))
    }
  }
  Types.encodeMetadata(entries.toArray())
}

record MetadataCapture {
  tag: Int
}

impl JServerInterceptor for MetadataCapture {
  func interceptCall(call: in JServerCall, headers: in JMetadata, next: in JServerCallHandler): JServerCallListener {
    val ctx = JContext.current().withValue(metadataContextKey, encodeHeaders(headers))
    JContexts.interceptCall(ctx, call, headers, next)
  }
}

func requestMetadata(): slice[GrpcMetadataEntry] {
  val encoded: JObject = metadataContextKey.get()
  Types.decodeMetadata(encoded.toString())
}

func failCall(observer: in JStreamObserver, status: in GrpcStatus): Unit {
  try {
    val code = JStatus.fromCodeValue(Types.statusCodeToInt(status.code))
    observer.onError(code.withDescription(status.message).asRuntimeException())
  } catch Bug as _ {
    ()
  }
}

func panicStatus(): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.Internal, message = "handler panicked")
}

func runUnary(
  handle: in (slice[Byte], slice[GrpcMetadataEntry]) -> Result[slice[Byte], GrpcStatus],
  request: in JInputStream,
  observer: in JStreamObserver,
): Unit {
  try {
    match handle(streamToBytes(request), requestMetadata()) {
      case Ok(response) -> {
        observer.onNext(bytesToStream(response))
        observer.onCompleted()
      }
      case Err(status) -> failCall(observer, status)
    }
  } catch Bug as _ {
    failCall(observer, panicStatus())
  }
}

func sendResponse(observer: in JStreamObserver, message: in slice[Byte]): Bool {
  try {
    observer.onNext(bytesToStream(message))
    true
  } catch Bug as _ {
    false
  }
}

func runStreaming(
  handle: in (slice[Byte], slice[GrpcMetadataEntry], (slice[Byte]) -> Bool) -> Result[Unit, GrpcStatus],
  request: in JInputStream,
  observer: in JStreamObserver,
): Unit {
  try {
    match handle(streamToBytes(request), requestMetadata(), { m: slice[Byte] -> sendResponse(observer, m) }) {
      case Ok(_) -> observer.onCompleted()
      case Err(status) -> failCall(observer, status)
    }
  } catch Bug as _ {
    failCall(observer, panicStatus())
  }
}

record UnaryAdapter {
  handle: (slice[Byte], slice[GrpcMetadataEntry]) -> Result[slice[Byte], GrpcStatus]
}

impl JUnaryMethod for UnaryAdapter {
  func invoke(request: in JInputStream, observer: in JStreamObserver): Unit {
    runUnary(self.handle, request, observer)
  }
}

record StreamingAdapter {
  handle: (slice[Byte], slice[GrpcMetadataEntry], (slice[Byte]) -> Bool) -> Result[Unit, GrpcStatus]
}

impl JServerStreamingMethod for StreamingAdapter {
  func invoke(request: in JInputStream, observer: in JStreamObserver): Unit {
    runStreaming(self.handle, request, observer)
  }
}

@externStatic
@externTarget("io.grpc.stub.ServerCalls.asyncUnaryCall")
func unaryCallHandler(m: in JUnaryMethod): JServerCallHandler = ()

@externStatic
@externTarget("io.grpc.stub.ServerCalls.asyncServerStreamingCall")
func streamingCallHandler(m: in JServerStreamingMethod): JServerCallHandler = ()

@externStatic
@externTarget("io.grpc.ServerInterceptors.intercept")
func interceptService(s: in JServerServiceDefinition, interceptors: in JList): JServerServiceDefinition = ()

func addRoute(b: in JServiceBuilder, route: in GrpcRoute): Unit {
  match route.handler {
    case GrpcHandler.Unary(handle) -> {
      val adapter: JUnaryMethod = UnaryAdapter(handle = handle)
      val _ = b.addMethod(buildMethod(route.service, route.method, JMethodType.UNARY), unaryCallHandler(adapter))
    }
    case GrpcHandler.ServerStreaming(handle) -> {
      val adapter: JServerStreamingMethod = StreamingAdapter(handle = handle)
      val _ = b.addMethod(
        buildMethod(route.service, route.method, JMethodType.SERVER_STREAMING),
        streamingCallHandler(adapter)
      )
    }
  }
}

func serviceNames(registry: in ServiceRegistry): List[String] {
  val names: List[String] = newList()
  for r in registry.routes {
    var seen = false
    for n in names {
      if n == r.service {
        seen = true
      }
    }
    if not seen {
      names.add(r.service)
    }
  }
  names
}

func buildServiceDefinition(service: in String, registry: in ServiceRegistry): JServerServiceDefinition {
  val b = JServerServiceDefinition.builder(service)
  for r in registry.routes {
    if r.service == service {
      addRoute(b, r)
    }
  }
  val capture: JServerInterceptor = MetadataCapture(tag = 0)
  interceptService(b.build(), JCollections.singletonList(capture))
}

func buildServer(host: in String, port: in Int, maxConnectionIdleMs: in Int, registry: in ServiceRegistry): JServer {
  val builder = JNettyServerBuilder.forAddress(JInetSocketAddress.new(host, port))
  val _ = builder.maxConnectionIdle(maxConnectionIdleMs.toLong(), JTimeUnit.MILLISECONDS)
  for service in serviceNames(registry) {
    val _ = builder.addService(buildServiceDefinition(service, registry))
  }
  builder.build()
}

val serverRegistry: JvmConcurrentDict[String, JServer] = newConcurrentDict[String, JServer]()

func startServer(
  host: in String,
  port: in Int,
  reflectionEnabled: in Bool,
  maxConnectionIdleMs: in Int,
  registry: in ServiceRegistry,
): JServer {
  if reflectionEnabled {
    panic("gRPC server reflection is not supported: set GrpcServer.reflectionEnabled to false")
  }
  val server = buildServer(host, port, maxConnectionIdleMs, registry)
  try {
    val _ = server.start()
  } catch Bug as b {
    panic("gRPC server could not start on " + host + ":" + port.toString() + ": " + b.message)
  }
  server
}

/// Start serving and block until the server terminates (the process exits).
pub func serve(
  host: in String,
  port: in Int,
  reflectionEnabled: in Bool,
  maxConnectionIdleMs: in Int,
  registry: in ServiceRegistry,
): Unit {
  val server = startServer(host, port, reflectionEnabled, maxConnectionIdleMs, registry)
  server.awaitTermination()
}

pub func netStartHandle(
  host: in String,
  port: in Int,
  reflectionEnabled: in Bool,
  maxConnectionIdleMs: in Int,
  registry: in ServiceRegistry,
): GrpcServerHandle {
  val server = startServer(host, port, reflectionEnabled, maxConnectionIdleMs, registry)
  val id = nextHandleId()
  cdPut(serverRegistry, id.toString(), server)
  Types.wrapServerHandle(id)
}

/// The port the server is bound to; `0` for an unknown or already stopped handle.
pub func netServerPort(handle: in GrpcServerHandle): Int {
  var server: JServer = default()
  if cdTryGetValue(serverRegistry, Types.serverHandleId(handle).toString(), server) {
    server.getPort()
  } else {
    0
  }
}

/// Stop accepting calls and wait up to `drainTimeoutMs` for in-flight calls to
/// finish, then cancel the rest. Stopping twice, or a handle from another run,
/// is a no-op.
pub func netStopHandle(handle: in GrpcServerHandle, drainTimeoutMs: in Int): Unit
  requires: drainTimeoutMs >= 0
{
  var server: JServer = default()
  if cdRemove(serverRegistry, Types.serverHandleId(handle).toString(), server) {
    val _ = server.shutdown()
    if not server.awaitTermination(drainTimeoutMs.toLong(), JTimeUnit.MILLISECONDS) {
      val _ = server.shutdownNow()
    }
  }
}

// ─── Server: rate limiting ────────────────────────────────────────────────────
ref record RateEntry {
  var scaledTokens: Long = 0i64
  var lastRefillMs: Long = 0i64
}

val rateLock: JLock = newLock()

val rateLimitMap: JvmConcurrentDict[String, RateEntry] = newConcurrentDict[String, RateEntry]()

/// Keyed on the whole configuration, not the method alone: two
/// instantiations of the aspect over one method, or a changed environment
/// value, must not inherit the limits of whichever created the entry first
/// (#7247).
func limiterKey(method: in String, requestsPerMinute: in Int, burstSize: in Int): String {
  method + "|" + requestsPerMinute.toString() + "|" + burstSize.toString()
}

/// Consume one permit from the token bucket for `method`: it holds
/// `requestsPerMinute + burstSize` permits, starts full and refills at
/// `requestsPerMinute` a minute (`Resilience.takeToken`). Returns `false` when
/// the bucket is empty.
pub func checkRateLimit(method: in String, requestsPerMinute: in Int, burstSize: in Int): Bool
  requires: requestsPerMinute > 0
  requires: burstSize > 0
{
  val nowMs = Time.nowEpochMillis()
  rateLock.lock()
  defer {
    rateLock.unlock()
  }
  val key = limiterKey(method, requestsPerMinute, burstSize)
  var entry: RateEntry = default()
  if not cdTryGetValue(rateLimitMap, key, entry) {
    val fresh = Resilience.newTokenBucket(requestsPerMinute, burstSize, nowMs)
    entry = RateEntry(scaledTokens = fresh.scaledTokens, lastRefillMs = fresh.lastRefillMs)
    cdPut(rateLimitMap, key, entry)
  }
  val take = Resilience.takeToken(
    Resilience.TokenBucket(scaledTokens = entry.scaledTokens, lastRefillMs = entry.lastRefillMs),
    requestsPerMinute,
    burstSize,
    nowMs
  )
  entry.scaledTokens = take.bucket.scaledTokens
  entry.lastRefillMs = take.bucket.lastRefillMs
  take.allowed
}
