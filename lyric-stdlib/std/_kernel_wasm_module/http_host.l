//! std/_kernel_wasm_module/http_host.l - browser/JS-host HTTP client kernel for
//! `Std.Http` (docs/35 Q-JS-008, D-progress-1049).
//!
//! Used only by `--target native --triple wasm32-wasi --shape module`, where the
//! generated JS glue provides `fetch`.  The stdlib loader picks it over
//! `_kernel_native/http_host.l` (`Lyric.Emitter.findStdlibSourcesNativeForShape`), so
//! `Std.Http`'s shared `http.l` compiles unchanged against the same public
//! surface as the dotnet, JVM and native kernels.
//!
//! ## How a request travels
//!
//! One `promise` import, `std.http.fetch` (a `@wasmImport("std.http", promise)`
//! extern), carries the request to the host and the response back as a single
//! String.  The glue ships a default implementation over the host's global
//! `fetch`; `instantiate(..., { imports: { 'std.http': { fetch } } })` replaces
//! it (to stub the network in a test, or to add authentication).
//!
//! Request: method, URL, header lines (`name: value`, newline separated), content
//! type, body text, whether there is a body, whether redirects are followed.
//! Response: `ok`, the status, header lines, a blank line, then the body as base64
//! (a String cannot carry arbitrary bytes).  A failure to get any response (offline,
//! DNS, CORS, an aborted fetch) is `error` and a message, returned as an ordinary
//! `Err`; it is not a rejected promise, which would panic the awaiting code.
//!
//! ## Deliberate scope decisions (real, disclosed divergences)
//!
//! 1. **TLS configuration is unsupported, and fails at request time.**
//!    `hostSupportsTlsConfig()` is `false`, so `HttpClientBuilder.build()` stays
//!    infallible and every request through a client built with a custom CA, a
//!    client identity, a minimum TLS version or `withInsecureSkipVerify` fails with
//!    a typed `ConnectionFailed` naming the gap.  A browser owns certificate
//!    verification; ignoring such an option would silently weaken or change a
//!    caller's security configuration.
//! 2. **Unix domain sockets are unsupported**, failing the same way.
//! 3. **HTTP version pins are accepted and have no effect**, and
//!    `hostResponseVersionMajor` reports 1: `fetch` does not expose the negotiated
//!    version.
//! 4. **Redirects are followed or not**; a hop cap other than "some" is not
//!    honoured (`fetch` has its own limit).  With redirects off a browser hides a
//!    redirect response (an opaque redirect), which is reported as an error rather
//!    than as a response with no status.
//! 5. **Cancellation tokens are accepted and not consulted**, as on the native
//!    kernel; an in-flight `fetch` is not aborted.
//! 6. **The host decides which headers may be set** (a browser refuses `Cookie`,
//!    `Origin` and others).  The kernel rejects the framing headers the other
//!    kernels reject, and CR or LF anywhere in a request.
//! 7. **The body is read fully, capped at 10 MiB** (the native kernel's budget): a
//!    larger response is an error.
@axiom("the host's global fetch conforms to the WHATWG Fetch standard; the glue's std.http.fetch import returns the documented ok/error String")
@io
package Std.HttpHost

import Std.Core
import Std.Collections
import Std.Encoding
import Std.String as Str
import Std.Task
import Std.Tls as Tls

// =====================================================================
// The host import.
// =====================================================================
@wasmImport("std.http", promise)
extern func hostFetch(method: String, url: String, headers: String, contentType: String, body: String, hasBody: Bool, followRedirects: Bool): String = "fetch"

// =====================================================================
// Public types.
// =====================================================================
/// A configured client.  `unsupported` is empty for a usable client; otherwise it
/// names why every request through it fails (a Unix socket, which `fetch` cannot
/// open).  TLS options are refused by `Std.Http` itself through
/// `hostSupportsTlsConfig`, so they never reach this record.
pub record HttpClientHandle {
  followRedirects: Bool
  maxRedirects: Int
  unsupported: String
}

/// Request under construction.  `timeoutNanos` is accepted for signature parity
/// with the other kernels and unused.
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

