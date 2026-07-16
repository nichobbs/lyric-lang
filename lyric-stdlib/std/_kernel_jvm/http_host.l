//! std/_kernel_jvm/http_host.l - JVM host boundary for HTTP client.
//!
//! Mirrors _kernel/http_host.l for the JVM target: the same public
//! surface (client construction, request building, the ten `*Safe`
//! wrappers, status/header/body accessors) over `java.net.http.HttpClient`
//! via the JVM auto-FFI.  The previous version routed every function
//! through phantom `lyric.stdlib.jvm.HttpClientHost` /
//! `HttpRequestBuilder` / `HttpResponseWrapper` classes that never existed
//! at runtime, which left Std.Http non-functional on this target
//! (docs/59 F-1c, docs/44 m-89).
//!
//! Representation choices:
//!
//!   - `HttpRequestMessage` is a pure-Lyric accumulation record rather
//!     than a `java.net.http.HttpRequest.Builder` alias: the JDK builder's
//!     only body-setting entry point is `method(name, publisher)`, so a
//!     later `hostWithStringBody` would need the method name back out of
//!     the builder, which the Builder interface cannot answer.  The real
//!     `HttpRequest` is built once, inside the send path.
//!   - `HttpResponseMessage` buffers status/headers/body eagerly at send
//!     time (`BodyHandlers.ofInputStream` + `readAllBytes`) — the same
//!     fully-buffered semantics as the .NET twin's default
//!     `HttpCompletionOption.ResponseContentRead`.  `ofInputStream` rather
//!     than `ofByteArray` because `HttpResponse.body()` is an erased
//!     generic (`()Ljava/lang/Object;`): a class-typed binding checkcast
//!     (`JInputStream`) is auto-FFI-expressible where an array checkcast
//!     (`[B`) is not.
//!
//! The JDK's synchronous `send(HttpRequest, BodyHandler)` blocks the
//! calling virtual thread (JEP 444); the JVM scheduler parks the carrier
//! thread on I/O without blocking the OS thread, so the `async` surface
//! below lowers to plain synchronous calls, as everywhere on this target.
//!
//! Cancellation is cooperative on this target: the JDK's synchronous
//! `send` accepts no cancellation token, so the `*WithCancel*` family
//! (a) polls the token before sending and before body reads, and (b) maps
//! a `makeCancelSourceTimeout` deadline onto `HttpRequest.Builder.timeout`
//! (the JDK's own in-flight request deadline, surfacing as
//! `HttpTimeoutException` -> `Err` through the `*Safe` wrappers).  An
//! explicit `cancelSource` fired while a request is already in flight is
//! observed at the next poll point rather than aborting the transfer —
//! the same cooperative-cancellation contract `_kernel_jvm/task.l`
//! documents for this target.
@axiom("java.net.http.HttpClient operations conform to their documented JVM contracts")
package Std.HttpHost

import Std.Core
import Std.Collections
import Std.Task

// =====================================================================
// Extern types — JDK classes the helpers below reference.
// =====================================================================
extern type HttpClientHandle = "java.net.http.HttpClient"

extern type JHttpClientBuilder = "java.net.http.HttpClient$Builder"

extern type JRedirect = "java.net.http.HttpClient$Redirect"

// HTTP-version knob (docs/61 §5.1, D128 decision 4; #5879).  JDK 21 has no
// `HTTP_3` case — the JDK's own `HttpClient.Version` enum only distinguishes
// `HTTP_1_1`/`HTTP_2` — so `Std.Http.HttpVersion.Http3` has no dotnet-style
// "pin" here at all; it is refused entirely at the `Std.Http` layer before
// any kernel call is made (see `HttpClientImpl.unsupportedReason`).
extern type JHttpVersion = "java.net.http.HttpClient$Version"

extern type JHttpRequest = "java.net.http.HttpRequest"

extern type JHttpRequestBuilder = "java.net.http.HttpRequest$Builder"

extern type JBodyPublishers = "java.net.http.HttpRequest$BodyPublishers"

extern type JBodyHandlers = "java.net.http.HttpResponse$BodyHandlers"

extern type JHttpResponse = "java.net.http.HttpResponse"

extern type JHttpHeaders = "java.net.http.HttpHeaders"

extern type JOptional = "java.util.Optional"

