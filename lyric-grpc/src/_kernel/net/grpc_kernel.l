//! Grpc.Kernel.Net — .NET extern boundary for gRPC client and server.
//!
//! Real:
//!   netOpenChannel / netCloseChannel — channel lifecycle (`GrpcChannel.ForAddress`
//!     / `.Dispose()`, registry-keyed like `lyric-mq`/`lyric-ws`/`lyric-jobs`)
//!   checkRateLimit()                 — in-process sliding-window rate limiter
//!
//! NOT implemented — blocked on a self-hosted-compiler gap (#6581), not a
//! design choice; see the long comment on `netCallUnary` below for the root
//! cause. Each fails fast (a typed `Err`, or a `panic` for the two functions
//! whose signature has no room for one) rather than the ORIGINAL design's
//! declaration-only `extern package { ... }` blocks against
//! `Grpc.Net.Client`/`Grpc.AspNetCore`, which the self-hosted MSIL backend
//! has never actually lowered to any MethodDef/MemberRef (`IExtern` is a
//! documented no-op there; see `Msil.Codegen`'s item dispatcher) — every
//! call through one of those blocks either silently dropped (the
//! pre-#5621/#5516 loud-failure behaviour) or, once that fix landed, would
//! hard-panic at compile time with no path forward for a caller. Tracked
//! overall in #6592; the compiler-side blocker itself is #6581:
//!   netCallUnary                                                 — unary RPC
//!   netOpenServerStream / netNextStreamMessage / netCloseStream  — server streaming
//!   serve() / netStartHandle() / netStopHandle()                 — server hosting
//!
//! A follow-up investigation (2026-09-05, group:ecosystem-lib-kernels) asked
//! whether #6581 still stands against `origin/main` and whether server
//! hosting specifically has a non-generic escape hatch the original #6581
//! writeup didn't consider (`AddGrpc`/`IServiceCollection`-shaped low-level
//! registration, a non-generic `Marshallers` overload, etc). Both `main`'s
//! `genericMemberSigToMsil` (`lyric-compiler/msil/codegen.l`) and
//! `ctxAddMethodSpec`'s callers (`lyric-compiler/msil/lowering.l`) are
//! unchanged from #6581's description — no GENERICINST arm, no general
//! `@externTarget`-generic-method MethodSpec path — and decoding the actual
//! `Grpc.Core.Api`/`Grpc.AspNetCore.Server` 2.65.0 reference-assembly
//! metadata directly (the same byte-level read the auto-FFI resolver does)
//! confirms server hosting has no such escape hatch either: every route
//! from `IServiceCollection.AddGrpc()` (itself non-generic and bindable) to
//! an actual registered RPC method is generic. The high-level
//! `Microsoft.AspNetCore.Builder.GrpcEndpointRouteBuilderExtensions
//! .MapGrpcService<TService>` is a generic extension method (MVAR, one type
//! parameter). Its low-level equivalent —
//! `Grpc.Core.ServerServiceDefinition.Builder.AddMethod<TRequest,TResponse>`
//! and `Grpc.Core.ServiceBinderBase.AddMethod<TRequest,TResponse>`, the pair
//! `MapGrpcService<T>` itself calls into — are equally generic (MVAR,
//! two type parameters each, four overloads apiece for
//! unary/client-streaming/server-streaming/duplex). And every one of those
//! `AddMethod` overloads takes a `Grpc.Core.Method<TRequest,TResponse>`,
//! whose only constructor takes two `Marshaller<T>` instances — hitting
//! Gap 1 a second, independent time (`Marshallers.Create<T>`'s own two
//! overloads were re-checked too: both still take a GENERICINST delegate
//! parameter over `T`, confirming no non-generic factory exists there
//! either). So `AddGrpc()` alone can wire up gRPC's ASP.NET Core middleware
//! plumbing, but produces a server with zero registered RPC methods — not a
//! partial win, since a route table with no routes cannot dispatch
//! anything `Grpc.addMethod` registered. Server hosting therefore fails for
//! the exact same two compiler gaps as unary/streaming, not a third,
//! independent one — this investigation found no bindable subset to ship.
//!
//! JWT verification lives in Auth.Kernel.Net (lyric-auth).
//!
//! Only active when compiled with feature = "dotnet".
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "dotnet")
package Grpc.Kernel.Net

import Grpc.Types
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

record ChannelHandleCounter {
  var next: Int = 0
}

