//! std/_kernel/http_host.l - host boundary for HTTP.
//!
//! This file is the audited extern boundary for `Std.Http`.  Every
//! host-facing function below is either:
//!
//!   * a direct `@externTarget` to a single BCL method / property /
//!     constructor (the trivial pass-through case), or
//!   * a native Lyric helper that composes a sequence of those
//!     primitives (the multi-step orchestration case — `hostMakeRequest`,
//!     `hostWithStringBody`, etc.).
//!
//! G12 (`docs/23-fsharp-shim-elimination.md` §5; D-progress-NNN):
//! the F# `Lyric.Stdlib.HttpClientHost` shim retires entirely.
@axiom("System.Net.Http operations conform to their documented .NET contracts")
package Std.HttpHost

import Std.Core
import Std.Task

// =====================================================================
// Extern types — BCL classes the helpers below reference.  Each one
// is the host-side type for a value that flows through Std.Http but
// stays opaque from the user's perspective.
// =====================================================================
extern type HttpClientHandle = "System.Net.Http.HttpClient"

extern type HttpClientHandler = "System.Net.Http.HttpClientHandler"

extern type HttpRequestMessage = "System.Net.Http.HttpRequestMessage"

extern type HttpResponseMessage = "System.Net.Http.HttpResponseMessage"

extern type HttpContent = "System.Net.Http.HttpContent"

extern type StringContent = "System.Net.Http.StringContent"

// `BclHttpMethod` rather than `HttpMethod` because `Std.Http`
// declares its own user-facing `pub enum HttpMethod { Get, Post, … }`
// and would shadow this extern.
extern type BclHttpMethod = "System.Net.Http.HttpMethod"

extern type HttpHeaders = "System.Net.Http.Headers.HttpHeaders"

extern type Encoding = "System.Text.Encoding"

extern type SocketsHttpHandler = "System.Net.Http.SocketsHttpHandler"

extern type UnixDomainSocketEndPoint = "System.Net.Sockets.UnixDomainSocketEndPoint"

extern type Socket = "System.Net.Sockets.Socket"

extern type SocketAddressFamily = "System.Net.Sockets.AddressFamily"

extern type SocketKind = "System.Net.Sockets.SocketType"

extern type SocketProtocolType = "System.Net.Sockets.ProtocolType"

extern type NetworkStream = "System.Net.Sockets.NetworkStream"

extern type SocketsHttpConnectionContext = "System.Net.Http.SocketsHttpConnectionContext"

extern type ValueTaskOfStream = "System.Threading.Tasks.ValueTask`1[System.IO.Stream]"

// =====================================================================
// Primitive externs (private to this kernel file).  These bind the
// individual BCL members; the public `host*` helpers compose them.
// =====================================================================
@externTarget("System.Text.Encoding.UTF8")
func utf8(): Encoding = ()

@externTarget("System.Net.Http.HttpMethod..ctor")
func newHttpMethod(name: in String): BclHttpMethod = ()

@externTarget("System.Net.Http.HttpRequestMessage..ctor")
func newRequest(method: in BclHttpMethod, url: in String): HttpRequestMessage = ()

@externInstance
@externTarget("System.Net.Http.HttpRequestMessage.Headers")
func requestHeaders(req: in HttpRequestMessage): HttpHeaders = ()

@externInstance
@externTarget("System.Net.Http.Headers.HttpHeaders.TryAddWithoutValidation")
func headersTryAdd(h: in HttpHeaders, name: in String, value: in String): Bool = ()

@externTarget("System.Net.Http.StringContent..ctor")
func newStringContent(body: in String, encoding: in Encoding, mediaType: in String): StringContent = ()

@externInstance
@externTarget("System.Net.Http.HttpRequestMessage.set_Content")
func setRequestContent(req: in HttpRequestMessage, content: in StringContent): Unit = ()

@externTarget("System.Net.Http.HttpClient..ctor")
func newClient(): HttpClientHandle = ()

@externTarget("System.Net.Http.HttpClient..ctor")
func newClientFromHandler(handler: in HttpClientHandler): HttpClientHandle = ()

@externTarget("System.Net.Http.HttpClientHandler..ctor")
func newHandler(): HttpClientHandler = ()

@externInstance
@externTarget("System.Net.Http.HttpClientHandler.set_AllowAutoRedirect")
func setAllowAutoRedirect(h: in HttpClientHandler, v: in Bool): Unit = ()

