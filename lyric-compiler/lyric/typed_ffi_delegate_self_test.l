//! typed_ffi_delegate_self_test.l — regression test for typed FFI delegate
//! bridging on `@externTarget` functions (Epic #1877/#3923's FFI-boundary
//! slice; see docs/50-ffi-delegates-proposal.md).
//!
//! Before this, an `@externTarget` function's `(A, B) -> R`-typed parameter
//! always erased to the uniform boxed ABI (`System.Func<object,object,object>`)
//! regardless of the real declared types — `typeExprToMsilCtx`'s shared
//! `TFunction` branch (`lyric-compiler/msil/codegen.l`). That mismatches any
//! real BCL method whose delegate parameter has a non-`object` shape — in
//! particular a **value-type** argument (e.g. `CancellationToken`), which
//! cannot be bridged by delegate variance the way reference-type arguments
//! sometimes can. This test targets `System.Net.Http.SocketsHttpHandler`'s
//! real `ConnectCallback` property — `Func<SocketsHttpConnectionContext,
//! CancellationToken, ValueTask<Stream>>` — specifically because
//! `CancellationToken` is a value type and `SocketsHttpConnectionContext` is a
//! plain (non-generic-declaring-type) reference type, pinning exactly the
//! shape the erasure bug corrupted and Predicate/Comparison special-casing
//! never covered.
//!
//! Run via native `lyric test` (compiled in-process through the self-hosted
//! `Msil.Bridge`, `--target dotnet`); imports only `Std.*`, no
//! `LYRIC_LOAD_COMPILER=1` needed.
@test_module
package Lyric.TypedFfiDelegateSelfTest

import Std.Core
import Std.Task
import Std.Testing

extern type Socket = "System.Net.Sockets.Socket"

extern type SocketAddressFamily = "System.Net.Sockets.AddressFamily"

extern type SocketKind = "System.Net.Sockets.SocketType"

extern type SocketProtocolType = "System.Net.Sockets.ProtocolType"

extern type NetworkStream = "System.Net.Sockets.NetworkStream"

extern type UnixDomainSocketEndPoint = "System.Net.Sockets.UnixDomainSocketEndPoint"

extern type SocketsHttpHandler = "System.Net.Http.SocketsHttpHandler"

extern type SocketsHttpConnectionContext = "System.Net.Http.SocketsHttpConnectionContext"

extern type ValueTaskOfStream = "System.Threading.Tasks.ValueTask`1[System.IO.Stream]"

@externTarget("System.Net.Sockets.AddressFamily.Unix")
func addressFamilyUnix(): SocketAddressFamily = ()

@externTarget("System.Net.Sockets.SocketType.Stream")
func socketKindStream(): SocketKind = ()

@externTarget("System.Net.Sockets.ProtocolType.Unspecified")
func protocolTypeUnspecified(): SocketProtocolType = ()

@externTarget("System.Net.Sockets.Socket..ctor")
func newSocket(family: in SocketAddressFamily, kind: in SocketKind, protocolType: in SocketProtocolType): Socket = ()

@externTarget("System.Net.Sockets.UnixDomainSocketEndPoint..ctor")
func newUnixDomainSocketEndPoint(path: in String): UnixDomainSocketEndPoint = ()

@externTarget("System.Net.Sockets.Socket.Connect")
func socketConnect(s: in Socket, endpoint: in UnixDomainSocketEndPoint): Unit = ()

@externTarget("System.Net.Sockets.NetworkStream..ctor")
func newNetworkStream(s: in Socket, ownsSocket: in Bool): NetworkStream = ()

@externTarget("System.Threading.Tasks.ValueTask`1..ctor")
func newValueTaskOfStream(stream: in NetworkStream): ValueTaskOfStream = ()

@externTarget("System.Net.Http.SocketsHttpHandler..ctor")
func newSocketsHandler(): SocketsHttpHandler = ()

@externInstance
@externTarget("System.Net.Http.SocketsHttpHandler.set_ConnectCallback")
func socketsSetConnectCallback(
  h: in SocketsHttpHandler,
  cb: in (SocketsHttpConnectionContext, CancellationToken) -> ValueTaskOfStream,
): Unit = ()