/// Response, fully buffered.
pub record HttpResponseMessage {
  status: Int
  headerNames: List[String]
  headerValues: List[String]
  bodyBytes: slice[Byte]
}

// =====================================================================
// ASCII helpers (no `.toLower()` is assumed on this target).
// =====================================================================
func lowerAsciiChar(c: in String): String {
  val upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  val lower = "abcdefghijklmnopqrstuvwxyz"
  val at = Str.indexOfRaw(upper, c)
  if at >= 0 {
    Str.substring(lower, at, 1)
  } else {
    c
  }
}

func asciiEqualsCaseInsensitive(a: in String, b: in String): Bool {
  if a.length != b.length {
    return false
  }
  var i = 0
  while i < a.length {
    if lowerAsciiChar(Str.substring(a, i, 1)) != lowerAsciiChar(Str.substring(b, i, 1)) {
      return false
    }
    i = i + 1
  }
  true
}

func findHeaderValue(names: in List[String], values: in List[String], name: in String): Option[String] {
  var i = 0
  while i < names.count {
    if asciiEqualsCaseInsensitive(names[i], name) {
      return Some(value = values[i])
    }
    i = i + 1
  }
  None
}

func hasForbiddenWireChar(s: in String): Bool {
  Str.indexOfRaw(s, "\r") >= 0 or Str.indexOfRaw(s, "\n") >= 0
}

// =====================================================================
// Client construction.
// =====================================================================
/// `false`: a browser owns certificate verification, so `Std.Http` fails every
/// request of a TLS-configured client with a typed error (module header item 1).
pub func hostSupportsTlsConfig(): Bool {
  false
}

func clientHandle(followRedirects: in Bool, maxRedirects: in Int, unsupported: in String): HttpClientHandle {
  HttpClientHandle(followRedirects = followRedirects, maxRedirects = maxRedirects, unsupported = unsupported)
}

pub func hostDefaultClient(): HttpClientHandle {
  clientHandle(true, 20, "")
}

pub func hostClientWithRedirects(maxRedirects: in Int): HttpClientHandle {
  clientHandle(maxRedirects > 0, maxRedirects, "")
}

pub func hostClientNoRedirects(): HttpClientHandle {
  clientHandle(false, 0, "")
}

pub func hostClientHttp11(): HttpClientHandle {
  hostDefaultClient()
}

pub func hostClientWithRedirectsHttp11(maxRedirects: in Int): HttpClientHandle {
  hostClientWithRedirects(maxRedirects)
}

pub func hostClientNoRedirectsHttp11(): HttpClientHandle {
  hostClientNoRedirects()
}

func unixSocketClient(followRedirects: in Bool, maxRedirects: in Int): HttpClientHandle {
  clientHandle(
    followRedirects,
    maxRedirects,
    "Unix domain socket clients are not available in the browser module (fetch has no Unix-socket transport)"
  )
}

pub func hostClientWithUnixSocket(socketPath: in String): HttpClientHandle {
  unixSocketClient(true, 20)
}

pub func hostClientWithUnixSocketAndRedirects(socketPath: in String, maxRedirects: in Int): HttpClientHandle {
  unixSocketClient(maxRedirects > 0, maxRedirects)
}

pub func hostClientWithUnixSocketNoRedirects(socketPath: in String): HttpClientHandle {
  unixSocketClient(false, 0)
}

pub func hostClientWithUnixSocketHttp11(socketPath: in String): HttpClientHandle {
  hostClientWithUnixSocket(socketPath)
}

pub func hostClientWithUnixSocketAndRedirectsHttp11(socketPath: in String, maxRedirects: in Int): HttpClientHandle {
  hostClientWithUnixSocketAndRedirects(socketPath, maxRedirects)
}

pub func hostClientWithUnixSocketNoRedirectsHttp11(socketPath: in String): HttpClientHandle {
  hostClientWithUnixSocketNoRedirects(socketPath)
}

