//! Grpc.Kernel.Net — .NET extern boundary for the gRPC client.
//!
//! Real, and covered by `tests/client_dotnet_tests.l` against an in-process
//! gRPC server:
//!   netOpenChannel / netCloseChannel                 — channel lifecycle
//!     (`GrpcChannel.ForAddress` / `.Dispose`, registry-keyed like
//!     `lyric-mq`/`lyric-ws`/`lyric-jobs`)
//!   netCallUnary                                     — unary RPC
//!     (`CallInvoker.BlockingUnaryCall<byte[],byte[]>`)
//!   netOpenServerStream / netNextStreamMessage /
//!     netCloseStream                                 — server streaming
//!     (`AsyncServerStreamingCall<byte[]>`, `IAsyncStreamReader<byte[]>`)
//!   checkRateLimit                                   — in-process sliding-window limiter
//!
//! Every binding is an `extern type` plus `@externTarget` auto-FFI resolved
//! from the NuGet reference assemblies; there is no `extern package` block
//! (that form has no lowering on any target, decision D281). Payloads are raw
//! `byte[]` through a pass-through `Marshaller<byte[]>`, so no message type is
//! generated: compose with `lyric-proto`. These bindings needed the MSIL
//! backend to bind a closed generic whose type argument is an array
//! (`Marshaller`1[System.Byte[]]`), a closed generic nested in another, and a
//! generic method (`BlockingUnaryCall<TReq,TResp>`) whose type arguments the
//! wrapper's array types pin (#6581 and its follow-ups).
//!
//! Server hosting (`serve` / `netStartHandle` / `netStopHandle` /
//! `netServerPort`) delegates to `Grpc.Kernel.Net.Server`, a pure-Lyric h2c gRPC
//! server: `Grpc.AspNetCore` registers an RPC through `BindableService` /
//! `ServiceBinderBase`, abstract classes a Lyric record cannot extend (D284).
//!
//! JWT verification lives in Auth.Kernel.Net (lyric-auth).
//!
//! Only active when compiled with feature = "dotnet".
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "dotnet")
@io
package Grpc.Kernel.Net

import Grpc.Types
import Grpc.Kernel.Net.Server
import Std.Core

// ─── Opaque .NET types ────────────────────────────────────────────────────────
extern type NetGrpcChannel = "Grpc.Net.Client.GrpcChannel"

extern type NetGrpcStream = "System.Collections.Generic.IAsyncEnumerator`1[System.Byte[]]"

// ─── Client: channel lifecycle ────────────────────────────────────────────────
// `GrpcChannel.ForAddress` has two same-arity overloads (`string` and `Uri`);
// the self-hosted MSIL backend's plain extern-target resolver binds the
// `string` overload correctly here (verified against the emitted MemberRef
// signature: `(string) : GrpcChannel`), unlike the generic-declaring-type
// path `Marshaller`1`..ctor` below hits (see the long comment on
// `netCallUnary`) — this one is a non-generic declaring type with an
// ordinary (non-delegate) parameter, so it never touches that code path.
@axiom("Grpc.Net.Client.GrpcChannel.ForAddress(string) conforms to its documented NuGet contract")
@externStatic
@externTarget("Grpc.Net.Client.GrpcChannel.ForAddress")
func grpcChannelForAddress(address: in String): NetGrpcChannel = ()

@externInstance
@externTarget("Grpc.Net.Client.GrpcChannel.Dispose")
func grpcChannelDispose(ch: in NetGrpcChannel): Unit = ()