test "a lambda closing over a value binds to a real closed Func<RefType, ValueType, ValueType> BCL delegate parameter" {
  val socketPath = "/tmp/lyric_typed_ffi_delegate_self_test.sock"
  val handler = newSocketsHandler()
  socketsSetConnectCallback(
    handler,
    { context: SocketsHttpConnectionContext, ct: CancellationToken ->
      val socket = newSocket(addressFamilyUnix(), socketKindStream(), protocolTypeUnspecified())
      try {
        socketConnect(socket, newUnixDomainSocketEndPoint(socketPath))
        newValueTaskOfStream(newNetworkStream(socket, true))
      } catch Bug as b {
        panic(b.message)
      }
    }
  )
  // Reaching here without a build-time signature-verification failure or a
  // runtime `MissingMethodException`/`InvalidCastException` on the setter
  // call above is the test: the delegate constructed above must be exactly
  // `Func<SocketsHttpConnectionContext, CancellationToken, ValueTask<Stream>>`
  // (real closed types throughout, no `object` erasure) to bind to the real
  // BCL property setter at all.
  assertTrue(true, "typed delegate bound to the real SocketsHttpHandler.ConnectCallback setter")
}

// #5319: the test above never actually *invokes* the constructed delegate —
// the socket-connect logic is dead code from the test's perspective, so the
// runtime argument-marshaling path (the `pi >= lambdaExternParamTys.count`
// `boxedParamTypes`-skip logic in `lowerFuncMsil`, and the real
// `System.Func<...>.Invoke` call) is never exercised by any assertion.
// `ConcurrentDictionary<TKey,TValue>.GetOrAdd(TKey, Func<TKey,TValue>)`
// invokes its `valueFactory` synchronously (the key is absent), so the
// lambda's return value is observable directly through the dictionary read
// — a small, targeted, real-BCL-entry-point exercise of the single-arg
// `Func<String, Int>` typed-delegate invocation path.
extern type ConcurrentDictOfStringInt = "System.Collections.Concurrent.ConcurrentDictionary`2[System.String,System.Int32]"

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2..ctor")
func newConcurrentDictOfStringInt(): ConcurrentDictOfStringInt = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.GetOrAdd")
@externInstance
func concurrentDictGetOrAdd(
  d: in ConcurrentDictOfStringInt, key: in String, valueFactory: in (String) -> Int
): Int = ()

test "a Func<String,Int> typed delegate is actually invoked through ConcurrentDictionary.GetOrAdd" {
  val d = newConcurrentDictOfStringInt()
  val result = concurrentDictGetOrAdd(d, "answer", { k: String -> k.length + 38 })
  assertEqualInt(result, 44, "GetOrAdd invokes the missing-key valueFactory: \"answer\".length (6) + 38 == 44")
}

// #5315: no test exercises the parallel void-returning `Action`N-typed`
// codegen path (`buildActionNTypedCtorTok`/`buildActionNTypedTypeSpec`) —
// distinct new codegen from the `Func`N-typed` path above, not merely a
// structural analogy. `List<T>.ForEach(Action<T>)` invokes its action once
// per element with real side effects observable after the call returns.
extern type IntList = "System.Collections.Generic.List`1[System.Int32]"

@externTarget("System.Collections.Generic.List`1..ctor")
func newIntList(): IntList = ()

@externTarget("System.Collections.Generic.List`1.Add")
@externInstance
func intListAdd(l: in IntList, v: in Int): Unit = ()

@externTarget("System.Collections.Generic.List`1.ForEach")
@externInstance
func intListForEach(l: in IntList, action: in (Int) -> Unit): Unit = ()

test "a void-returning Action<Int> typed delegate is actually invoked through List.ForEach" {
  val l = newIntList()
  intListAdd(l, 1)
  intListAdd(l, 2)
  intListAdd(l, 3)
  var sum = 0
  intListForEach(l, { x: Int -> sum = sum + x })
  assertEqualInt(sum, 6, "ForEach(Action<Int>) invokes the callback once per element, accumulating 1+2+3 == 6")
}

// #5312: no test exercises the zero-arg `() -> T` @externTarget delegate
// fix (#5309) — the trigger that used to be nested under an
// `inner.count > 0` gate meant for a different, pre-existing map.
// `System.Threading.ThreadLocal<T>(Func<T> valueFactory)` invokes its
// factory lazily on first `.Value` read, giving a real, observable
// zero-arg `Func<T>` invocation.
extern type ThreadLocalOfString = "System.Threading.ThreadLocal`1[System.String]"

@externTarget("System.Threading.ThreadLocal`1..ctor")
func newThreadLocalOfString(valueFactory: in () -> String): ThreadLocalOfString = ()

@externTarget("System.Threading.ThreadLocal`1.get_Value")
@externInstance
func threadLocalOfStringValue(t: in ThreadLocalOfString): String = ()

test "a zero-arg () -> T typed delegate is actually invoked through ThreadLocal<T>.Value (#5309)" {
  val t = newThreadLocalOfString({ -> "computed-" + "value" })
  val result = threadLocalOfStringValue(t)
  assertEqual(result, "computed-value", "ThreadLocal<T>.Value lazily invokes the zero-arg () -> T factory")
}