/// Unreachable through `Std.Http`: `hostSupportsTlsConfig` is false, so `build()`
/// never calls it.  Kept so the surface matches the other kernels; a client it
/// returns refuses every request.
pub func hostClientWithTls(
  maxRedirects: in Option[Int],
  noRedirects: in Bool,
  pinHttp11: in Bool,
  caCertificate: in Option[Tls.Certificate],
  exclusiveCaCertificate: in Option[Tls.Certificate],
  clientIdentity: in Option[Tls.Identity],
  minTlsVersion: in Option[Tls.TlsVersion],
  insecureSkipVerify: in Bool,
): HttpClientHandle {
  clientHandle(
    false,
    0,
    "TLS client configuration is not available in the browser module (the host owns certificate verification)"
  )
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

/// Framing headers the other kernels reject, so a caller cannot rely on setting
/// one here that fails there (#6658).
func isReservedFramingHeader(name: in String): Bool {
  asciiEqualsCaseInsensitive(name, "Host") or asciiEqualsCaseInsensitive(name, "Connection") or
    asciiEqualsCaseInsensitive(name, "Content-Type") or
    asciiEqualsCaseInsensitive(name, "Content-Length")
}

pub func hostWithHeader(
  request: in HttpRequestMessage, key: in String, value: in String
): Result[HttpRequestMessage, String] {
  if isReservedFramingHeader(key) {
    return Err(error = key)
  }
  request.headerNames.add(key)
  request.headerValues.add(value)
  return Ok(value = request)
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

// =====================================================================
// Send path.
// =====================================================================
func validateRequest(request: in HttpRequestMessage): String {
  if hasForbiddenWireChar(request.method) {
    return "invalid request method: contains CR or LF"
  }
  if Str.indexOfRaw(request.method, " ") >= 0 {
    return "invalid request method: contains a space"
  }
  if hasForbiddenWireChar(request.url) {
    return "invalid request URL: contains CR or LF"
  }
  if hasForbiddenWireChar(request.contentType) {
    return "invalid Content-Type: contains CR or LF"
  }
  var i = 0
  while i < request.headerNames.count {
    if hasForbiddenWireChar(request.headerNames[i]) or hasForbiddenWireChar(request.headerValues[i]) {
      return "invalid header: name or value contains CR or LF"
    }
    if Str.indexOfRaw(request.headerNames[i], ":") >= 0 {
      return "invalid header name: contains a colon"
    }
    i = i + 1
  }
  ""
}

func headerLines(request: in HttpRequestMessage): String {
  val lines: List[String] = newList()
  var i = 0
  while i < request.headerNames.count {
    lines.add(request.headerNames[i] + ": " + request.headerValues[i])
    i = i + 1
  }
  Str.joinList("\n", lines)
}

/// The text of `raw` from `start` up to the next newline (or the end), and the
/// index just past that newline.
func nextLine(raw: in String, start: in Int): (String, Int) {
  val at = Str.indexOfFromRaw(raw, "\n", start)
  if at < 0 {
    (Str.substring(raw, start), raw.length)
  } else {
    (Str.substring(raw, start, at - start), at + 1)
  }
}

func parseStatus(text: in String): Option[Int] {
  if text.length == 0 or text.length > 3 {
    return None
  }
  var n = 0
  var i = 0
  while i < text.length {
    val at = Str.indexOfRaw("0123456789", Str.substring(text, i, 1))
    if at < 0 {
      return None
    }
    n = n * 10 + at
    i = i + 1
  }
  Some(value = n)
}

/// Decode the String `std.http.fetch` returned.
func parseFetchResult(raw: in String): Result[HttpResponseMessage, String] {
  val (kind, afterKind) = nextLine(raw, 0)
  if kind == "error" {
    return Err(error = Str.substring(raw, afterKind))
  }
  if kind != "ok" {
    return Err(error = "std.http.fetch returned an unrecognised reply")
  }
  val (statusText, afterStatus) = nextLine(raw, afterKind)
  val status = match parseStatus(statusText) {
    case Some(n) -> n
    case None -> return Err(error = "std.http.fetch returned a malformed status")
  }
  val names: List[String] = newList()
  val values: List[String] = newList()
  var pos = afterStatus
  var inHeaders = true
  while inHeaders {
    if pos >= raw.length {
      inHeaders = false
    } else {
      val (line, next) = nextLine(raw, pos)
      pos = next
      if line.length == 0 {
        inHeaders = false
      } else {
        val colon = Str.indexOfRaw(line, ":")
        if colon > 0 {
          names.add(Str.substring(line, 0, colon))
          var valueStart = colon + 1
          if valueStart < line.length and Str.substring(line, valueStart, 1) == " " {
            valueStart = valueStart + 1
          }
          values.add(Str.substring(line, valueStart))
        }
      }
    }
  }
  val encoded = Str.substring(raw, pos)
  val bytes = match tryDecodeBase64(encoded) {
    case Some(b) -> b
    case None -> return Err(error = "std.http.fetch returned a malformed body")
  }
  Ok(value = HttpResponseMessage(status = status, headerNames = names, headerValues = values, bodyBytes = bytes))
}

async func doSend(client: in HttpClientHandle, request: in HttpRequestMessage): Result[HttpResponseMessage, String] {
  if client.unsupported.length > 0 {
    return Err(error = client.unsupported)
  }
  val problem = validateRequest(request)
  if problem.length > 0 {
    return Err(error = problem)
  }
  val raw = hostFetch(
    request.method,
    request.url,
    headerLines(request),
    request.contentType,
    request.body,
    request.hasBody,
    client.followRedirects
  )
  parseFetchResult(raw)
}

// =====================================================================
// Response accessors.
// =====================================================================
pub func hostStatusCode(response: in HttpResponseMessage): Int {
  response.status
}

pub func hostResponseHeader(response: in HttpResponseMessage, name: in String): String {
  match findHeaderValue(response.headerNames, response.headerValues, name) {
    case Some(v) -> v
    case None -> ""
  }
}

/// Always `1`: `fetch` does not expose the negotiated version (module header
/// item 3).
pub func hostResponseVersionMajor(response: in HttpResponseMessage): Int {
  1
}

func readBodyTextOf(response: in HttpResponseMessage): Result[String, String] {
  match tryDecodeUtf8(response.bodyBytes) {
    case Some(t) -> Ok(value = t)
    case None -> Err(error = "response body is not valid UTF-8")
  }
}

// ---------------------------------------------------------------------------
// Public send/read surface, matching the other kernels.
// ---------------------------------------------------------------------------
pub async func hostSendSafe(
  client: in HttpClientHandle, request: in HttpRequestMessage
): Result[HttpResponseMessage, String] {
  doSend(client, request)
}

pub async func hostGetSafe(client: in HttpClientHandle, url: in String): Result[HttpResponseMessage, String] {
  doSend(client, hostMakeRequest("GET", url))
}

pub async func hostPostStringSafe(
  client: in HttpClientHandle, url: in String, body: in String, contentType: in String
): Result[HttpResponseMessage, String] {
  doSend(client, hostWithStringBody(hostMakeRequest("POST", url), contentType, body))
}

pub async func hostReadBodyTextSafe(response: in HttpResponseMessage): Result[String, String] {
  readBodyTextOf(response)
}

pub async func hostReadBodyBytesSafe(response: in HttpResponseMessage): Result[slice[Byte], String] {
  Ok(value = response.bodyBytes)
}

// ---------------------------------------------------------------------------
// `*WithCancel*` family (module header item 5): `token` is accepted and not
// consulted.
// ---------------------------------------------------------------------------
pub async func hostSendWithCancelSafe(
  client: in HttpClientHandle,
  request: in HttpRequestMessage,
  token: in CancellationToken,
): Result[HttpResponseMessage, String] {
  doSend(client, request)
}

pub async func hostGetWithCancelSafe(
  client: in HttpClientHandle, url: in String, token: in CancellationToken
): Result[HttpResponseMessage, String] {
  doSend(client, hostMakeRequest("GET", url))
}

pub async func hostPostStringWithCancelSafe(
  client: in HttpClientHandle,
  url: in String,
  body: in String,
  contentType: in String,
  token: in CancellationToken,
): Result[HttpResponseMessage, String] {
  doSend(client, hostWithStringBody(hostMakeRequest("POST", url), contentType, body))
}

pub async func hostReadBodyTextWithCancelSafe(
  response: in HttpResponseMessage, token: in CancellationToken
): Result[String, String] {
  readBodyTextOf(response)
}
