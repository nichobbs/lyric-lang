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
//! #5315: a second test covers the parallel `Action`N`-typed path
//! (`buildActionNTypedCtorTok`/`buildActionNTypedTypeSpec`) via
//! `System.Threading.Tasks.Task.ContinueWith(Action<Task>)` — `Task` is a
//! non-generic receiver, so it sidesteps #5525 (generic-receiver TypeRef
//! corruption). It is BINDING-only: invoking the bound continuation is a
//! separate, pre-existing gap (D-progress-621 item 3), not asserted here.
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

// #5315: the Action`N-typed path (`buildActionNTypedCtorTok`/
// `buildActionNTypedTypeSpec`), zero coverage until now. `Task` (imported
// from `Std.Task`, already in scope via the `import Std.Task` above) is a
// NON-generic receiver, so this candidate is unaffected by #5525 (the
// generic-RECEIVER TypeRef-corruption bug that blocks List`1/
// ConcurrentDictionary`2/ThreadLocal`1 carriers). `Action<Task>`'s type
// argument (`Task`) is a plain reference type, not `System.Object`, so
// binding it correctly requires the real typed erasure this PR added —
// the pre-existing uniform `Action<object>` ABI would mismatch every
// `Task.ContinueWith` overload and throw `MissingMethodException` at the
// call below.
@externInstance
@externTarget("System.Threading.Tasks.Task.ContinueWith")
func taskContinueWithUnit(t: in Task, action: in (Task) -> Unit): Task = ()

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