@externInstance
@externTarget("System.Net.Http.HttpClientHandler.set_MaxAutomaticRedirections")
func setMaxAutomaticRedirections(h: in HttpClientHandler, n: in Int): Unit = ()

@externTarget("System.Net.Sockets.UnixDomainSocketEndPoint..ctor")
func newUnixDomainSocketEndPoint(path: in String): UnixDomainSocketEndPoint = ()

@externTarget("System.Net.Http.SocketsHttpHandler..ctor")
func newSocketsHandler(): SocketsHttpHandler = ()

@externInstance
@externTarget("System.Net.Http.SocketsHttpHandler.set_AllowAutoRedirect")
func socketsSetAllowAutoRedirect(h: in SocketsHttpHandler, v: in Bool): Unit = ()

@externInstance
@externTarget("System.Net.Http.SocketsHttpHandler.set_MaxAutomaticRedirections")
func socketsSetMaxAutomaticRedirections(h: in SocketsHttpHandler, n: in Int): Unit = ()

@externTarget("System.Net.Http.HttpClient..ctor")
func newClientFromSocketsHandler(handler: in SocketsHttpHandler): HttpClientHandle = ()

@externTarget("System.Net.Sockets.AddressFamily.Unix")
func addressFamilyUnix(): SocketAddressFamily = ()

@externTarget("System.Net.Sockets.SocketType.Stream")
func socketKindStream(): SocketKind = ()

@externTarget("System.Net.Sockets.ProtocolType.Unspecified")
func protocolTypeUnspecified(): SocketProtocolType = ()

@externTarget("System.Net.Sockets.Socket..ctor")
func newSocket(family: in SocketAddressFamily, kind: in SocketKind, protocolType: in SocketProtocolType): Socket = ()

@externInstance
@externTarget("System.Net.Sockets.Socket.Connect")
func socketConnect(s: in Socket, endpoint: in UnixDomainSocketEndPoint): Unit = ()

@externInstance
@externTarget("System.Net.Sockets.Socket.Dispose")
func socketDispose(s: in Socket): Unit = ()

@externTarget("System.Net.Sockets.NetworkStream..ctor")
func newNetworkStream(s: in Socket, ownsSocket: in Bool): NetworkStream = ()

// `ValueTask`1` has no implicit-conversion operator — the C# compiler's
// `return value;` sugar inside an `async ValueTask<T>` method lowers directly
// to `newobj ValueTask`1::.ctor(!0)`, not an `op_Implicit` call (there isn't
// one on this type; only `ValueTask`, the non-generic sibling, defines
// `FromResult`/no implicit operators either). `ValueTask`1` has THREE
// constructors — `(TResult result)`, `(Task<TResult> task)`, and
// `(IValueTaskSource<TResult>, short)` — so arity-only `@externTarget`
// resolution alone cannot tell the first two apart (compiler W0008). The
// metadata-direct resolver now scores candidates against the declared Lyric
// argument type, and a `!0`-typed parameter position scores as a match for
// any concrete argument (`scoreSigType`'s `STVar` arm, metadata_reader.l),
// which correctly picks `.ctor(TResult)` over `.ctor(Task<TResult>)` for a
// `NetworkStream` argument (#5797).
@externTarget("System.Threading.Tasks.ValueTask`1..ctor")
func newValueTaskOfStream(stream: in NetworkStream): ValueTaskOfStream = ()

@externInstance
@externTarget("System.Net.Http.SocketsHttpHandler.set_ConnectCallback")
func socketsSetConnectCallback(
  h: in SocketsHttpHandler,
  cb: in (SocketsHttpConnectionContext, CancellationToken) -> ValueTaskOfStream,
): Unit = ()

// Opens a raw Unix domain socket connected to `socketPath` and wraps it in a
// `NetworkStream`, disposing the socket (not just leaking the handle) if the
// connect itself fails.  Local Unix-socket connects (Docker, systemd, …) are
// effectively instantaneous, so this dials synchronously rather than binding
// `Socket.ConnectAsync`/honouring the delegate's `CancellationToken` — unlike
// the network-facing async connect the retired `UnixSocketHttpClient.cs` used,
// there is no meaningful wait to cancel here.
func connectUnixSocket(socketPath: in String): NetworkStream {
  val socket = newSocket(addressFamilyUnix(), socketKindStream(), protocolTypeUnspecified())
  try {
    socketConnect(socket, newUnixDomainSocketEndPoint(socketPath))
    newNetworkStream(socket, true)
  } catch Bug as b {
    socketDispose(socket)
    panic(b.message)
  }
}

