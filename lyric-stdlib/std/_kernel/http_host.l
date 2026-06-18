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
extern type HttpClient = "System.Net.Http.HttpClient"

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

@externTarget("System.Net.Http.HttpRequestMessage.Headers")
func requestHeaders(req: in HttpRequestMessage): HttpHeaders = ()

@externTarget("System.Net.Http.Headers.HttpHeaders.TryAddWithoutValidation")
func headersTryAdd(h: in HttpHeaders, name: in String, value: in String): Bool = ()

@externTarget("System.Net.Http.StringContent..ctor")
func newStringContent(body: in String, encoding: in Encoding, mediaType: in String): StringContent = ()

@externTarget("System.Net.Http.HttpRequestMessage.set_Content")
func setRequestContent(req: in HttpRequestMessage, content: in StringContent): Unit = ()

@externTarget("System.Net.Http.HttpClient..ctor")
func newClient(): HttpClient = ()

@externTarget("System.Net.Http.HttpClient..ctor")
func newClientFromHandler(handler: in HttpClientHandler): HttpClient = ()

@externTarget("System.Net.Http.HttpClientHandler..ctor")
func newHandler(): HttpClientHandler = ()

@externTarget("System.Net.Http.HttpClientHandler.set_AllowAutoRedirect")
func setAllowAutoRedirect(h: in HttpClientHandler, v: in Bool): Unit = ()

@externTarget("System.Net.Http.HttpClientHandler.set_MaxAutomaticRedirections")
func setMaxAutomaticRedirections(h: in HttpClientHandler, n: in Int): Unit = ()

@externTarget("System.Net.Sockets.UnixDomainSocketEndPoint..ctor")
func newUnixDomainSocketEndPoint(path: in String): UnixDomainSocketEndPoint = ()

@externTarget("System.Net.Http.SocketsHttpHandler..ctor")
func newSocketsHandler(): SocketsHttpHandler = ()

@externTarget("System.Net.Http.SocketsHttpHandler.set_AllowAutoRedirect")
func socketsSetAllowAutoRedirect(h: in SocketsHttpHandler, v: in Bool): Unit = ()

@externTarget("System.Net.Http.SocketsHttpHandler.set_MaxAutomaticRedirections")
func socketsSetMaxAutomaticRedirections(h: in SocketsHttpHandler, n: in Int): Unit = ()

@externTarget("System.Net.Http.HttpClient.SendAsync")
async func clientSendAsync(client: in HttpClient, request: in HttpRequestMessage): HttpResponseMessage = ()

@externTarget("System.Net.Http.HttpClient.SendAsync")
async func clientSendAsyncCancel(
  client: in HttpClient, request: in HttpRequestMessage, token: in CancellationToken
): HttpResponseMessage = ()

@externTarget("System.Net.Http.HttpClient.GetAsync")
async func clientGetAsync(client: in HttpClient, url: in String): HttpResponseMessage = ()

@externTarget("System.Net.Http.HttpClient.GetAsync")
async func clientGetAsyncCancel(client: in HttpClient, url: in String, token: in CancellationToken): HttpResponseMessage = ()

@externTarget("System.Net.Http.HttpClient.PostAsync")
async func clientPostAsync(client: in HttpClient, url: in String, content: in StringContent): HttpResponseMessage = ()

@externTarget("System.Net.Http.HttpClient.PostAsync")
async func clientPostAsyncCancel(
  client: in HttpClient,
  url: in String,
  content: in StringContent,
  token: in CancellationToken,
): HttpResponseMessage = ()

@externTarget("System.Net.Http.HttpResponseMessage.StatusCode")
func responseStatusInt(response: in HttpResponseMessage): Int = ()

@externTarget("System.Net.Http.HttpResponseMessage.Content")
func responseContent(response: in HttpResponseMessage): HttpContent = ()

@externTarget("System.Net.Http.HttpContent.ReadAsStringAsync")
async func contentReadAsString(c: in HttpContent): String = ()

@externTarget("System.Net.Http.HttpContent.ReadAsStringAsync")
async func contentReadAsStringCancel(c: in HttpContent, token: in CancellationToken): String = ()

@externTarget("System.Net.Http.HttpContent.ReadAsByteArrayAsync")
async func contentReadAsBytes(c: in HttpContent): slice[Byte] = ()

@externTarget("System.Net.Http.HttpContent.ReadAsByteArrayAsync")
async func contentReadAsBytesCancel(c: in HttpContent, token: in CancellationToken): slice[Byte] = ()

// =====================================================================
// Public host helpers — the names `Std.Http` resolves through
// `import Std.HttpHost as HostHttp`.  Each is either a thin alias or
// a multi-step composition that wraps the primitives above.
// =====================================================================
// #333: process-wide HttpClient singleton — initialised once in the package `.cctor`,
// reused on every request.  Per-call construction exhausts the TCP socket pool
// (sockets stay in TIME_WAIT for two MSL after GC).
pub val defaultClient: HttpClient = newClient()