val channelHandleCounter: ChannelHandleCounter = ChannelHandleCounter()

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
// BLOCKED — self-hosted-compiler gap, not a `lyric-grpc` design choice.
//
// A real unary call needs `Grpc.Core.CallInvoker` (obtained from the
// channel), a `Grpc.Core.Marshaller<byte[]>` (pass-through identity
// serializer/deserializer), a `Grpc.Core.Method<byte[],byte[]>`, and
// `CallInvoker.BlockingUnaryCall<TRequest,TResponse>`. Both of the
// following are unimplementable from Lyric today without compiler changes
// (verified empirically against `Grpc.Net.Client`/`Grpc.Core.Api` 2.65.0;
// root-caused against `lyric-compiler/msil/codegen.l`):
//
// 1. `Marshaller<byte[]>` construction. Every `Marshaller<T>` constructor
//    (and every `Marshallers.Create<T>(...)` static-factory overload — the
//    one alternative this ticket asked to try) takes a delegate parameter
//    that is itself a closed generic instantiation over `T`
//    (`Func<T,byte[]>`, `Func<byte[],T>`, or `Action<T,SerializationContext>`
//    / `Func<DeserializationContext,T>`). `Marshaller<T>` is a
//    generic-declaring type (name carries a `` `1 `` arity suffix), so the
//    MSIL backend routes its member calls through
//    `emitGenericExternMember` (`lyric-compiler/msil/codegen.l`), which
//    converts the BCL ctor's real parameter types via
//    `genericMemberSigToMsil`. That converter only has arms for
//    `STPrim`/`STVar`/`STByRef`/`STSzArray`/`STNamed` — there is no arm for
//    a GENERICINST-shaped parameter (`_ -> None`), so it returns `None` for
//    every `Marshaller<T>` ctor parameter, `convOk` goes false, and
//    `emitGenericExternMember` silently returns `false`. The caller then
//    falls through to the "legacy" extern-target lowering, which builds a
//    `MemberRef` for `.ctor` parented directly on the *open* (unconstructed)
//    `Marshaller`1` `TypeRef` instead of a closed `GENERICINST` `TypeSpec` —
//    an ECMA-335 §II.22.25 violation (a member of a generic type must be
//    referenced through a TypeSpec parent). This compiles and builds a
//    clean-looking DLL, but the CLR loader faults the moment the ctor is
//    invoked: `System.TypeLoadException: Could not load type
//    'Grpc.Core.Marshaller`1' from assembly '<the calling assembly>'`
//    (confirmed at both `T = System.Byte[]` and `T = System.String`, so
//    this is not specific to the array-typed witness the real call needs —
//    it reproduces for *any* `T`). Declaring the wrapper generic in Lyric
//    itself (`func newMarshaller[T](...): Marshaller[T]`, mirroring the
//    `ConcurrentDict[K, V]` idiom used elsewhere in this codebase) does not
//    route around this: `ConcurrentDict[K, V]`'s ctor takes zero
//    parameters, so it never exercises `genericMemberSigToMsil` on a
//    GENERICINST parameter in the first place — every real
//    `Marshaller<T>`-constructing member does, regardless of whether the
//    Lyric-side wrapper is itself generic or already monomorphized.
// 2. `CallInvoker.BlockingUnaryCall<TRequest,TResponse>` (and its
//    `Async*Call` siblings) are *generic methods* (MVAR) on a non-generic
//    type, not a generic-declaring-type member. Calling a BCL generic
//    method with explicit witness types needs a `MethodSpec` (table 0x2B)
//    row at the call site (ECMA-335 §II.22.29); the self-hosted MSIL
//    backend can already emit `MethodSpec` rows (`ctxAddMethodSpec`,
//    `lyric-compiler/msil/lowering.l`), but only for a handful of
//    compiler-internal async-state-machine call sites
//    (`ATMB<T>.Start<SM>`, `AwaitUnsafeOnCompleted<TAwaiter,SM>`) — there is
//    no general path from an `@externTarget` user declaration to a
//    `MethodSpec`-instantiated generic-method call. So even a hypothetical
//    fix to (1) would still block on this second, independent gap.
//
// Tracked as a compiler-side follow-up in #6581 (out of `lyric-grpc`'s
// scope — see docs/37-grpc-proto-sketch.md and this package's
// kernel-boundary contract). Channel lifecycle and the rate limiter above
// have no dependency on either gap and are real. Until #6581 lands, this
// fails fast (a typed `Err`) instead of the ORIGINAL design's inert
// `extern package Grpc.Net.Client.Unary { ... }` declaration block, which
// the self-hosted MSIL backend never lowers to any MethodDef/MemberRef
// (see the module doc comment) — a caller reaching this function used to
// hit a silently-dropped call (or, after #5621/#5516's loud-failure fix,
// a hard compile-time panic naming only a compiler internal). This
// `Err`-returning function compiles cleanly and fails honestly at the one
// call site that can actually explain why.
pub func netCallUnary(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  timeoutMs: in Int,
  metadata: in String,
): Result[slice[Byte], GrpcStatus] {
  Err(
    GrpcStatus(
      code = GrpcStatusCode.Unimplemented,
      message = "gRPC .NET unary calls are blocked on a self-hosted-compiler gap (tracked in #6581)"
    )
  )
}