extern type JURI = "java.net.URI"

extern type JString = "java.lang.String"

extern type JInputStream = "java.io.InputStream"

extern type JDuration = "java.time.Duration"

extern type JSystem = "java.lang.System"

/// Request under construction: method/URL/headers/body accumulate in
/// pure Lyric; the JDK `HttpRequest` is built once in the send path
/// (module header).  `timeoutNanos` (0 = none) carries a
/// `*WithCancel*` deadline onto `HttpRequest.Builder.timeout`.
pub record HttpRequestMessage {
  method: String
  url: String
  headerNames: List[String]
  headerValues: List[String]
  contentType: String
  body: String
  hasBody: Bool
  timeoutNanos: Long
}

/// Response, fully buffered at send time (module header).  `version` is
/// the negotiated wire protocol (docs/61 §5.1; #5879).
pub record HttpResponseMessage {
  status: Int
  jheaders: JHttpHeaders
  bodyBytes: slice[Byte]
  version: JHttpVersion
}

// =====================================================================
// Client construction.
// =====================================================================
// `version` (docs/61 §5.1, D128 decision 4; #5879): `HttpClient` is built
// immutably on this target — unlike the .NET twin's mutable
// `DefaultRequestVersion`/`DefaultVersionPolicy` properties, there is no
// post-construction way to change it — so every construction path takes the
// desired version up front rather than patching an already-built client.
func buildClient(followRedirects: in Bool, version: in JHttpVersion): HttpClientHandle {
  val b: JHttpClientBuilder = HttpClientHandle.newBuilder()
  val withRedirect: JHttpClientBuilder = if followRedirects {
    b.followRedirects(JRedirect.NORMAL)
  } else {
    b.followRedirects(JRedirect.NEVER)
  }
  val withVersion: JHttpClientBuilder = withRedirect.version(version)
  withVersion.build()
}

// #333 parity with the .NET twin: process-wide client singleton,
// initialised once in the package `.cctor` and reused on every request.
// Redirect-following by default, matching .NET's HttpClientHandler.
// `HTTP_2` matches the JDK's own out-of-the-box default (h2-or-lower,
// falling back to HTTP/1.1) — explicit here per docs/61 §5.1 for clarity
// rather than relying on the builder's implicit default.
val processClient: HttpClientHandle = buildClient(true, JHttpVersion.HTTP_2)

pub func hostDefaultClient(): HttpClientHandle {
  processClient
}

/// Redirect-following client.  `Redirect.NORMAL` follows same-or-safer
/// scheme redirects up to the JDK's internal hop cap; the cap itself is
/// process-wide (`-Djdk.httpclient.redirects.retrylimit`), not
/// per-client, so `maxRedirects` here selects between following
/// (positive) and not following (zero or negative) rather than setting
/// an exact hop count.
pub func hostClientWithRedirects(maxRedirects: in Int): HttpClientHandle {
  buildClient(maxRedirects > 0, JHttpVersion.HTTP_2)
}

pub func hostClientNoRedirects(): HttpClientHandle {
  buildClient(false, JHttpVersion.HTTP_2)
}

// ---------------------------------------------------------------------------
// HTTP/1.1 exact-pin variants (docs/61 §5.1, D128 decision 4; #5879) —
// mirrors `_kernel/http_host.l`'s `hostClient*Http11` family so `Std.Http`'s
// `HttpClientBuilder.build()` calls the same-named function on either
// kernel.
// ---------------------------------------------------------------------------
pub func hostClientHttp11(): HttpClientHandle {
  buildClient(true, JHttpVersion.HTTP_1_1)
}

pub func hostClientWithRedirectsHttp11(maxRedirects: in Int): HttpClientHandle {
  buildClient(maxRedirects > 0, JHttpVersion.HTTP_1_1)
}

pub func hostClientNoRedirectsHttp11(): HttpClientHandle {
  buildClient(false, JHttpVersion.HTTP_1_1)
}

// ---------------------------------------------------------------------------
// Unix domain socket support: not available on this target.
// `java.net.http.HttpClient` exposes no Unix-socket transport; until the
// JDK grows one, constructing such a client fails loudly rather than
// returning a client that silently dials TCP.  Tracked with the JVM
// parity umbrella, #2663.  Unsupported regardless of HTTP version, so the
// `*Http11` variants below fail the same way as their plain counterparts.
// ---------------------------------------------------------------------------
func unixSocketUnsupported(): HttpClientHandle {
  panic(
    "Std.Http: Unix domain socket clients are not supported on the JVM target: " +
      "java.net.http.HttpClient has no Unix-socket transport (tracked in #2663)"
  )
}

