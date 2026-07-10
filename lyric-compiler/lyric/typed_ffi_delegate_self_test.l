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

// #5319/#5315/#5312: an attempt was made to add tests here that actually
// *invoke* a constructed typed delegate (a Func<String,Int> via
// ConcurrentDictionary.GetOrAdd, a void Action<Int> via List.ForEach, and a
// zero-arg () -> T via ThreadLocal<T>.Value / Array.ForEach). All of them
// hit the SAME real runtime bug, independent of which BCL API was used:
// pairing ANY generic-type receiver (ConcurrentDictionary`2, List`1,
// ThreadLocal`1 — including the already-battle-tested `Std.Collections`
// `List[T]`) with a method that also carries a typed Func/Action delegate
// parameter corrupts the receiver's own TypeRef resolution. The resulting
// assembly throws `System.TypeLoadException: Could not load type
// 'System.Collections.Generic.List`1' from assembly
// '<ThisTestModule>'` at runtime — the receiver's TypeRef ends up pointing
// at the CURRENT assembly instead of the BCL one it actually lives in.
// Minimal repro (isolated, no delegate-erasure interaction otherwise):
//
//   extern type MyListOf[T] = "System.Collections.Generic.List`1"
//   @externTarget("System.Collections.Generic.List`1..ctor")
//   func newMyList(): MyListOf[Int] = ()
//   @externTarget("System.Collections.Generic.List`1.ForEach")
//   @externInstance
//   func myListForEach(l: in MyListOf[Int], action: in (Int) -> Unit): Unit = ()
//   // newMyList()/myListAdd() alone (no delegate param) work fine; adding
//   // myListForEach to the same compilation unit breaks List`1's own
//   // TypeRef, even though List`1 is never redeclared or touched by
//   // myListForEach's delegate-erasure logic itself.
//
// A separate attempt using a non-generic TYPE but a generic STATIC METHOD
// (`System.Array.ForEach(int[], Action<int>)`) hit a different but equally
// real failure: `MissingMethodException: Void
// System.Array.ForEach(Int32[], System.Action`1<Int32>)` — generic-method
// (as opposed to generic-type) delegate parameters are also unresolved.
// Filed as a real bug (not a test-authoring mistake — reproduced from
// scratch in complete isolation, with and without reusing the pre-existing
// `Std.CollectionsHost` `List[T]` declaration) rather than shipped as a
// failing/skipped test. No BCL API combining an invokable Func/Action
// delegate parameter with a non-generic receiver AND a non-generic method
// was found to substitute, so this file's original single test (which only
// exercises the delegate CONSTRUCTION/BINDING half, not invocation) is left
// unchanged; see the outer task report for full repro details.