// ─── Client: server-streaming calls ────────────────────────────────────────────
/// **BLOCKED** (#6581) — see `netCallUnary`'s long comment; server-streaming
/// needs the same `CallInvoker`/generic-method machinery.
pub func netOpenServerStream(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  timeoutMs: in Int,
  metadata: in String,
): Result[GrpcStream, GrpcStatus] {
  Err(
    GrpcStatus(
      code = GrpcStatusCode.Unimplemented,
      message = "gRPC .NET server-streaming calls are blocked on a self-hosted-compiler gap (tracked in #6581)"
    )
  )
}

/// A stream from `netOpenServerStream` never exists on this target, so
/// this is unreachable in practice.
pub func netNextStreamMessage(stream: in GrpcStream): Result[Option[slice[Byte]], GrpcStatus] {
  Err(
    GrpcStatus(
      code = GrpcStatusCode.Unimplemented,
      message = "gRPC .NET server-streaming calls are blocked on a self-hosted-compiler gap (tracked in #6581)"
    )
  )
}

/// A stream from `netOpenServerStream` never exists on this target, so
/// this is unreachable in practice; a real stream-close call is a no-op
/// stub rather than a panic since closing is idempotent and side-effect-
/// free to skip.
pub func netCloseStream(stream: in GrpcStream): Unit {
  ()
}

// ─── Server: hosting ────────────────────────────────────────────────────────────
/// **BLOCKED** (#6581) — independently re-verified against
/// `Grpc.AspNetCore.Server` 2.65.0's real metadata (group:ecosystem-lib-kernels,
/// 2026-09-05; see this module's doc comment for the full chain).
/// `IServiceCollection.AddGrpc()` itself is non-generic and would compile,
/// but every path from there to an actually-dispatchable RPC route needs a
/// MethodSpec-bound generic-method call (`MapGrpcService<TService>`, or the
/// `ServerServiceDefinition.Builder.AddMethod<TRequest,TResponse>` /
/// `ServiceBinderBase.AddMethod<TRequest,TResponse>` pair it wraps — Gap 2
/// from `netCallUnary`'s comment) over a `Method<TRequest,TResponse>` that
/// itself needs a `Marshaller<T>` (Gap 1). No non-generic registration
/// surface exists on this NuGet version. `Grpc.serve` (`grpc.l`) declares
/// this `Unit`-returning and blocking (it is meant to run the server host
/// forever) — there is no `Result` in its signature to fail into, so a
/// real implementation would only ever fail via an unhandled .NET
/// exception anyway; `panic` matches that contract honestly rather than
/// silently returning as if a server were actually running.
pub func serve(
  host: in String,
  port: in Int,
  reflectionEnabled: in Bool,
  maxConnectionIdleMs: in Int,
  registry: in ServiceRegistry,
): Unit {
  panic("gRPC .NET server hosting is blocked on a self-hosted-compiler gap (tracked in #6581)")
}

/// **BLOCKED** (#6581). `Grpc.startHandle` (`grpc.l`) declares
/// this as returning a bare `GrpcServerHandle` (no `Result`) — matching a
/// real implementation's "throws on failure" contract; `panic` is the
/// honest signal here too. `GrpcServerHandle` is `opaque type` owned by
/// `Grpc.Types` with no public constructor exposed to this package, so a
/// dummy success value cannot be fabricated even if this function's
/// signature allowed one.
pub func netStartHandle(
  host: in String,
  port: in Int,
  reflectionEnabled: in Bool,
  maxConnectionIdleMs: in Int,
  registry: in ServiceRegistry,
): GrpcServerHandle {
  panic("gRPC .NET server hosting is blocked on a self-hosted-compiler gap (tracked in #6581)")
}

/// A handle from `netStartHandle` never exists on this target, so this is
/// unreachable in practice.
pub func netStopHandle(handle: in GrpcServerHandle, drainTimeoutMs: in Int): Unit
  requires: drainTimeoutMs >= 0
{
  ()
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

func getOrCreateLimiterPair(method: in String, requestsPerMinute: in Int, burstSize: in Int): RateLimiterPair {
  var existing: RateLimiterPair = default()
  if cdTryGetValue(rateLimiters, method, existing) {
    return existing
  }
  val fresh = RateLimiterPair(
    sustained = Some(value = newSlidingWindowLimiter(60000, requestsPerMinute, 6)),
    burst = Some(value = newSlidingWindowLimiter(1000, burstSize, 1))
  )
  if cdTryAdd(rateLimiters, method, fresh) {
    return fresh
  }
  // Lost the race to another thread creating the same method's entry
  // concurrently; use its winning pair instead of our (now-orphaned) one.
  var winner: RateLimiterPair = default()
  val _ = cdTryGetValue(rateLimiters, method, winner)
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
/// both grant a permit. Real enforcement — does not depend on #6581.
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