@externInstance
@externTarget("System.Net.Http.HttpClient.SendAsync")
async func clientSendAsync(client: in HttpClientHandle, request: in HttpRequestMessage): HttpResponseMessage = ()

@externInstance
@externTarget("System.Net.Http.HttpClient.SendAsync")
async func clientSendAsyncCancel(
  client: in HttpClientHandle,
  request: in HttpRequestMessage,
  token: in CancellationToken,
): HttpResponseMessage = ()

@externInstance
@externTarget("System.Net.Http.HttpClient.GetAsync")
async func clientGetAsync(client: in HttpClientHandle, url: in String): HttpResponseMessage = ()

@externInstance
@externTarget("System.Net.Http.HttpClient.GetAsync")
async func clientGetAsyncCancel(
  client: in HttpClientHandle, url: in String, token: in CancellationToken
): HttpResponseMessage = ()

@externInstance
@externTarget("System.Net.Http.HttpClient.PostAsync")
async func clientPostAsync(client: in HttpClientHandle, url: in String, content: in StringContent): HttpResponseMessage = ()

@externInstance
@externTarget("System.Net.Http.HttpClient.PostAsync")
async func clientPostAsyncCancel(
  client: in HttpClientHandle,
  url: in String,
  content: in StringContent,
  token: in CancellationToken,
): HttpResponseMessage = ()

@externInstance
@externTarget("System.Net.Http.HttpResponseMessage.StatusCode")
func responseStatusInt(response: in HttpResponseMessage): Int = ()

@externInstance
@externTarget("System.Net.Http.HttpResponseMessage.Content")
func responseContent(response: in HttpResponseMessage): HttpContent = ()

@externInstance
@externTarget("System.Net.Http.HttpContent.ReadAsStringAsync")
async func contentReadAsString(c: in HttpContent): String = ()

@externInstance
@externTarget("System.Net.Http.HttpContent.ReadAsStringAsync")
async func contentReadAsStringCancel(c: in HttpContent, token: in CancellationToken): String = ()

@externInstance
@externTarget("System.Net.Http.HttpContent.ReadAsByteArrayAsync")
async func contentReadAsBytes(c: in HttpContent): slice[Byte] = ()

@externInstance
@externTarget("System.Net.Http.HttpContent.ReadAsByteArrayAsync")
async func contentReadAsBytesCancel(c: in HttpContent, token: in CancellationToken): slice[Byte] = ()

// =====================================================================
// Public host helpers — the names `Std.Http` resolves through
// `import Std.HttpHost as HostHttp`.  Each is either a thin alias or
// a multi-step composition that wraps the primitives above.
// =====================================================================
// #333: process-wide HttpClientHandle singleton — initialised once in the package `.cctor`,
// reused on every request.  Per-call construction exhausts the TCP socket pool
// (sockets stay in TIME_WAIT for two MSL after GC).
// Named `processClient` (not `defaultClient`) to avoid a name-resolution clash with
// the `Std.Http.defaultClient()` factory function when both packages are compiled together.
val processClient: HttpClientHandle = newClient()

pub func hostDefaultClient(): HttpClientHandle {
  processClient
}

pub func hostMakeRequest(httpMethod: in String, url: in String): HttpRequestMessage {
  newRequest(newHttpMethod(httpMethod), url)
}

pub func hostWithHeader(request: in HttpRequestMessage, key: in String, value: in String): HttpRequestMessage {
  val _ = headersTryAdd(requestHeaders(request), key, value)
  request
}

pub func hostWithStringBody(request: in HttpRequestMessage, contentType: in String, body: in String): HttpRequestMessage {
  setRequestContent(request, newStringContent(body, utf8(), contentType))
  request
}

pub func hostStatusCode(response: in HttpResponseMessage): Int {
  responseStatusInt(response)
}

pub func hostClientWithRedirects(maxRedirects: in Int): HttpClientHandle {
  val handler = newHandler()
  setAllowAutoRedirect(handler, true)
  setMaxAutomaticRedirections(handler, maxRedirects)
  newClientFromHandler(handler)
}

pub func hostClientNoRedirects(): HttpClientHandle {
  val handler = newHandler()
  setAllowAutoRedirect(handler, false)
  newClientFromHandler(handler)
}