// `lyric-ws`/`lyric-jobs`/`lyric-mq` kernels declare the identical
// `ConcurrentDict[K, V]` extern-type binding (a generic Lyric function
// monomorphized once per distinct `<K, V>` instantiation); re-declared
// locally per the kernel-boundary rule that only a file's own `_kernel/`
// package may declare `extern`/`@externTarget` surface
// (docs/14-native-stdlib-plan.md). This file needs its own, separately
// *named* (non-generic) monomorphization for `<Int, NetGrpcChannel>` rather
// than reusing the shared `[K, V]` helpers the rate limiter below
// instantiates for `<String, RateLimiterPair>`: an earlier version of this
// file, with two distinct call-site monomorphizations of the same generic
// function/type, plus a UFCS cross-package call to `wrapChannelHandle`
// (`netOpenChannel` below), failed at runtime with "unsupported method
// 'wrapChannelHandle'... (no matching user method, extern binding, or
// built-in intrinsic)". `netOpenChannel`/`netCloseChannel` now call
// `wrapChannelHandle`/`channelHandleId` via qualified syntax rather than
// UFCS, which independently fixes that exact failure (tracked as its own
// self-hosted-compiler bug, #6580) — but this hand-specialized,
// non-generic dict is kept rather than reverted to the shared generic
// `ConcurrentDict[K, V]` family, since only the combination of both fixes
// together has been verified.
extern type NetGrpcChannelDict = "System.Collections.Concurrent.ConcurrentDictionary`2[System.Int32,Grpc.Net.Client.GrpcChannel]"

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2..ctor")
func newChannelDict(): NetGrpcChannelDict = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryAdd")
func channelDictTryAdd(dict: in NetGrpcChannelDict, key: in Int, value: in NetGrpcChannel): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryGetValue")
func channelDictTryGet(dict: in NetGrpcChannelDict, key: in Int, value: out NetGrpcChannel): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryRemove")
func channelDictTryRemove(dict: in NetGrpcChannelDict, key: in Int, value: out NetGrpcChannel): Bool = ()

// Guards `channelHandleCounter`'s read-modify-write below — the identical
// `monitorEnter`/`monitorExit` idiom `lyric-ws`/`lyric-jobs`/`lyric-mq`
// kernels already use for their own `HandleCounter` (#6584: an earlier
// version of this file left the increment unguarded, letting two
// concurrent `Grpc.openChannel` calls compute the same id and alias one
// caller's channel onto the other's handle).
@axiom("System.Threading.Monitor.Enter — acquires an exclusive lock on obj")
@externStatic
@externTarget("System.Threading.Monitor.Enter")
func monitorEnter[T](obj: in T): Unit = ()

@axiom("System.Threading.Monitor.Exit — releases an exclusive lock on obj")
@externStatic
@externTarget("System.Threading.Monitor.Exit")
func monitorExit[T](obj: in T): Unit = ()

// Live `Grpc.Net.Client.GrpcChannel` objects, keyed by the counter-issued id
// the public `GrpcChannel` opaque type wraps (`Grpc.Types`' registry-key
// idiom — see that file's doc comment). `GrpcChannel` cannot hold the live
// .NET object directly: it is a platform-neutral type shared with the (not
// yet implemented) JVM kernel, so the live handle lives here instead.
//
// A real `ConcurrentDictionary` (not Lyric's own `Map[K, V]`): a module-level
// `Map` with a non-primitive (extern-type) value was found to compile to a
// mis-specialized `Dictionary<object, object>` at runtime — the same
// self-hosted-backend gap `getOrCreateLimiterPair` below already works
// around for `RateLimiterPair`. Storing a live `NetGrpcChannel` in a `Map`
// hit the identical gap here: the channel round-tripped through the
// mis-specialized dictionary corrupted enough MSIL token bookkeeping in this
// file that the unrelated, already-correctly-emitted `GrpcChannel.ForAddress`
// call site failed at runtime with `System.TypeLoadException`/
// `EntryPointNotFoundException` depending on the surrounding code shape —
// confirmed by bisection (removing the `Map` alone fixed it).
val channelRegistry: NetGrpcChannelDict = newChannelDict()

ref record ChannelHandleCounter {
  var next: Int = 0
}

val channelHandleCounter: ChannelHandleCounter = ChannelHandleCounter()

func nextStreamHandleId(): Int {
  monitorEnter(channelHandleCounter)
  channelHandleCounter.next = channelHandleCounter.next + 1
  val id = channelHandleCounter.next
  monitorExit(channelHandleCounter)
  id
}

func nextChannelHandleId(): Int {
  monitorEnter(channelHandleCounter)
  channelHandleCounter.next = channelHandleCounter.next + 1
  val id = channelHandleCounter.next
  monitorExit(channelHandleCounter)
  id
}

/// Open an HTTP/2 channel to `address`.  `GrpcChannel.ForAddress` is lazy —
/// it validates and parses `address` synchronously (the only way this call
/// fails) but does not dial the network until the first RPC or an explicit
/// `ConnectAsync`, so a malformed address is the only Err case reachable
/// from this function today.
pub func netOpenChannel(address: in String): Result[GrpcChannel, String] {
  try {
    val ch = grpcChannelForAddress(address)
    val id = nextChannelHandleId()
    val _ = channelDictTryAdd(channelRegistry, id, ch)
    Std.Core.Ok(Types.wrapChannelHandle(id))
  } catch Bug as b {
    Err(b.message)
  }
}