pub func hostClientWithUnixSocket(socketPath: in String): HttpClientHandle {
  unixSocketUnsupported()
}

pub func hostClientWithUnixSocketAndRedirects(socketPath: in String, maxRedirects: in Int): HttpClientHandle {
  unixSocketUnsupported()
}

pub func hostClientWithUnixSocketNoRedirects(socketPath: in String): HttpClientHandle {
  unixSocketUnsupported()
}

pub func hostClientWithUnixSocketHttp11(socketPath: in String): HttpClientHandle {
  unixSocketUnsupported()
}

pub func hostClientWithUnixSocketAndRedirectsHttp11(socketPath: in String, maxRedirects: in Int): HttpClientHandle {
  unixSocketUnsupported()
}

pub func hostClientWithUnixSocketNoRedirectsHttp11(socketPath: in String): HttpClientHandle {
  unixSocketUnsupported()
}

// =====================================================================
// Request construction.
// =====================================================================
pub func hostMakeRequest(httpMethod: in String, url: in String): HttpRequestMessage {
  val names: List[String] = newList()
  val values: List[String] = newList()
  HttpRequestMessage(
    method = httpMethod,
    url = url,
    headerNames = names,
    headerValues = values,
    contentType = "",
    body = "",
    hasBody = false,
    timeoutNanos = 0i64
  )
}

pub func hostWithHeader(request: in HttpRequestMessage, key: in String, value: in String): HttpRequestMessage {
  request.headerNames.add(key)
  request.headerValues.add(value)
  request
}

pub func hostWithStringBody(request: in HttpRequestMessage, contentType: in String, body: in String): HttpRequestMessage {
  HttpRequestMessage(
    method = request.method,
    url = request.url,
    headerNames = request.headerNames,
    headerValues = request.headerValues,
    contentType = contentType,
    body = body,
    hasBody = true,
    timeoutNanos = request.timeoutNanos
  )
}

func withTimeoutNanos(request: in HttpRequestMessage, nanos: in Long): HttpRequestMessage {
  HttpRequestMessage(
    method = request.method,
    url = request.url,
    headerNames = request.headerNames,
    headerValues = request.headerValues,
    contentType = request.contentType,
    body = request.body,
    hasBody = request.hasBody,
    timeoutNanos = nanos
  )
}

// =====================================================================
// Send path (internal).
// =====================================================================
func buildJavaRequest(request: in HttpRequestMessage): JHttpRequest {
  var b: JHttpRequestBuilder = JHttpRequest.newBuilder()
  b = b.uri(JURI.create(request.url))
  var i = 0
  while i < request.headerNames.count {
    val name: String = request.headerNames[i]
    val value: String = request.headerValues[i]
    b = b.header(name, value)
    i = i + 1
  }
  if request.timeoutNanos > 0i64 {
    b = b.timeout(JDuration.ofNanos(request.timeoutNanos))
  }
  if request.hasBody {
    b = b.header("Content-Type", request.contentType)
    b = b.method(request.method, JBodyPublishers.ofString(request.body))
  } else {
    b = b.method(request.method, JBodyPublishers.noBody())
  }
  b.build()
}

// Close on the failure path too, so a transfer aborted mid-body does not
// leak the connection's stream until GC (the _kernel_jvm/file_host.l
// hostReadAllBytes idiom, #4780).
func readAllAndClose(ins: in JInputStream): slice[Byte] {
  try {
    val bytes = ins.readAllBytes()
    ins.close()
    bytes
  } catch Bug as b {
    ins.close()
    panic(b.message)
  }
}

func doSend(client: in HttpClientHandle, request: in HttpRequestMessage): HttpResponseMessage {
  val jreq = buildJavaRequest(request)
  val resp: JHttpResponse = client.send(jreq, JBodyHandlers.ofInputStream())
  val ins: JInputStream = resp.body()
  val bytes = readAllAndClose(ins)
  HttpResponseMessage(status = resp.statusCode(), jheaders = resp.headers(), bodyBytes = bytes, version = resp.version())
}