// ---------------------------------------------------------------------------
// Unix domain socket support for local protocol access (Docker, systemd, etc).
// Native Lyric via a `SocketsHttpHandler.ConnectCallback` typed-delegate
// binding (D122/docs/50-ffi-delegates-proposal.md) — no host-assembly
// dependency, unlike the retired `Lyric.Cli.Aot.UnixSocketHttpClient` this
// replaced (D-progress-609/684; docs/59-compiler-stdlib-deep-review.md §7.3).
// ---------------------------------------------------------------------------
pub func hostClientWithUnixSocket(socketPath: in String): HttpClientHandle {
  val handler = newSocketsHandler()
  socketsSetConnectCallback(
    handler,
    { context: SocketsHttpConnectionContext, ct: CancellationToken ->
      newValueTaskOfStream(connectUnixSocket(socketPath))
    }
  )
  newClientFromSocketsHandler(handler)
}

pub func hostClientWithUnixSocketAndRedirects(socketPath: in String, maxRedirects: in Int): HttpClientHandle {
  val handler = newSocketsHandler()
  socketsSetConnectCallback(
    handler,
    { context: SocketsHttpConnectionContext, ct: CancellationToken ->
      newValueTaskOfStream(connectUnixSocket(socketPath))
    }
  )
  socketsSetAllowAutoRedirect(handler, true)
  socketsSetMaxAutomaticRedirections(handler, maxRedirects)
  newClientFromSocketsHandler(handler)
}

pub func hostClientWithUnixSocketNoRedirects(socketPath: in String): HttpClientHandle {
  val handler = newSocketsHandler()
  socketsSetConnectCallback(
    handler,
    { context: SocketsHttpConnectionContext, ct: CancellationToken ->
      newValueTaskOfStream(connectUnixSocket(socketPath))
    }
  )
  socketsSetAllowAutoRedirect(handler, false)
  newClientFromSocketsHandler(handler)
}

// `ResponseHeader` (#5568): native Lyric over `HttpHeaders.Contains` +
// `HttpHeaders.GetValues`, plus a NON-GENERIC `System.Collections.IEnumerator`
// walk to take the first value.  The previous shape —
// `HttpHeaders.TryGetValues(name, out IEnumerable<string>)` — was an instance
// extern with a generic-typed `out` parameter: the emitted MemberRef was
// unbindable, so every `HttpResponse.header` call faulted at run time with
// MissingMethodException.  `Contains` guards `GetValues`, so the
// absent-header case never rides on exception control flow; the value walk
// goes through the non-generic `IEnumerable` slot (which
// `IEnumerable<string>` always implements), so no MemberRef in this chain
// mentions a generic parameter in an argument position.  The BCL splits
// headers across `response.Headers` (general + caller-set) and
// `response.Content.Headers` (Content-Type, Content-Length, …) — try the
// former first, then fall through to the latter, then `""`.
extern type HttpResponseHeaders = "System.Net.Http.Headers.HttpResponseHeaders"

extern type HttpContentHeaders = "System.Net.Http.Headers.HttpContentHeaders"

extern type IEnumerableStr = "System.Collections.Generic.IEnumerable`1[System.String]"

extern type NonGenericEnumerator = "System.Collections.IEnumerator"

@externInstance
@externTarget("System.Net.Http.HttpResponseMessage.Headers")
func responseHeadersOf(r: in HttpResponseMessage): HttpResponseHeaders = ()

@externInstance
@externTarget("System.Net.Http.HttpContent.Headers")
func contentHeadersOf(c: in HttpContent): HttpContentHeaders = ()

@externInstance
@externTarget("System.Net.Http.Headers.HttpHeaders.Contains")
func responseHeadersContain(h: in HttpResponseHeaders, name: in String): Bool = ()

@externInstance
@externTarget("System.Net.Http.Headers.HttpHeaders.Contains")
func contentHeadersContain(h: in HttpContentHeaders, name: in String): Bool = ()

@externInstance
@externTarget("System.Net.Http.Headers.HttpHeaders.GetValues")
func responseHeaderValues(h: in HttpResponseHeaders, name: in String): IEnumerableStr = ()

@externInstance
@externTarget("System.Net.Http.Headers.HttpHeaders.GetValues")
func contentHeaderValues(h: in HttpContentHeaders, name: in String): IEnumerableStr = ()