pub func hostDefaultClient(): HttpClient {
  defaultClient
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

pub async func hostSend(client: in HttpClient, request: in HttpRequestMessage): HttpResponseMessage {
  await clientSendAsync(client, request)
}

pub async func hostGet(client: in HttpClient, url: in String): HttpResponseMessage {
  await clientGetAsync(client, url)
}

pub async func hostPostString(
  client: in HttpClient, url: in String, body: in String, contentType: in String
): HttpResponseMessage {
  await clientPostAsync(client, url, newStringContent(body, utf8(), contentType))
}

pub func hostStatusCode(response: in HttpResponseMessage): Int {
  responseStatusInt(response)
}

pub async func hostReadBodyText(response: in HttpResponseMessage): String {
  await contentReadAsString(responseContent(response))
}

pub async func hostReadBodyBytes(response: in HttpResponseMessage): slice[Byte] {
  await contentReadAsBytes(responseContent(response))
}

// ---------------------------------------------------------------------------
// Phase C cancellation-aware overloads (D-progress-070).
// ---------------------------------------------------------------------------
pub async func hostSendWithCancel(
  client: in HttpClient, request: in HttpRequestMessage, token: in CancellationToken
): HttpResponseMessage {
  await clientSendAsyncCancel(client, request, token)
}

pub async func hostGetWithCancel(
  client: in HttpClient, url: in String, token: in CancellationToken
): HttpResponseMessage {
  await clientGetAsyncCancel(client, url, token)
}

pub async func hostPostStringWithCancel(
  client: in HttpClient,
  url: in String,
  body: in String,
  contentType: in String,
  token: in CancellationToken,
): HttpResponseMessage {
  await clientPostAsyncCancel(client, url, newStringContent(body, utf8(), contentType), token)
}

pub async func hostReadBodyTextWithCancel(response: in HttpResponseMessage, token: in CancellationToken): String {
  await contentReadAsStringCancel(responseContent(response), token)
}

pub func hostClientWithRedirects(maxRedirects: in Int): HttpClient {
  val handler = newHandler()
  setAllowAutoRedirect(handler, true)
  setMaxAutomaticRedirections(handler, maxRedirects)
  newClientFromHandler(handler)
}

pub func hostClientNoRedirects(): HttpClient {
  val handler = newHandler()
  setAllowAutoRedirect(handler, false)
  newClientFromHandler(handler)
}

// ---------------------------------------------------------------------------
// Unix domain socket support for local protocol access (Docker, systemd, etc).
// Pure Lyric implementation using strongly-typed lambda FFI delegates (Epic #1877).
// ---------------------------------------------------------------------------

// Extern types for Unix socket and async callback support
extern type Socket = "System.Net.Sockets.Socket"
extern type AddressFamily = "System.Net.Sockets.AddressFamily"
extern type SocketType = "System.Net.Sockets.SocketType"
extern type ProtocolType = "System.Net.Sockets.ProtocolType"
extern type Stream = "System.IO.Stream"
extern type NetworkStream = "System.Net.Sockets.NetworkStream"
extern type SocketsHttpConnectionContext = "System.Net.Http.SocketsHttpConnectionContext"
extern type CancellationToken = "System.Threading.CancellationToken"

// Extern constructors and methods for socket operations
@externTarget("System.Net.Sockets.AddressFamily.Unix")
func getAddressFamilyUnix(): AddressFamily = ()

@externTarget("System.Net.Sockets.SocketType.Stream")
func getSocketTypeStream(): SocketType = ()

@externTarget("System.Net.Sockets.ProtocolType.Unspecified")
func getProtocolTypeUnspecified(): ProtocolType = ()

@externTarget("System.Net.Sockets.Socket..ctor")
func newSocket(addressFamily: in AddressFamily, socketType: in SocketType, protocolType: in ProtocolType): Socket = ()

@externTarget("System.Net.Sockets.Socket.ConnectAsync")
async func socketConnectAsync(socket: in Socket, endpoint: in UnixDomainSocketEndPoint, cancellationToken: in CancellationToken): Unit = ()

@externTarget("System.Net.Sockets.NetworkStream..ctor")
func newNetworkStream(socket: in Socket, ownsSocket: in Bool): NetworkStream = ()

@externTarget("System.Net.Sockets.Socket.Dispose")
func socketDispose(socket: in Socket): Unit = ()

@externTarget("System.Net.Http.SocketsHttpHandler.set_ConnectCallback")
func setConnectCallback(handler: in SocketsHttpHandler, callback: in async (SocketsHttpConnectionContext, CancellationToken) -> Stream): Unit = ()

// Create strongly-typed lambda for Unix socket connection (Epic #1877).
// The lambda is async and returns Stream; Lyric's type system automatically
// wraps it as Func<SocketsHttpConnectionContext, CancellationToken, ValueTask<Stream>>.
func makeUnixSocketCallback(socketPath: in String): async (SocketsHttpConnectionContext, CancellationToken) -> Stream {
  { (context: SocketsHttpConnectionContext, cancellationToken: CancellationToken) ->
    val socket = newSocket(getAddressFamilyUnix(), getSocketTypeStream(), getProtocolTypeUnspecified())
    try {
      val endpoint = newUnixDomainSocketEndPoint(socketPath)
      await socketConnectAsync(socket, endpoint, cancellationToken)
      newNetworkStream(socket, ownsSocket = true)
    } catch {
      case Bug as b -> {
        socketDispose(socket)
        throw Bug(message = b.message)
      }
    }
  }
}

pub func hostClientWithUnixSocket(socketPath: in String): HttpClient {
  val handler = newSocketsHandler()
  setConnectCallback(handler, makeUnixSocketCallback(socketPath))
  newClientFromHandler(handler)
}

pub func hostClientWithUnixSocketAndRedirects(socketPath: in String, maxRedirects: in Int): HttpClient {
  val handler = newSocketsHandler()
  socketsSetAllowAutoRedirect(handler, true)
  socketsSetMaxAutomaticRedirections(handler, maxRedirects)
  setConnectCallback(handler, makeUnixSocketCallback(socketPath))
  newClientFromHandler(handler)
}

pub func hostClientWithUnixSocketNoRedirects(socketPath: in String): HttpClient {
  val handler = newSocketsHandler()
  socketsSetAllowAutoRedirect(handler, false)
  setConnectCallback(handler, makeUnixSocketCallback(socketPath))
  newClientFromHandler(handler)
}

// `ResponseHeader` (G12 follow-up): native Lyric on top of
// `HttpHeaders.TryGetValues(name, out IEnumerable<string>)` + a
// `System.Linq.Enumerable.ToArray<string>` shuttle into a
// `slice[String]` the Lyric side can index.  The BCL splits headers
// across `response.Headers` (general + caller-set) and
// `response.Content.Headers` (Content-Type, Content-Length, …) — try
// the former first, then fall through to the latter, then `""`.
extern type HttpResponseHeaders = "System.Net.Http.Headers.HttpResponseHeaders"

extern type HttpContentHeaders = "System.Net.Http.Headers.HttpContentHeaders"

extern type IEnumerableStr = "System.Collections.Generic.IEnumerable`1[System.String]"

@externTarget("System.Net.Http.HttpResponseMessage.Headers")
func responseHeadersOf(r: in HttpResponseMessage): HttpResponseHeaders = ()

@externTarget("System.Net.Http.HttpContent.Headers")
func contentHeadersOf(c: in HttpContent): HttpContentHeaders = ()

@externTarget("System.Net.Http.Headers.HttpHeaders.TryGetValues")
func responseHeadersTryGet(h: in HttpResponseHeaders, name: in String, values: out IEnumerableStr): Bool = ()

@externTarget("System.Net.Http.Headers.HttpHeaders.TryGetValues")
func contentHeadersTryGet(h: in HttpContentHeaders, name: in String, values: out IEnumerableStr): Bool = ()

@externTarget("System.Linq.Enumerable.ToArray")
func enumerableStrToArray(values: in IEnumerableStr): slice[String] = ()

// Take the first element of `values` or `""` if empty.  Pure Lyric.
func firstOrEmpty(values: in slice[String]): String {
  if values.length > 0 {
    values[0]
  } else {
    ""
  }
}

pub func hostResponseHeader(response: in HttpResponseMessage, name: in String): String {
  val respHeaders = responseHeadersOf(response)
  var responseValues: IEnumerableStr = default()
  if responseHeadersTryGet(respHeaders, name, responseValues) {
    return firstOrEmpty(enumerableStrToArray(responseValues))
  }
  val contentHeaders = contentHeadersOf(responseContent(response))
  var contentValues: IEnumerableStr = default()
  if contentHeadersTryGet(contentHeaders, name, contentValues) {
    return firstOrEmpty(enumerableStrToArray(contentValues))
  }
  ""
}

// ---------------------------------------------------------------------------
// V0012-safe wrappers — issue #2985.
//
// The self-hosted MSIL emitter cannot place an await inside a CLR protected
// region (try/catch/finally).  Std.Http used to catch Bug inline around each
// await; those functions now await these wrappers instead, keeping the await
// outside any try block on the Std.Http side.  This file is @axiom, so it
// compiles through the F# bootstrap emitter which can hoist awaits — the
// wrappers below are therefore permitted to use await-in-try.
// ---------------------------------------------------------------------------
pub async func hostSendSafe(client: in HttpClient, request: in HttpRequestMessage): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await clientSendAsync(client, request))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostGetSafe(client: in HttpClient, url: in String): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await clientGetAsync(client, url))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostPostStringSafe(
  client: in HttpClient, url: in String, body: in String, contentType: in String
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
  client: in HttpClient, request: in HttpRequestMessage, token: in CancellationToken
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await clientSendAsyncCancel(client, request, token))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostGetWithCancelSafe(
  client: in HttpClient, url: in String, token: in CancellationToken
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await clientGetAsyncCancel(client, url, token))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostPostStringWithCancelSafe(
  client: in HttpClient,
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
