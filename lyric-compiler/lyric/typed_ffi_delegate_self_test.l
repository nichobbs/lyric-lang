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

// #5319/#5315/#5312/#5525/#5800: the delegate is now also INVOKED, through
// generic BCL receivers (`List<T>`, `ConcurrentDictionary<K,V>`) and through
// named (non-`Func`/`Action`) delegate types; see the tests below.  A member of
// a generic BCL type is called through the `<object,...>` erased TypeSpec, so
// the delegate it receives must be `Action<object>`/`Func<object,object>` at
// every position the BCL signature spells `!N`; the lambda unboxes its own
// arguments.  Positions the BCL signature fixes (`Comparison<T>` returns `int`)
// keep their real type.
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

// ---------------------------------------------------------------------------
// #5525/#5800: a generic BCL receiver paired with a typed delegate parameter.
extern type ListOf[T] = "System.Collections.Generic.List`1"

extern type DictOf[K, V] = "System.Collections.Concurrent.ConcurrentDictionary`2"

@externTarget("System.Collections.Generic.List`1..ctor")
func newListOf[T](): ListOf[T] = ()

@externInstance
@externTarget("System.Collections.Generic.List`1.Add")
func listOfAdd[T](l: in ListOf[T], item: in T): Unit = ()

@externInstance
@externTarget("System.Collections.Generic.List`1.get_Count")
func listOfCount[T](l: in ListOf[T]): Int = ()

@externInstance
@externTarget("System.Collections.Generic.List`1.ForEach")
func listOfForEach[T](l: in ListOf[T], action: in (T) -> Unit): Unit = ()

@externInstance
@externTarget("System.Collections.Generic.List`1.Exists")
func listOfExists[T](l: in ListOf[T], pred: in (T) -> Bool): Bool = ()

@externInstance
@externTarget("System.Collections.Generic.List`1.RemoveAll")
func listOfRemoveAll[T](l: in ListOf[T], pred: in (T) -> Bool): Int = ()

@externInstance
@externTarget("System.Collections.Generic.List`1.Sort")
func listOfSort[T](l: in ListOf[T], cmp: in (T, T) -> Int): Unit = ()

@externInstance
@externTarget("System.Collections.Generic.List`1.get_Item")
func listOfGet[T](l: in ListOf[T], index: in Int): T = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2..ctor")
func newDictOf[K, V](): DictOf[K, V] = ()

@externInstance
@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.GetOrAdd")
func dictGetOrAdd[K, V](d: in DictOf[K, V], key: in K, valueFactory: in (K) -> V): V = ()

test "#5525: List<T>.ForEach invokes an Action<T> lambda over a value type" {
  val l = newListOf[Int]()
  listOfAdd(l, 1)
  listOfAdd(l, 2)
  listOfAdd(l, 3)
  var sum = 0
  listOfForEach(l, { x: Int -> sum = sum + x })
  assertEqualInt(sum, 6, "each element reached the lambda unboxed")
}

test "#5525: List<T>.ForEach invokes an Action<T> lambda over a reference type" {
  val l = newListOf[String]()
  listOfAdd(l, "a")
  listOfAdd(l, "bc")
  var total = 0
  listOfForEach(l, { s: String -> total = total + s.length })
  assertEqualInt(total, 3, "each string reached the lambda narrowed to String")
}

test "#5800: ConcurrentDictionary<K,V>.GetOrAdd invokes a Func<K,V> lambda and returns its boxed result" {
  val d = newDictOf[String, Int]()
  val first = dictGetOrAdd(d, "key", { k: String -> k.length * 10 })
  assertEqualInt(first, 30, "factory result is unboxed back to Int")
  val second = dictGetOrAdd(d, "key", { k: String -> 999 })
  assertEqualInt(second, 30, "an existing key does not run the factory again")
}

test "#5947: List<T>.Exists and RemoveAll bind a lambda to the named Predicate<T> delegate" {
  val l = newListOf[Int]()
  listOfAdd(l, 1)
  listOfAdd(l, 2)
  listOfAdd(l, 3)
  listOfAdd(l, 4)
  assertTrue(listOfExists(l, { x: Int -> x == 3 }), "Exists finds 3")
  assertFalse(listOfExists(l, { x: Int -> x == 9 }), "Exists does not find 9")
  val removed = listOfRemoveAll(l, { x: Int -> x % 2 == 0 })
  assertEqualInt(removed, 2, "RemoveAll removed the even elements")
  assertEqualInt(listOfCount(l), 2, "two elements remain")
}

test "#5947: List<T>.Sort binds a lambda to the named Comparison<T> delegate (erased arguments, fixed int result)" {
  val l = newListOf[Int]()
  listOfAdd(l, 3)
  listOfAdd(l, 1)
  listOfAdd(l, 2)
  listOfSort(l, { a: Int, b: Int -> b - a })
  assertEqualInt(listOfGet(l, 0), 3, "descending: first")
  assertEqualInt(listOfGet(l, 1), 2, "descending: second")
  assertEqualInt(listOfGet(l, 2), 1, "descending: third")
}

// ---------------------------------------------------------------------------
// #5947: a delegate type the BCL declares itself, on a non-generic receiver.
extern type Obj = "System.Object"

extern type X509Cert = "System.Security.Cryptography.X509Certificates.X509Certificate"

extern type X509Chain = "System.Security.Cryptography.X509Certificates.X509Chain"

extern type SslPolicyErrors = "System.Net.Security.SslPolicyErrors"

extern type SslClientOptions = "System.Net.Security.SslClientAuthenticationOptions"

extern type Thread = "System.Threading.Thread"

@externTarget("System.Net.Security.SslClientAuthenticationOptions..ctor")
func newSslClientOptions(): SslClientOptions = ()

@externInstance
@externTarget("System.Net.Security.SslClientAuthenticationOptions.set_RemoteCertificateValidationCallback")
func setRemoteCertificateValidationCallback(
  options: in SslClientOptions,
  callback: in (Obj, X509Cert, X509Chain, SslPolicyErrors) -> Bool,
): Unit = ()

@externTarget("System.Object..ctor")
func newObj(): Obj = ()

@externInstance
@externTarget("System.Threading.TimerCallback.Invoke")
func invokeTimerCallback(callback: in (Obj) -> Unit, state: in Obj): Unit = ()

@externTarget("System.Threading.Thread..ctor")
func newThread(start: in () -> Unit): Thread = ()

@externInstance
@externTarget("System.Threading.Thread.Start")
func threadStart(t: in Thread): Unit = ()

@externInstance
@externTarget("System.Threading.Thread.Join")
func threadJoin(t: in Thread): Unit = ()

test "#5947: a lambda binds to a custom delegate-typed property setter (RemoteCertificateValidationCallback)" {
  val options = newSslClientOptions()
  setRemoteCertificateValidationCallback(
    options,
    { sender: Obj, certificate: X509Cert, chain: X509Chain, errors: SslPolicyErrors -> true }
  )
  assertTrue(true, "the setter bound a real RemoteCertificateValidationCallback, not a Func`5")
}

test "#5947: a bridged custom delegate is invoked through its own Invoke and sees its argument" {
  var calls = 0
  val state = newObj()
  invokeTimerCallback({ s: Obj -> calls = calls + 1 }, state)
  assertEqualInt(calls, 1, "the TimerCallback lambda ran once")
}

test "#5947: a zero-argument named delegate (ThreadStart) runs the lambda on another thread" {
  var ran = false
  val t = newThread({ -> ran = true })
  threadStart(t)
  threadJoin(t)
  assertTrue(ran, "the ThreadStart lambda ran")
}