test "#5315: a lambda binds to Task.ContinueWith's Action<Task> parameter (non-generic receiver, binding only)" {
  val t = delay(1)
  val continuation = taskContinueWithUnit(t, { finished: Task -> () })
  // This is a BINDING-only test: reaching here without a build-time
  // signature-verification failure or a runtime `MissingMethodException` on
  // the `ContinueWith` call above is the test — the constructed delegate
  // must be exactly `Action<Task>` (not the uniform `Action<object>`) to
  // bind to any `Task.ContinueWith` overload at all. Actually *invoking* the
  // continuation is a separate, already-documented gap (D-progress-621 item
  // 3: closures passed as Action-typed arguments to Task's own APIs never
  // fire on this backend) — out of scope here and not asserted.
  //
  // #5853: until that fix, this test's "PASS" was a false negative — the
  // caller actually constructed `Func`1<Task, object>` here (not
  // `Action<Task>`), a genuine type mismatch that only escaped detection
  // because `ContinueWith` schedules the mismatched delegate for
  // *asynchronous* invocation, and the continuation above is never awaited
  // or observed. The `Action<Int>`-at-receiver test further down (which
  // invokes synchronously) caught it for real. Construction here is now
  // genuinely correct, not just unobserved-broken.
  assertTrue(true, "typed Action<Task> delegate bound to Task.ContinueWith without a signature mismatch")
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
// was found to substitute, so the file's original single test (which only
// exercises the delegate CONSTRUCTION/BINDING half, not invocation) was left
// unchanged for a long time; see the outer task report for full repro
// details.
//
// #5315 follow-up: a BINDING-only test (no invocation) for the Action`N-
// typed path was added above (`Task.ContinueWith(Action<Task>)`) — `Task` is
// a non-generic receiver, so #5525's generic-receiver TypeRef corruption
// does not apply, and the bind call itself succeeds (no
// `MissingMethodException`). Invoking the bound continuation still does not
// work on this backend (a separate, pre-existing gap — D-progress-621 item
// 3 — unrelated to #5525), so invocation remains untested here.
// ---------------------------------------------------------------------------
// D-progress-686: a `ValueTask`1[...]`-shaped `extern type` RETURN value —
// as opposed to the delegate PARAMETER shape the test above covers — was
// also broken, in two separate spots. `newValueTaskOfStream`-style calls
// compile and even pass `ilverify` clean, but crash at runtime the first
// time a caller actually *consumes* the returned value: found migrating
// `UnixSocketHttpClient.cs`'s `ConnectCallback` construction to pure Lyric
// (docs/50), where the callback lambda must construct-and-return a real
// `ValueTask<Stream>`.
//
//   1. `addPackageTokens`'s call-site return-type registry (`cctx.
//      funcRetTypes`, consulted by every CALLER of the extern function) used
//      the same bracket-erasing `typeExprToMsilCtx` as any ordinary function,
//      instead of the `resolveValueTaskGenericMsilType` construction
//      `emitExternTargetBody` already used for the function's own BODY.
//   2. `lowerFuncMsil`'s own return-type computation (what the `.method`
//      SIGNATURE itself declares) had the identical gap — a SEPARATE
//      computation from `addPackageTokens`, so fixing only one left the
//      other still declaring `object`.
//
// With #2 present alone: the METHOD ITSELF is declared to return `object`
// while its body pushes a bare (unboxed) value-type struct and `ret`s —
// invalid at the metadata level, invisible to `ilverify`, surfacing only as
// `System.TypeLoadException: Could not load type 'System.Threading.Tasks.
// ValueTask`1' from assembly '<CurrentAssembly>'` the moment any caller
// invokes the method. Both are fixed in `msil/codegen.l` (D122/docs/50).
//
// A third, independent bug surfaced constructing the `ValueTask`1` argument
// itself: `ValueTask`1` has no implicit-conversion operator (unlike the
// non-generic `ValueTask`) — only THREE constructors, two of which share
// arity 1 (`(TResult result)` vs `(Task<TResult> task)`). `emitGenericExternMember`
// resolved the declaring generic type's member by arity alone, which cannot
// distinguish those two ctors and silently bound whichever came first in the
// Method table; when it picked `.ctor(Task<TResult>)`, the caller's concrete
// (non-Task) argument type leaked into that parameter position instead of
// the real `!0`. Fixed by scoring candidates against the declared Lyric
// argument type first (`Mdr.resolveExternMethodScored`), with `scoreSigType`
// (metadata_reader.l) extended so a `!0`-typed parameter matches any
// concrete argument.
//
// `MemoryStream` (not `NetworkStream`) so this test needs no live socket —
// it exercises the exact "construct and return a `ValueTask`1[...]`-shaped
// extern value" chain that was broken, without any I/O. Calling an INSTANCE
// method on a value-type generic-declaring extern receiver (e.g. `ValueTask
// `1.get_IsCompletedSuccessfully()`) is a separate, out-of-scope gap: the
// receiver arrives `object`-boxed (no parameter-type analog of the return-
// type special-casing above exists yet), so `unbox`/`unbox.any` cannot
// target the right closed instantiation in general. `emitGenericExternMember`
// now declines this shape outright (a clear build-time panic) rather than
// emitting a `castclass` that would compile clean and fault at runtime; not
// exercised here — tracked as follow-up work in #5809.
extern type MemoryStream = "System.IO.MemoryStream"

extern type ValueTaskOfMemStream = "System.Threading.Tasks.ValueTask`1[System.IO.Stream]"

@externTarget("System.IO.MemoryStream..ctor")
func newMemoryStream(): MemoryStream = ()

@externTarget("System.Threading.Tasks.ValueTask`1..ctor")
func newValueTaskOfMemStream(stream: in MemoryStream): ValueTaskOfMemStream = ()

test "constructing and returning a ValueTask`1[...]-shaped extern value does not crash at runtime (D-progress-686)" {
  val vt = newValueTaskOfMemStream(newMemoryStream())
  // Reaching here without a `TypeLoadException` (invalid metadata: erased
  // `object` return / mismatched CLASS-vs-VALUETYPE TypeSpec / a
  // `.ctor(Task<TResult>)` mis-bind that leaked the argument's concrete type
  // into the ctor's `!0` slot) is the test.
  assertTrue(
    true,
    "ValueTask<Stream> constructed via .ctor(TResult), disambiguated from .ctor(Task<TResult>) by argument-type scoring"
  )
}

// #5803: the test above only calls `newValueTaskOfMemStream` from a plain
// function body — it never wraps the ctor-return inside a lambda bound to a
// BCL delegate parameter and then has that delegate actually *invoked*. The
// production shape this migration ships (`hostClientWithUnixSocket*` in
// `http_host.l`) is exactly that combined shape: a closure passed as
// `SocketsHttpHandler.ConnectCallback`, invoked by the BCL itself, whose
// body constructs and returns a `ValueTask`1[...]`-shaped extern value —
// verified only manually against a live `dockerd` (not reproducible in CI)
// because `SocketsHttpHandler` only invokes `ConnectCallback` when a real
// HTTP request actually attempts a connection.
//
// `System.Func`2.Invoke` sidesteps needing real I/O: it lets the TEST
// itself invoke the constructed delegate synchronously (rather than the BCL
// invoking it internally), exercising all three pieces together — typed
// delegate CONSTRUCTION (the lambda binds directly to an `@externTarget`
// function's own `TFunction`-typed parameter, D122), delegate INVOCATION
// (`Func`2.Invoke` is a real `callvirt` through the bound delegate, not a
// direct call to the lambda body), and the `ValueTask`1[...]` ctor-return
// bug from D-progress-686 running INSIDE that invoked body.
//
// `cb` is BOTH the `TFunction`-typed lambda argument AND the `@externInstance`
// receiver for `Func`2.Invoke` — a shape every OTHER typed-delegate test in
// this file avoids (`cb` is always a non-receiver parameter elsewhere, e.g.
// `SocketsHttpHandler.set_ConnectCallback` above). That combination
// previously hit a distinct, now-fixed gap (#5833): the lambda bound to the
// real closed `Func<MemoryStream, ValueTask<Stream>>` correctly, but
// `emitGenericExternMember`'s receiver-loading code built the `castclass`
// target from the bare extern-target string alone (no bracket suffix, not a
// ctor) and fell back to the erased `Func<object,object>` TypeSpec instead
// of reusing the wrapper's own already-resolved real closed parameter type —
// `System.InvalidCastException` at the `Invoke` call site. Fixed by
// extending the same "reuse an already-resolved real closed type instead of
// erasing" mechanism D-progress-686's ctor-return fix introduced to also
// cover an instance call's RECEIVER type (`paramTypes[0]`), plus a follow-on
// fix to the VAR-typed-return unboxing dance (#2972, `AsyncLocal`1.Value`)
// that assumed every generic-member receiver is always object-erased and
// mis-fired `InvalidProgramException` (`brtrue` on a value-type stack slot)
// once the receiver could be a real closed instantiation.
@externInstance
@externTarget("System.Func`2.Invoke")
func invokeMemStreamFunc(cb: in (MemoryStream) -> ValueTaskOfMemStream, arg: in MemoryStream): ValueTaskOfMemStream = ()

test "invoking a Func<MemoryStream, ValueTask<Stream>> delegate runs the ValueTask ctor inside the invoked body (#5803/#5833)" {
  val vt = invokeMemStreamFunc({ s: MemoryStream -> newValueTaskOfMemStream(s) }, newMemoryStream())
  assertTrue(
    true,
    "Func<MemoryStream, ValueTask<Stream>> constructed, actually invoked via Func`2.Invoke (not just constructed/bound), and its body's ValueTask`1..ctor call did not crash"
  )
}

// #5851/#5853: an Action`N-typed receiver-position counterpart to the
// Func`2.Invoke test above — the D-progress-687 receiver-reuse fix's
// void-return branch was untested until now. Attempting exactly this shape
// surfaced a second, distinct bug (#5853, fixed alongside), unrelated to
// D-progress-687's receiver-reuse mechanism itself (which is correct):
//
//   1. Caller-side ctorTok selection: a `Unit`-returning delegate-bridged
//      lambda always built `Func`N<...,object>` instead of `Action`N<...>`,
//      because it read `funcRetTypes[lambdaKey]` (ALWAYS `MObject` for every
//      lambda under the Uniform Func ABI — `collectLambdasBfsExpr`
//      unconditionally synthesizes `ret = Some(Object)`) instead of
//      `lambdaExternDelegateRetType[lambdaKey]` (the real declared delegate
//      return type, correctly `MVoid` here). The existing `Task.ContinueWith`
//      test below happened to keep "passing" despite this — it never
//      observes the mismatch because `ContinueWith` invokes the delegate
//      asynchronously and the continuation is never awaited.
//   2. Argument marshaling: once (1) is fixed and the receiver TypeSpec is a
//      real closed `Action`1<Int32>` instantiation (not the erased
//      `<object>` default), `emitGenericExternMember`'s argument-loading
//      loop still unconditionally boxed the value-type argument for a
//      `!0`-typed BCL parameter position — correct only when the TypeSpec
//      is erased (an `Int32` argument going into a still-`<object>` slot),
//      but wrong once the slot is genuinely `Int32`: pushing a boxed
//      `object` there is a stack-type mismatch, `InvalidProgramException`
//      at load time. Not caught by the Func`2.Invoke test above because
//      `MemoryStream` is a reference type — boxing never applied there.
//
// Both are gated on the same `objArgsErased` flag D-progress-687 introduced
// for the VAR-typed-return unboxing dance, extended to this argument-boxing
// site too.
@externInstance
@externTarget("System.Action`1.Invoke")
func invokeActionOfInt(cb: in (Int) -> Unit, arg: Int): Unit = ()

test "invoking an Action<Int> delegate at the receiver position works (#5851/#5853)" {
  invokeActionOfInt({ x: Int -> () }, 42)
  assertTrue(
    true,
    "Action<Int> constructed as a real closed Action`1<Int32> (not the erased Func`2<Int32,object>), invoked via Action`1.Invoke at the receiver position, and the value-type argument was passed unboxed to match the closed instantiation's !0 slot without crashing"
  )
}