/// Close the channel and release all pooled HTTP/2 connections.  A double
/// close or a handle from a different process/run is a silent no-op (the
/// registry lookup simply misses) rather than a panic — mirrors the
/// `lyric-mq`/`lyric-ws` handle-registry kernels' behavior for the same
/// int-keyed-registry idiom.
///
/// Pops the entry via `TryRemove` before disposing, rather than
/// `TryGetValue` then dispose then `TryRemove`: the get-then-dispose-then-
/// remove order left a window where two threads racing to close the same
/// handle could both pass the `TryGetValue` check and both call `Dispose`
/// on the same `NetGrpcChannel`. `TryRemove` atomically claims the entry,
/// so only one of the two ever proceeds to `Dispose`.
pub func netCloseChannel(channel: in GrpcChannel): Unit {
  val id = Types.channelHandleId(channel)
  var ch: NetGrpcChannel = default()
  if channelDictTryRemove(channelRegistry, id, ch) {
    grpcChannelDispose(ch)
  }
}

// ─── Client: unary calls ──────────────────────────────────────────────────────
// Bound against `Grpc.Core.Api` 2.65.0 with a pass-through `byte[]` marshaller:
// the library hands the caller raw protobuf bytes (compose with `lyric-proto`),
// so no message type is ever generated. `Marshaller`1`'s constructor takes a
// closed-generic `Func` delegate and `CallInvoker.BlockingUnaryCall` is a
// generic method; the MSIL backend binds both since #6581 (#6981).
extern type NetCallInvoker = "Grpc.Core.CallInvoker"

extern type NetMarshaller = "Grpc.Core.Marshaller`1[System.Byte[]]"

extern type NetMethod = "Grpc.Core.Method`2[System.Byte[],System.Byte[]]"

extern type NetMethodType = "Grpc.Core.MethodType"

extern type NetCallOptions = "Grpc.Core.CallOptions"

extern type NetMetadata = "Grpc.Core.Metadata"

extern type NetDateTime = "System.DateTime"

@externInstance
@externTarget("Grpc.Net.Client.GrpcChannel.CreateCallInvoker")
func channelCreateCallInvoker(ch: in NetGrpcChannel): NetCallInvoker = ()

@externTarget("Grpc.Core.Marshaller`1..ctor")
func newMarshaller(
  serializer: in (slice[Byte]) -> slice[Byte], deserializer: in (slice[Byte]) -> slice[Byte]
): NetMarshaller = ()

@externTarget("Grpc.Core.Method`2..ctor")
func newMethod(
  kind: in NetMethodType,
  service: in String,
  name: in String,
  req: in NetMarshaller,
  resp: in NetMarshaller,
): NetMethod = ()

@externTarget("Grpc.Core.MethodType.Unary")
func methodTypeUnary(): NetMethodType = ()

@externTarget("Grpc.Core.MethodType.ServerStreaming")
func methodTypeServerStreaming(): NetMethodType = ()

@externTarget("Grpc.Core.Metadata..ctor")
func newMetadata(): NetMetadata = ()

@externInstance
@externTarget("Grpc.Core.Metadata.Add")
func metadataAdd(m: in NetMetadata, key: in String, value: in String): Unit = ()

@externInstance
@externTarget("Grpc.Core.CallOptions.WithHeaders")
func callOptionsWithHeaders(o: in NetCallOptions, headers: in NetMetadata): NetCallOptions = ()

@externInstance
@externTarget("Grpc.Core.CallOptions.WithDeadline")
func callOptionsWithDeadline(o: in NetCallOptions, deadline: in NetDateTime): NetCallOptions = ()

@externStatic
@externTarget("System.DateTime.get_UtcNow")
func dateTimeUtcNow(): NetDateTime = ()

@externInstance
@externTarget("System.DateTime.AddMilliseconds")
func dateTimeAddMillis(d: in NetDateTime, ms: in Double): NetDateTime = ()

@externInstance
@externTarget("Grpc.Core.CallInvoker.BlockingUnaryCall")
func invokerBlockingUnary(
  inv: in NetCallInvoker,
  m: in NetMethod,
  host: in String,
  o: in NetCallOptions,
  req: in slice[Byte],
): slice[Byte] = ()