@externInstance
@externTarget("System.Collections.IEnumerable.GetEnumerator")
func headerValuesEnumerator(values: in IEnumerableStr): NonGenericEnumerator = ()

@externInstance
@externTarget("System.Collections.IEnumerator.MoveNext")
func enumeratorMoveNext(e: in NonGenericEnumerator): Bool = ()

@externInstance
@externTarget("System.Collections.IEnumerator.Current")
func enumeratorCurrent(e: in NonGenericEnumerator): String = ()

// First element of `values`, or `""` when the sequence is empty.
func firstHeaderValue(values: in IEnumerableStr): String {
  val e = headerValuesEnumerator(values)
  if enumeratorMoveNext(e) {
    enumeratorCurrent(e)
  } else {
    ""
  }
}

pub func hostResponseHeader(response: in HttpResponseMessage, name: in String): String {
  // Each leg is exception-mapped SEPARATELY: `Contains` throws
  // InvalidOperationException for a known header of the other category
  // (`response.Headers.Contains("Content-Type")` — the strict category
  // check that motivated the BCL's TryGetValues) and FormatException for a
  // syntactically invalid name, so a throwing response-leg lookup must
  // still fall through to the content leg rather than aborting the whole
  // read.
  val fromResponse = try {
    val respHeaders = responseHeadersOf(response)
    if responseHeadersContain(respHeaders, name) {
      firstHeaderValue(responseHeaderValues(respHeaders, name))
    } else {
      ""
    }
  } catch Bug as _ {
    ""
  }
  if fromResponse.length > 0 {
    return fromResponse
  }
  return try {
    val contentHeaders = contentHeadersOf(responseContent(response))
    if contentHeadersContain(contentHeaders, name) {
      firstHeaderValue(contentHeaderValues(contentHeaders, name))
    } else {
      ""
    }
  } catch Bug as _ {
    ""
  }
}

// ---------------------------------------------------------------------------
// V0012-safe wrappers — issue #2985.
//
// The self-hosted MSIL emitter cannot emit SM resume labels inside CLR
// protected regions (try/catch/finally): the JIT rejects branches INTO a
// protected region (#2737).  Std.Http keeps its awaits OUTSIDE try blocks
// for exactly this reason.
//
// The wrappers below are safe despite using await-in-try because every
// awaited callee (`clientSendAsync`, `clientGetAsync`, etc.) is declared
// `@externTarget async func` with return type T (not Task<T>).  The MSIL
// emitter's `isTaskTypeMsil` check therefore returns false for every EAwait
// in these bodies: Phase A counts zero SM resume points, Phase B emits no
// SM resume labels, and the `try` block compiles as ordinary (non-SM) IL
// — no label ever lands inside a CLR protected region.
// ---------------------------------------------------------------------------
pub async func hostSendSafe(
  client: in HttpClientHandle, request: in HttpRequestMessage
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await clientSendAsync(client, request))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostGetSafe(client: in HttpClientHandle, url: in String): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await clientGetAsync(client, url))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostPostStringSafe(
  client: in HttpClientHandle, url: in String, body: in String, contentType: in String
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await clientPostAsync(client, url, newStringContent(body, utf8(), contentType)))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyTextSafe(response: in HttpResponseMessage): Result[String, String] {
  return try {
    Ok(value = await contentReadAsString(responseContent(response)))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyBytesSafe(response: in HttpResponseMessage): Result[slice[Byte], String] {
  return try {
    Ok(value = await contentReadAsBytes(responseContent(response)))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostSendWithCancelSafe(
  client: in HttpClientHandle,
  request: in HttpRequestMessage,
  token: in CancellationToken,
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await clientSendAsyncCancel(client, request, token))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostGetWithCancelSafe(
  client: in HttpClientHandle, url: in String, token: in CancellationToken
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await clientGetAsyncCancel(client, url, token))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostPostStringWithCancelSafe(
  client: in HttpClientHandle,
  url: in String,
  body: in String,
  contentType: in String,
  token: in CancellationToken,
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await clientPostAsyncCancel(client, url, newStringContent(body, utf8(), contentType), token))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyTextWithCancelSafe(
  response: in HttpResponseMessage, token: in CancellationToken
): Result[String, String] {
  return try {
    Ok(value = await contentReadAsStringCancel(responseContent(response), token))
  } catch Bug as b {
    Err(error = b.message)
  }
}