// Apply a `makeCancelSourceTimeout` deadline as the JDK request timeout
// (module header).  A poll-race where the deadline elapses between the
// caller's `throwIfCancelled` and here still panics the same way the
// poll would, rather than handing `Duration.ofNanos` a non-positive value.
func withCancelDeadline(request: in HttpRequestMessage, token: in CancellationToken): HttpRequestMessage {
  if token.deadlineMs > 0i64 {
    val remaining = token.deadlineMs - JSystem.nanoTime()
    if remaining <= 0i64 {
      panic("OperationCanceledException: cancellation was requested")
    }
    withTimeoutNanos(request, remaining)
  } else {
    request
  }
}

func doGet(client: in HttpClientHandle, url: in String): HttpResponseMessage {
  doSend(client, hostMakeRequest("GET", url))
}

func doPostString(
  client: in HttpClientHandle, url: in String, body: in String, contentType: in String
): HttpResponseMessage {
  doSend(client, hostWithStringBody(hostMakeRequest("POST", url), contentType, body))
}

// =====================================================================
// Response accessors.
// =====================================================================
pub func hostStatusCode(response: in HttpResponseMessage): Int {
  response.status
}

/// `negotiatedVersion` (docs/61 §5.1; #5879): maps the JDK's
/// `HttpClient.Version` enum to the major-version int `Std.Http` matches
/// against `HttpVersion` (mirrors `_kernel/http_host.l`'s
/// `hostResponseVersionMajor`). JDK 21's enum has exactly two cases
/// (`HTTP_1_1`/`HTTP_2` — no `HTTP_3`), so anything that isn't `HTTP_2`
/// is `HTTP_1_1`.
pub func hostResponseVersionMajor(response: in HttpResponseMessage): Int {
  if response.version.equals(JHttpVersion.HTTP_2) {
    2
  } else {
    1
  }
}

/// First value of the named response header, or `""` if absent.
/// `java.net.http.HttpHeaders` is case-insensitive and carries content
/// headers in the same map, matching the .NET twin's two-collection
/// fallthrough.
pub func hostResponseHeader(response: in HttpResponseMessage, name: in String): String {
  val opt: JOptional = response.jheaders.firstValue(name)
  val value: String = opt.orElse("")
  value
}

func readBodyTextOf(response: in HttpResponseMessage): String {
  JString.new(response.bodyBytes, "UTF-8")
}

// ---------------------------------------------------------------------------
// V0012-safe wrappers — the public send/read surface, mirroring
// _kernel/http_host.l.  On JVM there is no CLR protected-region
// restriction; the try/catch here is the kernel's exception -> Result
// boundary, same division of labour as the .NET twin.
// ---------------------------------------------------------------------------
pub async func hostSendSafe(
  client: in HttpClientHandle, request: in HttpRequestMessage
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = doSend(client, request))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostGetSafe(client: in HttpClientHandle, url: in String): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = doGet(client, url))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostPostStringSafe(
  client: in HttpClientHandle, url: in String, body: in String, contentType: in String
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = doPostString(client, url, body, contentType))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyTextSafe(response: in HttpResponseMessage): Result[String, String] {
  return try {
    Ok(value = readBodyTextOf(response))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyBytesSafe(response: in HttpResponseMessage): Result[slice[Byte], String] {
  return try {
    Ok(value = response.bodyBytes)
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
    throwIfCancelled(token)
    Ok(value = doSend(client, withCancelDeadline(request, token)))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostGetWithCancelSafe(
  client: in HttpClientHandle, url: in String, token: in CancellationToken
): Result[HttpResponseMessage, String] {
  return try {
    throwIfCancelled(token)
    Ok(value = doSend(client, withCancelDeadline(hostMakeRequest("GET", url), token)))
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
    throwIfCancelled(token)
    val request = hostWithStringBody(hostMakeRequest("POST", url), contentType, body)
    Ok(value = doSend(client, withCancelDeadline(request, token)))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyTextWithCancelSafe(
  response: in HttpResponseMessage, token: in CancellationToken
): Result[String, String] {
  return try {
    throwIfCancelled(token)
    Ok(value = readBodyTextOf(response))
  } catch Bug as b {
    Err(error = b.message)
  }
}