func newByteMarshaller(): NetMarshaller {
  newMarshaller({ b: slice[Byte] -> b }, { b: slice[Byte] -> b })
}

func buildCallOptions(timeoutMs: in Int, metadata: in String): NetCallOptions {
  var o: NetCallOptions = default()
  val entries = Types.decodeMetadata(metadata)
  if entries.count > 0 {
    val md = newMetadata()
    for e in entries {
      metadataAdd(md, e.key, e.value)
    }
    o = callOptionsWithHeaders(o, md)
  }
  if timeoutMs > 0 {
    o = callOptionsWithDeadline(o, dateTimeAddMillis(dateTimeUtcNow(), timeoutMs.toDouble()))
  }
  o
}

func lookupChannel(channel: in GrpcChannel): Option[NetGrpcChannel] {
  var ch: NetGrpcChannel = default()
  if channelDictTryGet(channelRegistry, Types.channelHandleId(channel), ch) {
    Some(value = ch)
  } else {
    None
  }
}

pub func netCallUnary(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  timeoutMs: in Int,
  metadata: in String,
): Result[slice[Byte], GrpcStatus] {
  match lookupChannel(channel) {
    case None -> Err(GrpcStatus(code = GrpcStatusCode.FailedPrecondition, message = "gRPC channel is closed"))
    case Some(ch) -> {
      try {
        val inv = channelCreateCallInvoker(ch)
        val m = newMethod(methodTypeUnary(), service, method, newByteMarshaller(), newByteMarshaller())
        Ok(invokerBlockingUnary(inv, m, "", buildCallOptions(timeoutMs, metadata), payload))
      } catch Bug as b {
        Err(statusFromException(b.typeName, b.message))
      }
    }
  }
}

// ─── Client: server-streaming calls ───────────────────────────────────────────
// `AsyncServerStreamingCall<byte[]>` owns the HTTP/2 stream; `ResponseStream`
// is its `IAsyncStreamReader<byte[]>`. Lyric's call model is synchronous, so
// each `MoveNext` task is waited on with `Task.Result`. The live call object
// lives in `streamRegistry`, keyed by the `Int` the opaque `GrpcStream` wraps.
extern type NetServerStreamingCall = "Grpc.Core.AsyncServerStreamingCall`1[System.Byte[]]"

extern type NetStreamReader = "Grpc.Core.IAsyncStreamReader`1[System.Byte[]]"

extern type NetTaskOfBool = "System.Threading.Tasks.Task`1[System.Boolean]"

extern type NetCancellationToken = "System.Threading.CancellationToken"

extern type NetStreamDict = "System.Collections.Concurrent.ConcurrentDictionary`2[System.Int32,Grpc.Core.AsyncServerStreamingCall`1[System.Byte[]]]"

@externInstance
@externTarget("Grpc.Core.CallInvoker.AsyncServerStreamingCall")
func invokerServerStreaming(
  inv: in NetCallInvoker,
  m: in NetMethod,
  host: in String,
  o: in NetCallOptions,
  req: in slice[Byte],
): NetServerStreamingCall = ()

@externInstance
@externTarget("Grpc.Core.AsyncServerStreamingCall`1.get_ResponseStream")
func streamingCallResponseStream(c: in NetServerStreamingCall): NetStreamReader = ()

@externInstance
@externTarget("Grpc.Core.AsyncServerStreamingCall`1.Dispose")
func streamingCallDispose(c: in NetServerStreamingCall): Unit = ()

@externInstance
@externTarget("Grpc.Core.IAsyncStreamReader`1.MoveNext")
func readerMoveNext(r: in NetStreamReader, token: in NetCancellationToken): NetTaskOfBool = ()

@externInstance
@externTarget("Grpc.Core.IAsyncStreamReader`1.get_Current")
func readerCurrent(r: in NetStreamReader): slice[Byte] = ()

@externInstance
@externTarget("System.Threading.Tasks.Task`1.get_Result")
func taskOfBoolResult(t: in NetTaskOfBool): Bool = ()

@externTarget("System.Threading.CancellationToken.get_None")
func cancellationTokenNone(): NetCancellationToken = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2..ctor")
func newStreamDict(): NetStreamDict = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryAdd")
func streamDictTryAdd(dict: in NetStreamDict, key: in Int, value: in NetServerStreamingCall): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryGetValue")
func streamDictTryGet(dict: in NetStreamDict, key: in Int, value: out NetServerStreamingCall): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryRemove")
func streamDictTryRemove(dict: in NetStreamDict, key: in Int, value: out NetServerStreamingCall): Bool = ()

val streamRegistry: NetStreamDict = newStreamDict()

/// Open a server-streaming call. The request is sent immediately; messages
/// are read with `netNextStreamMessage`. A failure that only surfaces once
/// the first message is awaited (an unreachable server, a deadline) is
/// reported by that read, as in every gRPC client.
pub func netOpenServerStream(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  timeoutMs: in Int,
  metadata: in String,
): Result[GrpcStream, GrpcStatus] {
  match lookupChannel(channel) {
    case None -> Err(GrpcStatus(code = GrpcStatusCode.FailedPrecondition, message = "gRPC channel is closed"))
    case Some(ch) -> {
      try {
        val inv = channelCreateCallInvoker(ch)
        val m = newMethod(methodTypeServerStreaming(), service, method, newByteMarshaller(), newByteMarshaller())
        val call = invokerServerStreaming(inv, m, "", buildCallOptions(timeoutMs, metadata), payload)
        val id = nextStreamHandleId()
        val _ = streamDictTryAdd(streamRegistry, id, call)
        Ok(Types.wrapStreamHandle(id))
      } catch Bug as b {
        Err(statusFromException(b.typeName, b.message))
      }
    }
  }
}

/// Read the next message: `Ok(Some(bytes))`, `Ok(None)` at end of stream, or
/// `Err(status)` when the call failed (the stream is then finished).
pub func netNextStreamMessage(stream: in GrpcStream): Result[Option[slice[Byte]], GrpcStatus] {
  var call: NetServerStreamingCall = default()
  if not streamDictTryGet(streamRegistry, Types.streamHandleId(stream), call) {
    return Ok(None)
  }
  try {
    val reader = streamingCallResponseStream(call)
    if taskOfBoolResult(readerMoveNext(reader, cancellationTokenNone())) {
      Ok(Some(value = readerCurrent(reader)))
    } else {
      Ok(None)
    }
  } catch Bug as b {
    Err(statusFromException(b.typeName, b.message))
  }
}

/// Cancel (if still running) and release the call. Closing twice, or a
/// stream from another run, is a no-op.
pub func netCloseStream(stream: in GrpcStream): Unit {
  var call: NetServerStreamingCall = default()
  if streamDictTryRemove(streamRegistry, Types.streamHandleId(stream), call) {
    streamingCallDispose(call)
  }
}

// ─── Server: hosting ────────────────────────────────────────────────────────────
// The pure-Lyric h2c server lives in `Grpc.Kernel.Net.Server`; these are the
// entry points `Grpc` calls.
pub func serve(
  host: in String,
  port: in Int,
  reflectionEnabled: in Bool,
  maxConnectionIdleMs: in Int,
  registry: in ServiceRegistry,
): Unit {
  Grpc.Kernel.Net.Server.serve(host, port, reflectionEnabled, maxConnectionIdleMs, registry)
}

pub func netStartHandle(
  host: in String,
  port: in Int,
  reflectionEnabled: in Bool,
  maxConnectionIdleMs: in Int,
  registry: in ServiceRegistry,
): GrpcServerHandle {
  Grpc.Kernel.Net.Server.startServer(host, port, reflectionEnabled, maxConnectionIdleMs, registry)
}

pub func netServerPort(handle: in GrpcServerHandle): Int {
  Grpc.Kernel.Net.Server.serverPort(handle)
}

pub func netStopHandle(handle: in GrpcServerHandle, drainTimeoutMs: in Int): Unit
  requires: drainTimeoutMs >= 0
{
  Grpc.Kernel.Net.Server.stopServer(handle, drainTimeoutMs)
}

// ─── Server: rate limiting (System.Threading.RateLimiting) ────────────────────
// Two independent `SlidingWindowRateLimiter`s per method, composed with AND: a
// window-only limiter cannot express both "average request rate" and
// "instantaneous burst ceiling" as separate numbers, so a request must clear a
// coarse 60s/requestsPerMinute-permit limiter AND a fine 1s/burstSize-permit
// limiter. The burst limiter is checked first so a request that fails it never
// spends a (scarcer) sustained-window permit.
extern type NetRateLimiterOptions = "System.Threading.RateLimiting.SlidingWindowRateLimiterOptions"

extern type NetRateLimiter = "System.Threading.RateLimiting.SlidingWindowRateLimiter"

extern type NetRateLimitLease = "System.Threading.RateLimiting.RateLimitLease"

extern type NetQueueProcessingOrder = "System.Threading.RateLimiting.QueueProcessingOrder"

extern type NetTimeSpan = "System.TimeSpan"

// `lyric-ws`/`lyric-jobs`/`lyric-mq` kernels declare the identical binding;
// re-declared locally per the kernel-boundary rule that only a file's own
// `_kernel/` package may declare `extern`/`@externTarget` surface
// (docs/14-native-stdlib-plan.md). Kept generic (unlike the channel
// registry's hand-specialized `NetGrpcChannelDict` above) since this is the
// only `<K, V>` instantiation of it in this file — see the long comment on
// `NetGrpcChannelDict` for why a *second* generic instantiation in the same
// file is avoided.
extern type ConcurrentDict[K, V] = "System.Collections.Concurrent.ConcurrentDictionary`2"

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2..ctor")
func newConcurrentDict[K, V](): ConcurrentDict[K, V] = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryGetValue")
func cdTryGetValue[K, V](dict: in ConcurrentDict[K, V], key: in K, value: out V): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryAdd")
func cdTryAdd[K, V](dict: in ConcurrentDict[K, V], key: in K, value: in V): Bool = ()

@axiom("System.Threading.RateLimiting.SlidingWindowRateLimiter conforms to its documented .NET contract")
@externTarget("System.Threading.RateLimiting.SlidingWindowRateLimiterOptions..ctor")
func newRateLimiterOptions(): NetRateLimiterOptions = ()

@externInstance
@externTarget("System.Threading.RateLimiting.SlidingWindowRateLimiterOptions.set_Window")
func rlOptSetWindow(o: in NetRateLimiterOptions, w: in NetTimeSpan): Unit = ()

@externInstance
@externTarget("System.Threading.RateLimiting.SlidingWindowRateLimiterOptions.set_PermitLimit")
func rlOptSetPermitLimit(o: in NetRateLimiterOptions, n: in Int): Unit = ()

@externInstance
@externTarget("System.Threading.RateLimiting.SlidingWindowRateLimiterOptions.set_SegmentsPerWindow")
func rlOptSetSegmentsPerWindow(o: in NetRateLimiterOptions, n: in Int): Unit = ()

@externInstance
@externTarget("System.Threading.RateLimiting.SlidingWindowRateLimiterOptions.set_QueueLimit")
func rlOptSetQueueLimit(o: in NetRateLimiterOptions, n: in Int): Unit = ()

@externInstance
@externTarget("System.Threading.RateLimiting.SlidingWindowRateLimiterOptions.set_QueueProcessingOrder")
func rlOptSetQueueOrder(o: in NetRateLimiterOptions, order: in NetQueueProcessingOrder): Unit = ()

@externInstance
@externTarget("System.Threading.RateLimiting.SlidingWindowRateLimiterOptions.set_AutoReplenishment")
func rlOptSetAutoReplenishment(o: in NetRateLimiterOptions, v: in Bool): Unit = ()

@externTarget("System.Threading.RateLimiting.QueueProcessingOrder.OldestFirst")
func queueOrderOldestFirst(): NetQueueProcessingOrder = ()

@externTarget("System.TimeSpan.FromMilliseconds")
func rlTimeSpanFromMillis(ms: in Double): NetTimeSpan = ()

@externTarget("System.Threading.RateLimiting.SlidingWindowRateLimiter..ctor")
func newRateLimiter(o: in NetRateLimiterOptions): NetRateLimiter = ()

@externInstance
@externTarget("System.Threading.RateLimiting.RateLimiter.AttemptAcquire")
func rlAttemptAcquire(l: in NetRateLimiter, permitCount: in Int): NetRateLimitLease = ()

@externInstance
@externTarget("System.Threading.RateLimiting.RateLimitLease.get_IsAcquired")
func rlLeaseIsAcquired(lease: in NetRateLimitLease): Bool = ()

@externInstance
@externTarget("System.Threading.RateLimiting.RateLimitLease.Dispose")
func rlLeaseDispose(lease: in NetRateLimitLease): Unit = ()

func newSlidingWindowLimiter(windowMs: in Int, permitLimit: in Int, segmentsPerWindow: in Int): NetRateLimiter {
  val o = newRateLimiterOptions()
  rlOptSetWindow(o, rlTimeSpanFromMillis(windowMs.toDouble()))
  rlOptSetPermitLimit(o, permitLimit)
  rlOptSetSegmentsPerWindow(o, segmentsPerWindow)
  rlOptSetQueueLimit(o, 0)
  rlOptSetQueueOrder(o, queueOrderOldestFirst())
  rlOptSetAutoReplenishment(o, true)
  newRateLimiter(o)
}

// Per-method (sustained, burst) limiter pair, created lazily on first use
// and reused across calls. The registry is a real `ConcurrentDictionary`
// (not Lyric's own `Map[K, V]` — a module-level `Map` with a non-primitive
// record value type was found to compile to a mis-specialized
// `Dictionary<object, object>` at runtime, an unrelated self-hosted-backend
// gap; `lyric-ws`/`lyric-jobs`/`lyric-mq` kernels already use this same
// `ConcurrentDict` extern-type idiom for exactly this kind of registry),
// so concurrent RPCs racing to create the same method's entry need no
// separate lock. `sustained`/`burst` are `Option[NetRateLimiter]` (not a
// bare `NetRateLimiter`) purely so `default()` has a well-defined
// zero-value to zero-init the `out` parameter on a `cdTryGetValue` miss —
// Lyric has no null literal, so an extern type with no natural "empty"
// value can only appear in a `default()`-able record wrapped in `Option`.
// Both fields are always `Some` in every pair this file ever stores.
record RateLimiterPair {
  sustained: Option[NetRateLimiter] = None
  burst: Option[NetRateLimiter] = None
}

val rateLimiters: ConcurrentDict[String, RateLimiterPair] = newConcurrentDict()

// Keyed on the whole configuration, not the method alone: two instantiations
// of the aspect over one method, or a changed environment value, must not
// inherit the limits of whichever created the entry first (#7247).
func limiterKey(method: in String, requestsPerMinute: in Int, burstSize: in Int): String {
  method + "|" + requestsPerMinute.toString() + "|" + burstSize.toString()
}

func getOrCreateLimiterPair(method: in String, requestsPerMinute: in Int, burstSize: in Int): RateLimiterPair {
  val key = limiterKey(method, requestsPerMinute, burstSize)
  var existing: RateLimiterPair = default()
  if cdTryGetValue(rateLimiters, key, existing) {
    return existing
  }
  val fresh = RateLimiterPair(
    sustained = Some(value = newSlidingWindowLimiter(60000, requestsPerMinute, 6)),
    burst = Some(value = newSlidingWindowLimiter(1000, burstSize, 1))
  )
  if cdTryAdd(rateLimiters, key, fresh) {
    return fresh
  }
  // Lost the race to another thread creating the same method's entry
  // concurrently; use its winning pair instead of our (now-orphaned) one.
  var winner: RateLimiterPair = default()
  val _ = cdTryGetValue(rateLimiters, key, winner)
  winner
}

func unwrapLimiter(opt: in Option[NetRateLimiter]): NetRateLimiter {
  match opt {
    case Some(limiter) -> limiter
    case None -> panic("unreachable: RateLimiterPair's limiters are always Some")
  }
}

/// Check (and consume, if allowed) one permit from both the sustained
/// (`requestsPerMinute` over a rolling 60s window) and burst (`burstSize`
/// over a rolling 1s window) limiters for `method`. Returns `true` only if
/// both grant a permit. Real enforcement.
pub func checkRateLimit(method: in String, requestsPerMinute: in Int, burstSize: in Int): Bool
  requires: requestsPerMinute > 0
  requires: burstSize > 0
{
  val pair = getOrCreateLimiterPair(method, requestsPerMinute, burstSize)
  val burstLease = rlAttemptAcquire(unwrapLimiter(pair.burst), 1)
  val burstOk = rlLeaseIsAcquired(burstLease)
  rlLeaseDispose(burstLease)
  if not burstOk {
    return false
  }
  val sustainedLease = rlAttemptAcquire(unwrapLimiter(pair.sustained), 1)
  val sustainedOk = rlLeaseIsAcquired(sustainedLease)
  rlLeaseDispose(sustainedLease)
  sustainedOk
}
